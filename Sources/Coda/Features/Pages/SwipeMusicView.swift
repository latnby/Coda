import SwiftUI

/// 刷歌 — a vertical, full-screen music feed in the Douyin/Qishui style:
/// one song per page, swipe up for the next, swipe down for the previous,
/// and the song you land on plays. The feed belongs to whichever platform
/// the user is currently on; its category bar carries whatever
/// recommendation kinds that platform actually offers; and upcoming songs
/// are buffered ahead — the feed IS the player queue (so the queue
/// prefetcher downloads the next songs), artwork is pre-warmed, and the
/// next batch loads before the end is reached.
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
        player.play(tracks: model.tracks, source: .none, startAt: first)
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
        if idx >= model.tracks.count - 3 {
            Task {
                let added = await model.loadMore()
                if !added.isEmpty { player.queue.append(contentsOf: added) }
            }
        }
    }

    private func prewarm(around idx: Int) {
        for j in max(0, idx - 1)...min(model.tracks.count - 1, idx + 2) {
            if let url = model.tracks[j].album.picUrl?.resizedImageURL(768) {
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

/// One full-screen song page: blurred cover backdrop, the cover itself,
/// title/artist, a like button and — for the playing page — progress.
private struct SwipePage: View {
    let track: Track
    let isCurrent: Bool
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop(size: geo.size)
                VStack(spacing: 18) {
                    Spacer()
                    cover(size: min(320, geo.size.width - 88))
                    VStack(spacing: 6) {
                        Text(track.name)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text(track.artistNames)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    LikeButton(trackID: track.id, size: 25)
                    progressBar
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 118)
                if isCurrent && !player.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { player.togglePlayPause() }
    }

    private func backdrop(size: CGSize) -> some View {
        ZStack {
            Platform.windowBackgroundColor
            if let cover = track.album.picUrl?.resizedImageURL(384) {
                CachedAsyncImage(url: cover)
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(colorScheme == .dark ? 0.45 : 0.3)
                    .saturation(1.4)
            }
            LinearGradient(
                colors: [.clear, Platform.windowBackgroundColor.opacity(0.6)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func cover(size: CGFloat) -> some View {
        Group {
            if let url = track.album.picUrl?.resizedImageURL(768) {
                CachedAsyncImage(url: url)
            } else {
                Rectangle().fill(.quaternary.opacity(0.4))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 54, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.3)).frame(height: 3)
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
