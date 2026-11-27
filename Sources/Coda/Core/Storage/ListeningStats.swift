import Foundation

/// One finished listening session, recorded locally by the player when a
/// track ends or is skipped away from. The listening report aggregates
/// these across every platform — nothing leaves the device.
struct ListeningPlayEvent: Codable, Hashable {
    var identity: String
    var name: String
    var artists: String
    var providerRaw: String
    var startedAt: Date
    var listenedSeconds: Double
}

/// Local, cross-platform listening history behind the report page. Events
/// are kept for a rolling 400 days, which covers the 本周 / 本月 / 今年
/// windows the report shows.
@MainActor
final class ListeningStatsStore: ObservableObject {
    static let shared = ListeningStatsStore()

    @Published private(set) var events: [ListeningPlayEvent] = []

    private let fileURL: URL
    private let maxEvents = 6000

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("listening-stats.json")
        load()
    }

    func record(track: Track, listenedSeconds: Double, startedAt: Date) {
        let provider = MusicProvider(rawValue: track.platformSong?.source.rawValue ?? "netease") ?? .netease
        events.append(ListeningPlayEvent(
            identity: track.aggregateIdentity, name: track.name, artists: track.artistNames,
            providerRaw: provider.rawValue, startedAt: startedAt, listenedSeconds: listenedSeconds))
        let cutoff = Date().addingTimeInterval(-400 * 24 * 3600)
        events.removeAll { $0.startedAt < cutoff }
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        save()
    }

    // MARK: - Aggregation

    enum Period: String, CaseIterable {
        case week = "本周"
        case month = "本月"
        case year = "今年"
    }

    struct SongStat: Identifiable {
        var id: String
        var name: String
        var artists: String
        var plays: Int
        var seconds: Double
    }

    struct ArtistStat: Identifiable {
        var id: String
        var name: String
        var plays: Int
        var seconds: Double
    }

    struct PlatformShare: Identifiable {
        var provider: MusicProvider
        var seconds: Double
        var id: String { provider.rawValue }
    }

    struct Summary {
        var totalSeconds: Double = 0
        var playCount: Int = 0
        var activeDays: Int = 0
        var topSongs: [SongStat] = []
        var topArtists: [ArtistStat] = []
        var platformShares: [PlatformShare] = []
        var peakHour: Int?
    }

    func summary(for period: Period, now: Date = Date()) -> Summary {
        let calendar = Calendar.current
        let interval: DateInterval?
        switch period {
        case .week: interval = calendar.dateInterval(of: .weekOfYear, for: now)
        case .month: interval = calendar.dateInterval(of: .month, for: now)
        case .year: interval = calendar.dateInterval(of: .year, for: now)
        }
        guard let interval else { return Summary() }
        let inPeriod = events.filter { interval.contains($0.startedAt) }
        var result = Summary()
        result.totalSeconds = inPeriod.reduce(0) { $0 + $1.listenedSeconds }
        // A play counts once the song actually played for half a minute;
        // skipped-past songs still add their seconds to the total time.
        let plays = inPeriod.filter { $0.listenedSeconds >= 30 }
        result.playCount = plays.count
        result.activeDays = Set(inPeriod.map { calendar.startOfDay(for: $0.startedAt) }).count
        var songs: [String: SongStat] = [:]
        for event in plays {
            var stat = songs[event.identity] ?? SongStat(id: event.identity, name: event.name,
                                                         artists: event.artists, plays: 0, seconds: 0)
            stat.plays += 1
            stat.seconds += event.listenedSeconds
            songs[event.identity] = stat
        }
        result.topSongs = Array(songs.values.sorted { $0.seconds > $1.seconds }.prefix(5))
        var artists: [String: ArtistStat] = [:]
        for event in plays where !event.artists.isEmpty {
            var stat = artists[event.artists] ?? ArtistStat(id: event.artists, name: event.artists,
                                                            plays: 0, seconds: 0)
            stat.plays += 1
            stat.seconds += event.listenedSeconds
            artists[event.artists] = stat
        }
        result.topArtists = Array(artists.values.sorted { $0.seconds > $1.seconds }.prefix(5))
        var perPlatform: [String: Double] = [:]
        for event in inPeriod { perPlatform[event.providerRaw, default: 0] += event.listenedSeconds }
        result.platformShares = perPlatform.compactMap { pair in
            MusicProvider(rawValue: pair.key).map { PlatformShare(provider: $0, seconds: pair.value) }
        }.sorted { $0.seconds > $1.seconds }
        var hours: [Int: Double] = [:]
        for event in inPeriod {
            hours[calendar.component(.hour, from: event.startedAt), default: 0] += event.listenedSeconds
        }
        result.peakHour = hours.max { $0.value < $1.value }?.key
        return result
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ListeningPlayEvent].self, from: data) else { return }
        events = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
