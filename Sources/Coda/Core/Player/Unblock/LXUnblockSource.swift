import Foundation

/// The user-imported LX source (账号管理 → 洛雪音源）, tried as one more
/// mirror-class resolver: for a gray track it takes the matching song ID on
/// QQ / NetEase / KuGou — found through the app's own platform searches —
/// and asks the script for a stream URL, exactly like LX Music would.
struct LXUnblockSource: UnblockSource {
    let id = AudioSourceID.lx

    func isAvailable() async -> Bool {
        await MainActor.run { LXSourceStore.shared.activeSource != nil }
    }

    func isSignedIn() async -> Bool { false }

    func resolve(_ query: UnblockQuery, quality: AudioQuality) async throws -> UnblockStream? {
        guard let runtime = await MainActor.run(body: { LXSourceStore.shared.activeRuntime() }) else { return nil }
        for attempt in Self.attempts(for: query, declared: runtime.declaredSources) {
            guard let musicInfo = try? await Self.musicInfo(for: attempt, query: query) else { continue }
            guard let urlString = try? await runtime.musicURL(
                    source: attempt.code, musicInfo: musicInfo, type: Self.lxQuality(for: quality)),
                  let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https"
            else { continue }
            return UnblockStream(url: url, quality: quality,
                                 title: AudioQualityOption.unifiedTitle(quality: quality))
        }
        return nil
    }

    func qualityOptions(_ query: UnblockQuery) async throws -> [AudioQualityOption] {
        guard let runtime = await MainActor.run(body: { LXSourceStore.shared.activeRuntime() }),
              let attempt = Self.attempts(for: query, declared: runtime.declaredSources).first,
              let declared = runtime.declaredSources[attempt.code]
        else { return [] }
        var options: [AudioQualityOption] = []
        for tier in declared.qualitys {
            guard let quality = Self.audioQuality(forLXTier: tier),
                  !options.contains(where: { $0.quality == quality }) else { continue }
            options.append(.init(quality: quality, title: AudioQualityOption.unifiedTitle(quality: quality)))
        }
        return options
    }

    // MARK: - Platform attempts

    private struct Attempt {
        let platform: MusicProvider
        let code: String
    }

    /// Platforms the source can resolve for, other than the track's own,
    /// in QQ → NetEase → KuGou order.
    private static func attempts(for query: UnblockQuery, declared: [String: LXDeclaredSource]) -> [Attempt] {
        let all: [Attempt] = [
            Attempt(platform: .qq, code: "tx"),
            Attempt(platform: .netease, code: "wy"),
            Attempt(platform: .kugou, code: "kg"),
        ]
        return all.filter { $0.platform != query.origin && declared[$0.code]?.actions.contains("musicUrl") == true }
    }

    /// Builds the LX `musicInfo` for one platform from the app's own match.
    private static func musicInfo(for attempt: Attempt, query: UnblockQuery) async throws -> [String: Any]? {
        var info: [String: Any] = [
            "name": query.title,
            "singer": query.artists.joined(separator: "、"),
            "source": attempt.code,
            "albumName": query.album,
        ]
        switch attempt.platform {
        case .qq:
            let api = await UnblockSessionPool.shared.qqAPI()
            let song = try await UnblockMatchCache.shared.song(.qq, query) {
                try await api.searchSongs(keyword: query.keyword, limit: 10)
            }
            guard let mid = song?.qqMid, !mid.isEmpty else { return nil }
            info["songmid"] = mid
            info["id"] = mid
        case .netease:
            guard let songID = try await NeteaseSongLookup.shared.songID(for: query) else { return nil }
            info["id"] = songID
        case .kugou:
            let api = await UnblockSessionPool.shared.kugouAPI()
            let song = try await UnblockMatchCache.shared.song(.kugou, query) {
                try await api.searchSongs(keyword: query.keyword, limit: 10)
            }
            guard let hash = song?.kugouHash, !hash.isEmpty else { return nil }
            info["hash"] = hash
        case .qishui:
            return nil
        }
        return info
    }

    // MARK: - Quality mapping

    private static func lxQuality(for quality: AudioQuality) -> String {
        switch quality {
        case .standard: return "128k"
        case .higher, .exhigh: return "320k"
        case .lossless: return "flac"
        case .hires, .jyeffect, .sky, .jymaster: return "flac24bit"
        }
    }

    private static func audioQuality(forLXTier tier: String) -> AudioQuality? {
        switch tier.lowercased() {
        case "128k": return .standard
        case "192k": return .higher
        case "320k": return .exhigh
        case "flac": return .lossless
        case "flac24bit": return .hires
        default: return nil
        }
    }
}
