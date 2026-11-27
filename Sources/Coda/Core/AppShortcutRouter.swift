import Foundation
#if os(iOS)
import UIKit
#endif

/// Home-screen quick actions (long-press the app icon) — exactly three:
/// resume playback, my favorites, aggregate playlists. The app delegate
/// installs the items and forwards activations here; the main window
/// consumes them when it is up.
@MainActor
public final class AppShortcutRouter: ObservableObject {
    public static let shared = AppShortcutRouter()

    public enum Action: String, CaseIterable {
        case resume
        case favorites
        case aggregate

        public var shortcutType: String { "dragonmusic.shortcut.\(rawValue)" }

        public static func from(type: String) -> Action? {
            allCases.first { $0.shortcutType == type }
        }
    }

    @Published public private(set) var pending: Action?

    public func request(_ action: Action) {
        pending = action
    }

    public func consume() -> Action? {
        defer { pending = nil }
        return pending
    }

    #if os(iOS)
    /// Installs the three dynamic shortcut items shown on long-press.
    public static func installShortcutItems() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(type: Action.resume.shortcutType,
                                      localizedTitle: "继续播放",
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "play.fill"),
                                      userInfo: nil),
            UIApplicationShortcutItem(type: Action.favorites.shortcutType,
                                      localizedTitle: "我的收藏",
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "heart.fill"),
                                      userInfo: nil),
            UIApplicationShortcutItem(type: Action.aggregate.shortcutType,
                                      localizedTitle: "聚合歌单",
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "music.note.list"),
                                      userInfo: nil),
        ]
    }
    #endif
}
