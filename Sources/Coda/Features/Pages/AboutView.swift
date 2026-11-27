import SwiftUI

/// Product information, updates, project links and notices, shown inline in
/// Settings. The disclaimer sheet is hosted on the Form by the caller.
struct AboutSections: View {
    @Binding var showsDisclaimer: Bool
    private let info = AppAboutInfo()

    var body: some View {
        Section {
            AboutHeader(info: info)

            Group {
                LabeledContent { Text(info.version) } label: { Label("版本", systemImage: "number") }
                LabeledContent { Text(info.build) } label: { Label("构建号", systemImage: "hammer") }
                if let commit = info.commit {
                    LabeledContent { Text(commit) } label: { Label("提交", systemImage: "arrow.triangle.branch") }
                }
                LabeledContent { Text(info.developer) } label: { Label("开发者", systemImage: "person") }
            }
            .textSelection(.enabled)

            AboutUpdateRows()

            AboutLinkRow(title: "问题反馈", systemImage: "exclamationmark.bubble", detail: nil,
                         url: URL(string: "https://b23.tv/HmhZ5zP")!)

            Button {
                showsDisclaimer = true
            } label: {
                Label("查看完整免责声明", systemImage: "exclamationmark.shield")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("关于")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("Dragon Music 是非官方的第三方客户端，与各音乐平台无关。音乐内容与数据均来自当前选择的音乐平台，版权归原权利人所有。")
            }
        }
    }
}

private struct AboutUpdateRows: View {
    @EnvironmentObject private var settings: SettingsManager
    #if os(macOS)
    @ObservedObject private var updater = UpdaterManager.shared
    #endif

    var body: some View {
        Toggle(isOn: $settings.autoCheckUpdates) {
            Label("启动时自动检查更新", systemImage: "clock.arrow.circlepath")
        }
        Button {
            #if os(iOS)
            IOSUpdater.shared.check(interactive: true)
            #else
            updater.checkForUpdates()
            #endif
        } label: {
            Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .disabled(!updater.canCheckForUpdates)
        #endif
    }
}

private struct AboutHeader: View {
    let info: AppAboutInfo

    var body: some View {
        VStack(spacing: 10) {
            AppIconImage()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(info.name)
                .font(.title2.bold())
            Text("多平台音乐客户端")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct AppIconImage: View {
    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
        #else
        if let icon = Self.primaryIcon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.tint)
        }
        #endif
    }

    #if os(iOS)
    private static let primaryIcon: UIImage? = {
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = Bundle.main.object(forInfoDictionaryKey: key) as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let name = (primary["CFBundleIconFiles"] as? [String])?.last,
                  let image = UIImage(named: name) else { continue }
            return image
        }
        return nil
    }()
    #endif
}

private struct AboutLinkRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let detail: String?
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(url.absoluteString))
    }
}
