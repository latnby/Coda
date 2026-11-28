import SwiftUI

/// 刷歌 — a vertical, full-screen music feed in the Douyin/Qishui style:
/// one song per page, swipe up for the next, swipe down for the previous,
/// and the song you land on plays. The feed belongs to whichever platform
/// the user is currently on; its category bar carries whatever
/// recommendation kinds that platform actually offers; and upcoming songs
/// are buffered ahead — the feed IS the player queue (so the queue
/// prefetcher downloads the next songs), artwork is pre-warmed, and the
/// next batch loads before the end is reached.
@available(iOS 17.0, macOS 15.0, *)
struct SwipeMusicView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openLogin) private var openLogin
    @Environment(\.activeIOSTab) private var activeTab
    @ObservedObject private var model = SwipeFeedModel.shared
    @State private var currentID: Int?

    /// The feed is live exactly when the player's queue is the feed's.
    /// The play source is the single source of truth: anything else the
    /// user plays, anywhere, turns the feed back into a silent browser.
    private var feedLive: Bool { player.source == .swipeFeed }

    private var feedKey: String { "\(account.provider.rawValue)-\(account.hasAuthCookie)" }

    var body: some View {
        ZStack(alignment: .top) {
            if account.hasAuthCookie {
                feedContent
                if !model.categories.isEmpty {
                    categoryBar
                }
            } else {
                loginPrompt
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: feedKey) {
            await model.start(provider: account.provider, scope: feedKey)
            if !model.tracks.contains(where: { $0.id == currentID }) {
                currentID = model.currentTrackID ?? model.tracks.first?.id
            }
            activateIfVisible()
        }
        .onChange(of: activeTab) { _, _ in activateIfVisible() }
        .onChange(of: currentID) { _, id in handlePageChange(id) }
        .onChange(of: player.currentTrack?.id) { _, id in
            // The song ended and the player advanced on its own: follow
            // it — but only while the feed owns playback.
            if feedLive, let id, id != currentID, model.tracks.contains(where: { $0.id == id }) {
                currentID = id
            }
        }
    }

    // MARK: - Playback coordination

    /// Playback starts only when the tab is actually on screen: in the
    /// legacy tab layout every page exists from launch (behind opacity),
    /// and merely opening the app must not hijack whatever is playing.
    /// Playback ownership, per Lon's rules: entering the feed NEVER
    /// hijacks music that is already loaded — the feed is a browser
    /// until he taps play on one of its songs. The one exception: when
    /// nothing is loaded at all, entering the feed starts it. And while
    /// the feed owns playback, leaving and returning changes nothing.
    private func activateIfVisible() {
        guard activeTab == .swipe, account.hasAuthCookie, !model.tracks.isEmpty else { return }
        if feedLive {
            if let id = player.currentTrack?.id, model.tracks.contains(where: { $0.id == id }) {
                currentID = id
            }
            return
        }
        guard player.currentTrack == nil else { return }
        beginPlayback(from: model.tracks.first(where: { $0.id == model.currentTrackID }) ?? model.tracks.first)
    }

    private func beginPlayback(from track: Track?) {
        guard let first = track ?? model.tracks.first else { return }
        player.play(tracks: model.tracks, source: .swipeFeed, startAt: first)
        model.currentTrackID = first.id
        currentID = first.id
    }

    private func handlePageChange(_ id: Int?) {
        guard let id, let idx = model.tracks.firstIndex(where: { $0.id == id }) else { return }
        model.currentTrackID = id
        let track = model.tracks[idx]
        // Swiping only changes the music while the feed owns playback;
        // otherwise it is silent browsing.
        if feedLive {
            if player.queue.contains(where: { $0.id == id }) {
                if player.currentTrack?.id != id { player.jumpTo(track) }
            } else {
                beginPlayback(from: track)
            }
        }
        prewarm(around: idx)
        if idx >= model.tracks.count - 6 {
            Task {
                let added = await model.loadMore()
                if feedLive, !added.isEmpty { player.extendQueue(with: added) }
            }
        }
    }

    private func prewarm(around idx: Int) {
        for j in max(0, idx - 1)...min(model.tracks.count - 1, idx + 5) {
            if let url = model.tracks[j].album.picUrl?.resizedImageURL(1080) {
                Task { _ = await ImageCache.shared.image(for: url) }
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var feedContent: some View {
        if model.isLoading && model.tracks.isEmpty {
            ProgressView("正在加载推荐")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.tracks.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(error)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    Task {
                        await model.start(provider: account.provider, scope: feedKey)
                        activateIfVisible()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.tracks.isEmpty {
            Text("暂无推荐")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            pager
        }
    }

    private var pager: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(model.tracks) { track in
                    SwipePage(track: track, isCurrent: track.id == currentID,
                              isPlayingThisFeed: feedLive,
                              onPlayRequest: { beginPlayback(from: track) })
                        .containerRelativeFrame(.vertical)
                        .id(track.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .ignoresSafeArea()
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.categories) { category in
                    let selected = model.selectedCategoryID == category.id
                    Button {
                        Task {
                            let wasLive = feedLive
                            await model.select(category.id)
                            if wasLive {
                                beginPlayback(from: nil)
                            } else {
                                activateIfVisible()
                            }
                        }
                    } label: {
                        Text(category.title)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background {
                                if selected {
                                    Capsule().fill(Color.primary)
                                } else {
                                    Capsule().fill(.ultraThinMaterial)
                                }
                            }
                            .foregroundStyle(selected ? Platform.windowBackgroundColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 6)
    }

    private var loginPrompt: some View {
        VStack(spacing: Theme.Spacing.component) {
            Image(systemName: "waveform")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("登录后开始刷歌")
                .font(Theme.Typography.cardTitle)
            Text("\(account.provider.name)会根据你的口味推荐歌曲，登录哪个号就刷哪个的")
                .font(Theme.Typography.secondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("登录") { openLogin() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One full-screen song page. The layout follows the reference Lon
/// picked from Qishui: a big rounded square (about 91% of the screen
/// width) over a blurred-cover backdrop, sitting clear of the category
/// bar, with the title, artist and controls directly beneath it.
/// Tapping the artwork switches to lyrics: the artwork shrinks into a
/// small thumbnail at the top-left, the synced lyrics play inside the
/// square's own box (feed-sized type that wraps — never off-screen),
/// and tapping the thumbnail restores the big square.
@available(iOS 17.0, macOS 15.0, *)
private struct SwipePage: View {
    let track: Track
    let isCurrent: Bool
    let isPlayingThisFeed: Bool
    let onPlayRequest: () -> Void
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme
    @State private var showLyrics = false
    @State private var aggregateAddTrack: Track?

    var body: some View {
        GeometryReader { geo in
            let big = min(geo.size.width * 0.91, geo.size.height * 0.46)
            ZStack {
                backdrop
                VStack(alignment: .center, spacing: 0) {
                    headerRow(big: big)
                    if showLyrics && isCurrent {
                        lyricsBox
                            .frame(width: big, height: big)
                            .padding(.top, 16)
                    } else {
                        titleBlock
                            .padding(.top, 18)
                    }
                    controlsRow
                        .padding(.top, 16)
                    progressBar
                        .padding(.top, 14)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, geo.size.height * 0.15)
                .padding(.bottom, 118)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.easeInOut(duration: 0.32), value: showLyrics)
        .onChange(of: isCurrent) { _, current in
            if !current { showLyrics = false }
        }
        .sheet(item: $aggregateAddTrack) { selected in
            AggregateAddSheet(track: selected)
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            Platform.windowBackgroundColor
            if let url = track.album.picUrl?.resizedImageURL(300) {
                CachedAsyncImage(url: url)
                    .scaledToFill()
                    .blur(radius: 40)
                    .opacity(colorScheme == .dark ? 0.55 : 0.4)
            }
            Platform.windowBackgroundColor.opacity(0.55)
        }
        .ignoresSafeArea()
    }

    // MARK: - Header (artwork + compact titles in lyrics mode)

    private func headerRow(big: CGFloat) -> some View {
        HStack(spacing: 12) {
            artwork(size: showLyrics ? 54 : big)
            if showLyrics {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: showLyrics ? .leading : .center)
    }

    private func artwork(size: CGFloat) -> some View {
        Group {
            if let url = track.album.picUrl?.resizedImageURL(1080) {
                CachedAsyncImage(url: url).scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: showLyrics ? 18 : 54, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: showLyrics ? 10 : 24, style: .continuous))
        .shadow(color: .black.opacity(showLyrics ? 0.15 : 0.3), radius: showLyrics ? 8 : 24, y: showLyrics ? 3 : 12)
        .contentShape(Rectangle())
        .onTapGesture {
            // Only the playing page has live lyrics to show.
            guard isCurrent else { return }
            withAnimation(.easeInOut(duration: 0.32)) { showLyrics.toggle() }
        }
    }

    // MARK: - Lyrics

    @ViewBuilder
    private var lyricsBox: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            FeedLyricsView(lyrics: lyrics, cursor: player.lyricsCursor)
        } else if player.lyrics?.isInstrumental == true {
            centeredNote("纯音乐，请欣赏")
        } else if player.lyrics != nil {
            centeredNote("暂无歌词")
        } else {
            centeredNote("歌词加载中…")
        }
    }

    private func centeredNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.secondary)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Titles and controls

    private var titleBlock: some View {
        VStack(spacing: 5) {
            Text(track.name)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(track.artistNames)
                .font(Theme.Typography.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var controlsRow: some View {
        HStack(spacing: 34) {
            LikeButton(trackID: track.id, size: 25)
            Button { playAction() } label: {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 27))
            }
            .buttonStyle(.plain)
            Button { aggregateAddTrack = track } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    /// The play button: while the feed owns playback it pauses/resumes
    /// or jumps within the feed queue; while anything else owns it, it
    /// is the explicit tap that hands playback to this feed song.
    private func playAction() {
        if isPlayingThisFeed && player.queue.contains(where: { $0.id == track.id }) {
            if isCurrent {
                player.togglePlayPause()
            } else {
                player.jumpTo(track)
            }
        } else {
            onPlayRequest()
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 3)
                if isCurrent && player.duration > 0 {
                    Capsule().fill(.primary)
                        .frame(width: geo.size.width * min(1, max(0, player.progress / player.duration)), height: 3)
                }
            }
        }
        .frame(height: 3)
    }
}

/// Synced lyrics sized for the feed: type that wraps to the box width
/// (never off-screen), the active line bold, auto-scrolling with the
/// song. The now-playing page's lyrics column is tuned for its own
/// full-screen layout and overflows this box, so the feed has its own.
@available(iOS 17.0, macOS 15.0, *)
private struct FeedLyricsView: View {
    let lyrics: ParsedLyrics
    @ObservedObject var cursor: LyricsCursor

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(lyrics.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.text.isEmpty ? "· · ·" : line.text)
                                .font(isActive(line) ? .system(size: 19, weight: .bold) : .system(size: 17))
                                .foregroundStyle(isActive(line) ? Color.primary : Color.secondary)
                            if let translation = line.translation, !translation.isEmpty {
                                Text(translation)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(line.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.07),
                    .init(color: .black, location: 0.93),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            .onAppear { scrollToActive(proxy, animated: false) }
            .onChange(of: cursor.activeIndex) { _, _ in scrollToActive(proxy, animated: true) }
        }
    }

    private func isActive(_ line: LyricLine) -> Bool {
        guard let idx = cursor.activeIndex, lyrics.lines.indices.contains(idx) else { return false }
        return lyrics.lines[idx].id == line.id
    }

    private func scrollToActive(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let idx = cursor.activeIndex, lyrics.lines.indices.contains(idx) else { return }
        let id = lyrics.lines[idx].id
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// The feed's data: categories are whatever the current platform offers,
/// batches append without duplicates, and a generation counter keeps a
/// slow load from landing after the user switched category or platform.
@MainActor
private final class SwipeFeedModel: ObservableObject {
    struct Category: Identifiable, Hashable {
        let id: String
        let title: String
    }

    @Published private(set) var categories: [Category] = []
    @Published private(set) var selectedCategoryID: String?
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// The page the feed was last on. The model is shared, so this
    /// survives the page view being recreated on tab switches.
    @Published var currentTrackID: Int?

    static let shared = SwipeFeedModel()
    private var loadedScope: String?

    private var provider: MusicProvider = .netease
    private var generation = 0
    private var hasMore = true
    private var loadingMore = false
    private var dailyRefreshed = false
    private var qishuiScenes: [QishuiListeningScene] = QishuiListeningScene.preferences
    private var qishuiState: QishuiFeedState?

    func start(provider: MusicProvider, scope: String) async {
        // Already loaded for this account scope: a tab switch recreates
        // the view, not the feed — keep the songs and the position.
        if loadedScope == scope, !tracks.isEmpty { return }
        loadedScope = scope
        self.provider = provider
        currentTrackID = nil
        generation += 1
        let gen = generation
        tracks = []
        errorMessage = nil
        hasMore = true
        dailyRefreshed = false
        qishuiState = nil
        qishuiScenes = QishuiListeningScene.preferences
        categories = Self.categories(for: provider, scenes: qishuiScenes)
        selectedCategoryID = categories.first?.id
        if provider == .qishui {
            await refreshScenes(generation: gen)
        }
        await reload(generation: gen)
    }

    func select(_ categoryID: String) async {
        guard categoryID != selectedCategoryID else { return }
        generation += 1
        let gen = generation
        selectedCategoryID = categoryID
        tracks = []
        currentTrackID = nil
        errorMessage = nil
        hasMore = true
        dailyRefreshed = false
        qishuiState = nil
        if provider == .qq && categoryID == "radio" {
            PlatformMusicAPI.shared.resetQQFM()
        }
        await reload(generation: gen)
    }

    /// Appends the next batch; returns the tracks that were actually added
    /// so the caller can extend the player's queue with the same songs.
    func loadMore() async -> [Track] {
        guard hasMore, !loadingMore, !tracks.isEmpty else { return [] }
        loadingMore = true
        defer { loadingMore = false }
        let gen = generation
        do {
            let batch = try await fetchBatch()
            guard gen == generation else { return [] }
            let known = Set(tracks.map(\.id))
            let fresh = batch.filter { !known.contains($0.id) }
            if fresh.isEmpty { hasMore = false }
            tracks.append(contentsOf: fresh)
            return fresh
        } catch {
            return []
        }
    }

    private func reload(generation gen: Int) async {
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let batch = try await fetchBatch()
            guard gen == generation else { return }
            var seen = Set<Int>()
            tracks = batch.filter { seen.insert($0.id).inserted }
            if tracks.isEmpty { hasMore = false }
        } catch {
            guard gen == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func refreshScenes(generation gen: Int) async {
        guard let scenes = try? await QishuiMusicAPI.shared.listeningScenes(), !scenes.isEmpty else { return }
        guard gen == generation else { return }
        qishuiScenes = scenes
        categories = Self.categories(for: .qishui, scenes: scenes)
        if !categories.contains(where: { $0.id == selectedCategoryID }) {
            selectedCategoryID = categories.first?.id
        }
    }

    private static func categories(for provider: MusicProvider, scenes: [QishuiListeningScene]) -> [Category] {
        switch provider {
        case .netease:
            return [.init(id: "daily", title: "每日推荐"),
                    .init(id: "fm", title: "私人FM")]
        case .qq:
            return [.init(id: "guess", title: "猜你喜欢"),
                    .init(id: "daily", title: "每日推荐"),
                    .init(id: "radio", title: "电台雷达")]
        case .kugou:
            return [.init(id: "daily", title: "每日推荐"),
                    .init(id: "fm", title: "私人FM")]
        case .qishui:
            return scenes.map { .init(id: $0.mode, title: $0.title) }
        }
    }

    private func fetchBatch() async throws -> [Track] {
        switch provider {
        case .netease:
            if selectedCategoryID == "fm" {
                var out: [Track] = []
                for _ in 0..<6 where out.count < 18 {
                    out.append(contentsOf: try await NeteaseAPI.personalFM())
                }
                return out
            }
            if tracks.isEmpty {
                return try await NeteaseAPI.dailyRecommendSongs()
            }
            if !dailyRefreshed {
                dailyRefreshed = true
                return try await NeteaseAPI.dailyRecommendSongs(afresh: true)
            }
            hasMore = false
            return []
        case .qq:
            switch selectedCategoryID {
            case "daily":
                if tracks.isEmpty {
                    return try await PlatformMusicAPI.shared.qqDailySongs()
                }
                hasMore = false
                return []
            case "radio":
                return try await PlatformMusicAPI.shared.recommendations(fm: true)
            default:
                return try await PlatformMusicAPI.shared.recommendations(fm: false)
            }
        case .kugou:
            return try await PlatformMusicAPI.shared.recommendations(fm: selectedCategoryID == "fm")
        case .qishui:
            guard let scene = qishuiScenes.first(where: { $0.mode == selectedCategoryID }) else { return [] }
            if let state = qishuiState {
                let page = try await QishuiMusicAPI.shared.continueFeed(
                    state,
                    excluding: Set(tracks.compactMap { $0.platformSong?.qishui?.trackID }),
                    played: [])
                qishuiState = page.state
                if !page.state.hasMore { hasMore = false }
                return try PlatformMusicAPI.shared.tracks(page.songs)
            }
            let page = try await QishuiMusicAPI.shared.feedPage(
                QishuiMusicAPI.shared.feedState(.scene(scene)))
            qishuiState = page.state
            if !page.state.hasMore { hasMore = false }
            return try PlatformMusicAPI.shared.tracks(page.songs)
        }
    }
}
