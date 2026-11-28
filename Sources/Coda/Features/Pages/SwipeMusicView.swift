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
    @StateObject private var model = SwipeFeedModel()
    @State private var currentID: Int?
    @State private var feedLive = false

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
            feedLive = false
            await model.start(provider: account.provider)
            activateIfVisible()
        }
        .onChange(of: activeTab) { _, _ in activateIfVisible() }
        .onChange(of: currentID) { _, id in handlePageChange(id) }
        .onChange(of: player.currentTrack?.id) { _, id in
            // The song ended and the player advanced on its own: follow it.
            if let id, id != currentID, model.tracks.contains(where: { $0.id == id }) {
                currentID = id
            }
        }
    }

    // MARK: - Playback coordination

    /// Playback starts only when the tab is actually on screen: in the
    /// legacy tab layout every page exists from launch (behind opacity),
    /// and merely opening the app must not hijack whatever is playing.
    private func activateIfVisible() {
        guard activeTab == .swipe, account.hasAuthCookie, !model.tracks.isEmpty else { return }
        if feedLive, model.tracks.contains(where: { $0.id == player.queue.first?.id }) {
            if let id = player.currentTrack?.id, model.tracks.contains(where: { $0.id == id }) {
                currentID = id
            }
            return
        }
        beginPlayback(from: nil)
    }

    private func beginPlayback(from track: Track?) {
        guard let first = track ?? model.tracks.first else { return }
        player.play(tracks: model.tracks, source: .swipeFeed, startAt: first)
        feedLive = true
        currentID = first.id
    }

    private func handlePageChange(_ id: Int?) {
        guard let id, let idx = model.tracks.firstIndex(where: { $0.id == id }) else { return }
        let track = model.tracks[idx]
        if player.queue.contains(where: { $0.id == id }) {
            if player.currentTrack?.id != id { player.jumpTo(track) }
        } else if feedLive {
            beginPlayback(from: track)
        }
        prewarm(around: idx)
        if idx >= model.tracks.count - 6 {
            Task {
                let added = await model.loadMore()
                if !added.isEmpty { player.extendQueue(with: added) }
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
                        feedLive = false
                        await model.start(provider: account.provider)
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
                    SwipePage(track: track, isCurrent: track.id == currentID)
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
                            await model.select(category.id)
                            feedLive = false
                            activateIfVisible()
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
/// width) over a blurred-cover backdrop — NOT a full-bleed picture.
/// Tapping the artwork switches to lyrics: the artwork itself shrinks
/// into a small thumbnail at the top-left (the now-playing page's
/// gesture), the synced lyrics take the body over the frosted backdrop,
/// and tapping the thumbnail restores the big square.
@available(iOS 17.0, macOS 15.0, *)
private struct SwipePage: View {
    let track: Track
    let isCurrent: Bool
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme
    @State private var showLyrics = false

    var body: some View {
        GeometryReader { geo in
            let big = min(geo.size.width * 0.91, geo.size.height * 0.52)
            ZStack {
                backdrop
                VStack(alignment: .leading, spacing: 16) {
                    headerRow(big: big)
                    if showLyrics && isCurrent {
                        lyricsLayer
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 0)
                        titleBlock
                    }
                    controlsRow
                    progressBar
                }
                .padding(.horizontal, 20)
                .padding(.top, 104)
                .padding(.bottom, 118)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.easeInOut(duration: 0.32), value: showLyrics)
        .onChange(of: isCurrent) { _, current in
            if !current { showLyrics = false }
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
    private var lyricsLayer: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            AppleMusicLyricsColumn(lyrics: lyrics)
                .id(player.currentTrack?.id)
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
            if isCurrent {
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 27))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
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

    private var provider: MusicProvider = .netease
    private var generation = 0
    private var hasMore = true
    private var loadingMore = false
    private var dailyRefreshed = false
    private var qishuiScenes: [QishuiListeningScene] = QishuiListeningScene.preferences
    private var qishuiState: QishuiFeedState?

    func start(provider: MusicProvider) async {
        self.provider = provider
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
