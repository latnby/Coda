import SwiftUI
import CoreImage.CIFilterBuiltins

/// Owns the QR login session for QQ / Kugou / Qishui at app level.
///
/// The session used to live in the login sheet's view state. On a real
/// device, switching to the platform app to confirm and coming back can get
/// the sheet's view destroyed and recreated while the sheet stays presented
/// (its `@State` goes with it), which minted a brand-new QR code on return
/// and stranded the confirmation the user had just made — the login could
/// never complete. Keeping the session, the QR image, the status text and
/// the polling task here — in a store that outlives any view — means a
/// recreated sheet simply re-renders the in-flight session, and polling
/// keeps waiting on the SAME code until the server itself ends it.
@MainActor
final class PlatformLoginSessionStore: ObservableObject {
    static let shared = PlatformLoginSessionStore()

    @Published private(set) var image: PlatformImage?
    @Published private(set) var status = "正在获取二维码…"
    @Published private(set) var isSaving = false
    /// Bumped every time a login finishes saving; the presenting sheet
    /// observes it and dismisses itself.
    @Published private(set) var completedToken = 0

    let qishuiAuth = QishuiMusicAPI(diagnostics: true)
    private let qqAuth = QQMusicAuth(persistsSession: false)

    private enum Session {
        case qqMain
        case qqAdditional(QQMusicLoginChannel)
        case kugou(key: String)
        case qishui(QishuiMusicAPI.QRCode)
    }

    private enum Phase {
        case idle
        case active
        case finished
    }

    private(set) var provider: MusicProvider?
    private(set) var addsAccount = false
    private(set) var qqChannel: QQMusicLoginChannel = .qq
    private var session: Session?
    private var phase: Phase = .idle
    private var task: Task<Void, Never>?
    private var startedAt = Date.distantPast
    /// A session that somehow never hears back from the server is treated
    /// as expired after this long, so nothing polls forever.
    private let maxSessionAge: TimeInterval = 8 * 60

    /// Called by the sheet whenever it appears. A live session for the same
    /// provider is simply re-displayed — never restarted. Only the very
    /// first appearance (or one after an explicit cancel) starts a login.
    func attach(provider: MusicProvider, addsAccount: Bool, qqChannel: QQMusicLoginChannel) {
        if phase == .active {
            if self.provider == provider, self.addsAccount == addsAccount {
                if provider == .qq, self.qqChannel != qqChannel {
                    start(provider: provider, addsAccount: addsAccount, qqChannel: qqChannel)
                }
                return
            }
            start(provider: provider, addsAccount: addsAccount, qqChannel: qqChannel)
            return
        }
        if phase == .idle {
            start(provider: provider, addsAccount: addsAccount, qqChannel: qqChannel)
            return
        }
        // .finished for a different provider/mode: that outcome belongs to
        // another sheet; start fresh here. For the same provider, keep
        // showing the outcome (expired / failed) until the user explicitly
        // refreshes or cancels.
        if self.provider != provider || self.addsAccount != addsAccount {
            start(provider: provider, addsAccount: addsAccount, qqChannel: qqChannel)
        }
    }

    /// The 刷新二维码 button: the only in-sheet path that mints a new code.
    func refresh() {
        guard let provider else { return }
        start(provider: provider, addsAccount: addsAccount, qqChannel: qqChannel)
    }

    /// Switching the QQ channel abandons the current code, as before.
    func changeQQChannel(_ channel: QQMusicLoginChannel) {
        guard provider == .qq, channel != qqChannel else { return }
        start(provider: .qq, addsAccount: addsAccount, qqChannel: channel)
    }

    /// Explicit cancel from the sheet's 取消 button. View teardown does NOT
    /// call this — that is the whole point of the store.
    func cancel() {
        task?.cancel()
        task = nil
        session = nil
        phase = .idle
        provider = nil
        image = nil
        status = "正在获取二维码…"
        qishuiAuth.cancelLogin()
    }

    private func start(provider: MusicProvider, addsAccount: Bool, qqChannel: QQMusicLoginChannel) {
        task?.cancel()
        if self.provider == .qishui { qishuiAuth.cancelLogin() }
        self.provider = provider
        self.addsAccount = addsAccount
        self.qqChannel = qqChannel
        session = nil
        phase = .active
        startedAt = Date()
        task = Task {
            guard await fetchSession() else {
                if !Task.isCancelled { phase = .finished }
                return
            }
            await runSession()
        }
    }

    /// Fetches a fresh QR code and stores its session. Returns false when
    /// the fetch failed (status already shows why) or the task was cancelled.
    private func fetchSession() async -> Bool {
        guard let provider else { return false }
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
                    self.image = PlatformImage(data: data)
                    self.status = "等待使用\(channel.name)扫码"
                }, onScanned: {
                    self.status = "已扫码，请在\(channel.name)中确认"
                })
                try Task.checkCancellation()
                await finish(credentials: result.credentials, nickname: result.nickname)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    // This session lived inside the call and is gone with
                    // it; only an explicit refresh can mint a new code.
                    self.session = nil
                    phase = .finished
                    status = error.localizedDescription
                }
            }
        case .qqMain:
            await pollLoop {
                switch try await self.qqAuth.poll() {
                case .waiting: return .keepWaiting("等待扫码")
                case .scanned: return .keepWaiting("已扫码，请在 QQ 中确认")
                case .expired: return .expired
                case .error(let message): return .failed(message)
                case .success(let nickname):
                    await self.finish(credentials: self.qqAuth.exportedCredentials, nickname: nickname)
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
                    await self.finish(credentials: credentials, nickname: credentials["nickname"] ?? "酷狗音乐用户")
                    return .done
                }
            }
        case .qishui(let qr):
            await pollLoop {
                if self.qishuiAuth.isQRCodeExpired(token: qr.token) { return .expired }
                switch try await self.qishuiAuth.pollQRCode(token: qr.token) {
                case .waiting: return .keepWaiting("等待使用汽水音乐扫码")
                case .scanned: return .keepWaiting("已扫码，请在汽水音乐中确认")
                case .processing: return .keepWaiting("正在等待平台完成登录，请稍候…")
                case .expired: return .expired
                case .confirmed(let credentials):
                    await self.finish(credentials: credentials, nickname: credentials["nickname"] ?? "汽水音乐用户")
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

    /// Polls `step` every 3 seconds until the server ends the session.
    /// Transient failures — the app sitting backgrounded while the user
    /// confirms in the platform app, requests timing out or being cancelled
    /// by the system — never kill the login: the loop notes the problem and
    /// keeps waiting on the same code. Suspension freezes the task; when
    /// the app comes back to the foreground the loop simply continues.
    private func pollLoop(_ step: () async throws -> PollStep) async {
        var consecutiveErrors = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if Date().timeIntervalSince(startedAt) > maxSessionAge {
                status = "二维码已过期，请刷新"
                session = nil
                phase = .finished
                return
            }
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
                    phase = .finished
                    return
                case .failed(let message):
                    status = message
                    session = nil
                    phase = .finished
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors == 3 {
                    status = "网络异常，正在重试…"
                }
            }
        }
    }

    private func finish(credentials: [String: String], nickname: String) async {
        guard let provider else { return }
        session = nil
        phase = .finished
        isSaving = true
        defer { isSaving = false }
        do {
            if addsAccount {
                let item = try await MusicAccountManager.shared.addAccount(provider: provider, credentials: credentials, nickname: nickname)
                ToastCenter.shared.show(MusicAccountManager.shared.addedMessage(for: item))
            } else {
                try await MusicAccountManager.shared.saveAndActivate(provider: provider, credentials: credentials, nickname: nickname)
            }
            completedToken += 1
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

struct PlatformLoginSheet: View {
    let provider: MusicProvider
    /// Adds the scanned account to the list instead of switching to it.
    var addsAccount = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var store = PlatformLoginSessionStore.shared
    @ObservedObject private var qishuiAuth: QishuiMusicAPI
    @State private var qqChannel = QQMusicLoginChannel.qq

    init(provider: MusicProvider, addsAccount: Bool = false) {
        self.provider = provider
        self.addsAccount = addsAccount
        _qishuiAuth = ObservedObject(wrappedValue: PlatformLoginSessionStore.shared.qishuiAuth)
    }

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
                .disabled(store.isSaving)
                .onChange(of: qqChannel) { _ in store.changeQQChannel(qqChannel) }
            }
            Text(provider == .qishui ? "请使用已登录的汽水音乐 App 扫码并确认登录" : provider == .qq ? "请使用\(qqChannel.name)扫描二维码并确认登录" : "请使用酷狗音乐扫描二维码并确认登录")
                .font(Theme.Typography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            LoginQRCodeFrame(image: store.image) { EmptyView() }
            Text(store.status).font(Theme.Typography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("刷新二维码") { store.refresh() }
                .buttonStyle(.plain).font(Theme.Typography.caption).foregroundStyle(Theme.accent)
                .disabled(store.isSaving)
            Button("取消") { store.cancel(); dismiss() }
                .buttonStyle(.plain).font(Theme.Typography.caption).foregroundStyle(.secondary)
                .padding(.bottom, Theme.Spacing.section).disabled(store.isSaving)
        }
        .frame(width: 320)
        .interactiveDismissDisabled(store.isSaving)
        // The sheet is a dumb window onto the app-level session store: if
        // this view is destroyed and recreated (which is what used to reset
        // the QR code when returning from the platform app), appearing again
        // just re-attaches to the session that is still in flight.
        .onAppear {
            store.attach(provider: provider, addsAccount: addsAccount, qqChannel: qqChannel)
        }
        .onChange(of: store.completedToken) { _ in
            if store.provider == provider, store.addsAccount == addsAccount { dismiss() }
        }
        .sheet(isPresented: Binding(get: { qishuiAuth.verificationWebView != nil }, set: { if !$0 { qishuiAuth.cancelVerification() } })) {
            if let web = qishuiAuth.verificationWebView {
                QishuiSecurityVerificationView(webView: web, onCancel: { qishuiAuth.cancelVerification() })
            }
        }
    }
}
