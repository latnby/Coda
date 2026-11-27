import SwiftUI
import CoreImage.CIFilterBuiltins

struct PlatformLoginSheet: View {
    let provider: MusicProvider
    /// Adds the scanned account to the list instead of switching to it.
    var addsAccount = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var account: AccountStore
    @State private var image: PlatformImage?
    @State private var qqChannel = QQMusicLoginChannel.qq
    @State private var status = "正在获取二维码…"
    @State private var isSaving = false
    @StateObject private var qishuiAuth = QishuiMusicAPI(diagnostics: true)
    @StateObject private var qqAuth = QQMusicAuth(persistsSession: false)

    /// The live QR session. It outlives the polling task so that switching to
    /// the platform app to scan/confirm and coming back resumes polling the
    /// SAME code instead of fetching a new one — a refreshed code strands the
    /// confirmation the user just made in the other app. (The NetEase sheet
    /// already works this way; this sheet used to restart from scratch
    /// whenever its `.task` restarted or a poll died in the background.)
    private enum Session {
        case qqMain
        case qqAdditional(QQMusicLoginChannel)
        case kugou(key: String)
        case qishui(QishuiMusicAPI.QRCode)
    }

    @State private var session: Session?
    @State private var loginTask: Task<Void, Never>?
    @State private var started = false
    /// Set when polling paused after repeated network failures (the app spent
    /// too long backgrounded); scenePhase .active then resumes the same
    /// session instead of letting the login die.
    @State private var pollInterrupted = false

    var body: some View {
        VStack(spacing: Theme.Spacing.section) {
            Text(addsAccount ? "添加\(provider.name)账号" : "登录\(provider.name)").font(Theme.Typography.sectionTitle)
                .padding(.top, Theme.Spacing.section)
            if provider == .qq {
                Picker("扫码方式", selection: $qqChannel) {
                    ForEach(QQMusicLoginChannel.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .disabled(isSaving)
                .onChange(of: qqChannel) { _ in restart() }
            }
            Text(provider == .qishui ? "请使用已登录的汽水音乐 App 扫码并确认登录" : provider == .qq ? "请使用\(qqChannel.name)扫描二维码并确认登录" : "请使用酷狗音乐扫描二维码并确认登录")
                .font(Theme.Typography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            LoginQRCodeFrame(image: image) { EmptyView() }
            Text(status).font(Theme.Typography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("刷新二维码") { restart() }
                .buttonStyle(.plain).font(Theme.Typography.caption).foregroundStyle(Theme.accent)
                .disabled(isSaving)
            Button("取消") { dismiss() }
                .buttonStyle(.plain).font(Theme.Typography.caption).foregroundStyle(.secondary)
                .padding(.bottom, Theme.Spacing.section).disabled(isSaving)
        }
        .frame(width: 320)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            guard !started else { return }
            started = true
            begin()
        }
        // Dismissing the sheet is the user cancelling; merely backgrounding
        // the app does not fire onDisappear, so a live session survives the
        // trip to the platform app and back.
        .onDisappear {
            loginTask?.cancel()
            started = false
            if provider == .qishui { qishuiAuth.cancelLogin() }
        }
        // Coming back from the platform app (single-device flow): if polling
        // died while we were in the background, pick the same session up again.
        .onChange(of: scenePhase) { _ in
            guard scenePhase == .active else { return }
            resumeIfNeeded()
        }
        .sheet(isPresented: Binding(get: { qishuiAuth.verificationWebView != nil }, set: { if !$0 { qishuiAuth.cancelVerification() } })) {
            if let web = qishuiAuth.verificationWebView {
                QishuiSecurityVerificationView(webView: web, onCancel: { qishuiAuth.cancelVerification() })
            }
        }
    }

    // MARK: - Session lifecycle

    /// Explicit refresh (button, or switching the QQ channel): the only path
    /// that throws the current code away and fetches a new one.
    private func restart() {
        loginTask?.cancel()
        loginTask = nil
        session = nil
        pollInterrupted = false
        if provider == .qishui { qishuiAuth.cancelLogin() }
        started = true
        begin()
    }

    private func resumeIfNeeded() {
        guard let session, pollInterrupted else { return }
        // The additional QQ channels keep their session inside the sign-in
        // call itself, so there is nothing to resume from here; their
        // transports tolerate backgrounding on their own.
        if case .qqAdditional = session { return }
        pollInterrupted = false
        loginTask = Task { await runSession() }
    }

    private func begin() {
        pollInterrupted = false
        loginTask = Task {
            guard await fetchSession() else { return }
            await runSession()
        }
    }

    /// Fetches a fresh QR code and stores its session. Returns false when the
    /// fetch failed (status already shows why) or the task was cancelled.
    private func fetchSession() async -> Bool {
        image = nil
        status = "正在获取二维码…"
        do {
            if provider == .qishui {
                let qr = try await qishuiAuth.qrCode()
                try Task.checkCancellation()
                guard let decoded = Self.qrImage(qr.scanURL.absoluteString) else { throw QishuiError.invalidResponse }
                image = decoded
                status = "等待使用汽水音乐扫码"
                session = .qishui(qr)
            } else if provider == .qq, qqChannel != .qq {
                session = .qqAdditional(qqChannel)
            } else if provider == .qq {
                let data = try await qqAuth.fetchQRCode()
                try Task.checkCancellation()
                image = PlatformImage(data: data)
                status = "等待扫码"
                session = .qqMain
            } else {
                let qr = try await KugouMusicAPI.shared.qrKey()
                try Task.checkCancellation()
                session = .kugou(key: qr.key)
                image = Self.qrImage(qr.url)
                status = "等待扫码"
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled { status = error.localizedDescription }
            return false
        }
    }

    private func runSession() async {
        guard let session else { return }
        switch session {
        case .qqAdditional(let channel):
            do {
                let result = try await QQMusicAdditionalLogin.signIn(channel, onImage: { data in
                    image = PlatformImage(data: data)
                    status = "等待使用\(channel.name)扫码"
                }, onScanned: {
                    status = "已扫码，请在\(channel.name)中确认"
                })
                try Task.checkCancellation()
                await finish(credentials: result.credentials, nickname: result.nickname)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    // This session lived inside the call and is gone with it;
                    // only an explicit refresh can mint a new code.
                    self.session = nil
                    status = error.localizedDescription
                }
            }
        case .qqMain:
            await pollLoop {
                switch try await qqAuth.poll() {
                case .waiting: return .keepWaiting("等待扫码")
                case .scanned: return .keepWaiting("已扫码，请在 QQ 中确认")
                case .expired: return .expired
                case .error(let message): return .failed(message)
                case .success(let nickname):
                    await finish(credentials: qqAuth.exportedCredentials, nickname: nickname)
                    return .done
                }
            }
        case .kugou(let key):
            await pollLoop {
                switch try await KugouMusicAPI.shared.pollQR(key: key) {
                case .waiting: return .keepWaiting("等待扫码")
                case .scanned: return .keepWaiting("已扫码，请在酷狗音乐中确认")
                case .expired: return .expired
                case .error(let message): return .failed(message)
                case .success(let credentials):
                    await finish(credentials: credentials, nickname: credentials["nickname"] ?? "酷狗音乐用户")
                    return .done
                }
            }
        case .qishui(let qr):
            await pollLoop {
                if qishuiAuth.isQRCodeExpired(token: qr.token) { return .expired }
                switch try await qishuiAuth.pollQRCode(token: qr.token) {
                case .waiting: return .keepWaiting("等待使用汽水音乐扫码")
                case .scanned: return .keepWaiting("已扫码，请在汽水音乐中确认")
                case .processing: return .keepWaiting("正在等待平台完成登录，请稍候…")
                case .expired: return .expired
                case .confirmed(let credentials):
                    await finish(credentials: credentials, nickname: credentials["nickname"] ?? "汽水音乐用户")
                    return .done
                }
            }
        }
    }

    private enum PollStep {
        case keepWaiting(String)
        case done
        case expired
        case failed(String)
    }

    /// Polls `step` every 3 seconds. Transient network failures — the app
    /// being backgrounded while the user scans in the platform app — are
    /// tolerated instead of killing the login on the first failure; after 10
    /// in a row the loop pauses and scenePhase .active resumes it with the
    /// same QR session.
    private func pollLoop(_ step: () async throws -> PollStep) async {
        var consecutiveErrors = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            do {
                let outcome = try await step()
                consecutiveErrors = 0
                switch outcome {
                case .keepWaiting(let text):
                    status = text
                case .done:
                    return
                case .expired:
                    status = "二维码已过期，请刷新"
                    session = nil
                    return
                case .failed(let message):
                    status = message
                    session = nil
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 10 {
                    pollInterrupted = true
                    status = "网络异常，回到应用后将继续等待扫码"
                    return
                }
            }
        }
    }

    private func finish(credentials: [String: String], nickname: String) async {
        session = nil
        isSaving = true
        defer { isSaving = false }
        do {
            if addsAccount {
                let item = try await MusicAccountManager.shared.addAccount(provider: provider, credentials: credentials, nickname: nickname)
                ToastCenter.shared.show(MusicAccountManager.shared.addedMessage(for: item))
            } else {
                try await MusicAccountManager.shared.saveAndActivate(provider: provider, credentials: credentials, nickname: nickname)
            }
            dismiss()
        } catch { status = error.localizedDescription }
    }
    private static func qrImage(_ value: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: 200, height: 200))
        #else
        return UIImage(cgImage: cg)
        #endif
    }
}
