import Foundation

/// A locally stored, cross-platform playlist （聚合歌单）.
///
/// Unlike platform playlists, an aggregate playlist belongs to no account:
/// every entry is a full `Track` snapshot that keeps the platform song it
/// was collected from, so playback always goes back to the origin platform
/// (and to the player's usual unblock fallback when that origin fails).
struct AggregatePlaylist: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var tracks: [Track]

    /// Same cover rule as other playlists: the first entry's artwork.
    var coverURLString: String? {
        tracks.first?.album.picUrl ?? tracks.first?.platformSong?.coverURL?.absoluteString
    }

    var sourceSummary: String {
        let names = Set(tracks.map(\.aggregateSourceName))
        return names.isEmpty ? "" : names.sorted().joined(separator: " · ")
    }
}

extension Track {
    /// Stable cross-platform identity used for duplicate checks.
    var aggregateIdentity: String {
        platformSong?.identityKey ?? "netease-\(id)"
    }

    /// Display name of the platform this track was collected from.
    var aggregateSourceName: String {
        switch platformSong?.source {
        case .qishui: return "汽水音乐"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗音乐"
        case .netease, nil: return "网易云音乐"
        }
    }
}

/// Owns every aggregate playlist. Persisted as JSON in UserDefaults; the
/// data is small (track snapshots only, no audio) and account-independent,
/// so the playlists survive provider sign-outs and account switches.
@MainActor
final class AggregatePlaylistStore: ObservableObject {
    static let shared = AggregatePlaylistStore()

    @Published private(set) var playlists: [AggregatePlaylist] = []

    private let defaultsKey = "aggregatePlaylists.v1"

    init() { load() }

    // MARK: - Playlist management

    @discardableResult
    func create(name: String) -> AggregatePlaylist {
        let playlist = AggregatePlaylist(id: UUID(), name: name, createdAt: Date(), tracks: [])
        playlists.append(playlist)
        save()
        return playlist
    }

    func rename(id: UUID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        save()
    }

    func delete(id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func movePlaylists(from source: IndexSet, to destination: Int) {
        playlists.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func playlist(id: UUID) -> AggregatePlaylist? {
        playlists.first { $0.id == id }
    }

    // MARK: - Track management

    enum AddResult { case added, duplicate }

    /// Adds one track snapshot. The same recording from the same platform
    /// is refused as a duplicate; the same song from another platform is a
    /// different entry and is allowed.
    @discardableResult
    func add(_ track: Track, to playlistID: UUID) -> AddResult {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return .duplicate }
        if playlists[index].tracks.contains(where: { $0.aggregateIdentity == track.aggregateIdentity }) {
            return .duplicate
        }
        playlists[index].tracks.append(track)
        save()
        return .added
    }

    func remove(trackIdentity: String, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].tracks.removeAll { $0.aggregateIdentity == trackIdentity }
        save()
    }

    func moveTracks(in playlistID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].tracks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func deleteTracks(in playlistID: UUID, at offsets: IndexSet) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].tracks.remove(atOffsets: offsets)
        save()
    }

    /// Bulk import of a whole platform playlist. Duplicates inside the
    /// incoming list collapse; returns the created playlist.
    @discardableResult
    func importPlaylist(name: String, tracks: [Track]) -> AggregatePlaylist {
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert($0.aggregateIdentity).inserted }
        let playlist = AggregatePlaylist(id: UUID(), name: name, createdAt: Date(), tracks: unique)
        playlists.append(playlist)
        save()
        return playlist
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([AggregatePlaylist].self, from: data) else { return }
        playlists = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
