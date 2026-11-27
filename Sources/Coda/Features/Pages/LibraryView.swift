import SwiftUI

// The same library page is used by phone tabs and compact windows.

struct LibraryView: View {
    @Binding var showLogin: Bool
    @Environment(\.openDestination) private var openDestination
    @EnvironmentObject private var account: AccountStore
    @State private var showSettings = false
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @StateObject private var profileDetail = PanelResource<NeteaseAPI.UserDetailResponse?>(nil)
    /// Global frame of the profile hero's avatar slot, reported by the hero
    /// itself; the Dynamic Island dock overlay follows it while scrolling.
    @State private var profileAvatarFrame: CGRect = .zero

    var phoneLayout = PhonePageLayout()
    private var isPhone: Bool { phoneLayout.isEnabled }

    private var phoneCreatedPlaylists: [PlaylistSummary] {
        guard let liked = account.likedSongsPlaylist else { return account.createdPlaylists }
        return [liked] + account.createdPlaylists.filter { $0.id != liked.id }
    }

    var body: some View {
        Group {
            if isPhone {
                phonePage
            } else {
                tabletPage
            }
        }
        .textCase(nil)
        .appRootNavigationTitle(String(localized: "我的"))
        .panelRefresh(key: "ios-library:\(account.sessionRevision):\(account.libraryRevision):\(SidebarResources.playbackRevision)") { force in
            guard account.provider.supports(.profileStatistics), let uid = account.authenticatedAccountID else {
                profileDetail.reset()
                await account.refreshLibrary(force: force)
                if account.provider.supports(.collectionArtists) { await account.refreshSublists(force: force) }
                return
            }
            await profileDetail.load(lifetime: 60,
                                     key: "\(account.libraryRevision):\(SidebarResources.playbackRevision)",
                                     force: force) {
                try await NeteaseAPI.userDetail(uid: uid)
            }
            if isPhone {
                await account.refreshSublists(force: force)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("设置")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") {
                                showSettings = false
                            }
                        }
                    }
            }
            .environment(\.openDestination, { destination in
                showSettings = false
                openDestination(destination)
            })
        }
        .alert("新建歌单", isPresented: $showNewPlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                newPlaylistName = ""
                guard !name.isEmpty else { return }
                Task {
                    do {
                        try await NeteaseAPI.createPlaylist(name: name, isPrivate: false)
                        await account.refreshLibrary()
                        ToastCenter.shared.show(String(localized: "歌单已创建"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
            Button("取消", role: .cancel) { newPlaylistName = "" }
        }
    }

    private var phonePage: some View {
        ZStack(alignment: .top) {
        ProfileDetailPage() {
            if account.provider.supports(.accountSync) { SyncedLoginButtons() }
            if let profile = account.profile {
                ProfileIslandHero(
                    artworkURL: profile.avatarUrl,
                    title: profile.nickname,
                    subtitle: profileSubtitle,
                    metadataText: profileMetadata
                ) {
                    profileActions
                }
            } else {
                ProfileIslandHero(artworkURL: nil, title: String(localized: "我的"),
                                        subtitle: String(localized: "登录\(account.provider.name)"),
                                        metadataText: String(localized: "同步我喜欢的音乐、歌单与收藏")) {
                    VStack(spacing: 16) {
                        Button("登录\(account.provider.name)") { showLogin = true }
                        profileActions
                    }
                }
            }
            if account.hasAuthCookie {
                HStack {
                    SectionHeader(title: LocalizedStringKey(account.provider.playlistSectionTitle), action: {
                        openDestination(.librarySection(.createdPlaylists))
                    })
                    Spacer()
                    Button { showNewPlaylist = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新建歌单")
                    .disabled(!account.provider.supports(.playlistCreation))
                }
                .padding(.horizontal, 16)
                playlistShelf(phoneCreatedPlaylists)
                if account.provider.supports(.playlistSubscriptions) || !account.subscribedPlaylists.isEmpty {
                    SectionHeader(title: "收藏的歌单", action: {
                        openDestination(.librarySection(.subscribedPlaylists))
                    }).padding(.horizontal, 16)
                    if account.subscribedPlaylists.isEmpty {
                        emptyNote("暂无收藏歌单").padding(.horizontal, 16)
                    } else {
                        playlistShelf(account.subscribedPlaylists)
                    }
                }
                if account.provider.supports(.collectionAlbums) || !account.likedAlbums.isEmpty {
                    SectionHeader(title: "收藏的专辑", action: {
                        openDestination(.librarySection(.albums))
                    }).padding(.horizontal, 16)
                    if account.likedAlbums.isEmpty {
                        emptyNote(collectionEmptyMessage("还没有收藏专辑")).padding(.horizontal, 16)
                    } else {
                    ProfileDetailCoverShelf(itemCount: account.likedAlbums.count, resetKey: account.likedAlbums.first?.id) { visibleCount in
                        ForEach(account.likedAlbums.prefix(visibleCount)) { album in
                            NavigationLink(value: Destination.album(album.id)) {
                                CoverCardBody(coverURL: album.picUrl?.resizedImageURL(384),
                                              title: album.name, subtitle: album.artistName)
                            }
                            .buttonStyle(.interactiveCard)
                        }
                    }
                    }
                }
                if account.provider.supports(.collectionArtists) || !account.likedArtists.isEmpty {
                    SectionHeader(title: "收藏的歌手", action: {
                        openDestination(.librarySection(.artists))
                    }).padding(.horizontal, 16)
                    if account.likedArtists.isEmpty {
                        emptyNote(collectionEmptyMessage("还没有收藏歌手")).padding(.horizontal, 16)
                    } else {
                    ProfileDetailCoverShelf(itemCount: account.likedArtists.count, resetKey: account.likedArtists.first?.id) { visibleCount in
                        ForEach(account.likedArtists.prefix(visibleCount)) { artist in
                            NavigationLink(value: Destination.artist(artist.id)) {
                                ProfileDetailArtistCardBody(artist: artist)
                            }
                            .buttonStyle(.interactiveCard)
                        }
                    }
                    }
                }
            }
            PlayerClearanceSpacer()
        }
        ProfileIslandDockOverlay(avatarURL: account.profile?.avatarUrl, avatarFrame: profileAvatarFrame)
        }
        .onPreferenceChange(ProfileAvatarFrameKey.self) { profileAvatarFrame = $0 }
    }

    private var profileSubtitle: String {
        if account.provider.supports(.profileStatistics) {
            return "Lv.\(profileDetail.value?.level.map(String.init) ?? "—") · 累计听歌 \(profileDetail.value?.listenSongs?.formatted() ?? "—") 首"
        }
        return account.provider.name
    }

    private var profileMetadata: String {
        if account.provider.supports(.profileStatistics) {
            return "\(profileDetail.value?.profile?.follows?.formatted() ?? "—") 关注 · \(profileDetail.value?.profile?.followeds?.formatted() ?? "—") 粉丝 · \(profileDetail.value?.profile?.playlistCount?.formatted() ?? "—") 歌单"
        }
        return String(localized: "\(account.userPlaylists.count) 个歌单")
    }

    private var profileActions: some View {
        let hasHistory = account.provider.supports(.recentPlays)
        return PlaylistPrimaryActions(
            isSaved: false, canSave: account.provider.supports(.cloud),
            canPlay: hasHistory || account.likedSongsPlaylist != nil || !account.hasAuthCookie, isSaving: false,
            onToggleSaved: { openPhoneShortcut(.cloud) },
            onPlayAll: {
                if hasHistory { openPhoneShortcut(.recents) }
                else if let liked = account.likedSongsPlaylist { openPhoneShortcut(.playlist(liked.id)) }
                else { showLogin = true }
            },
            leadingIcon: "icloud.fill", primaryTitle: hasHistory ? "最近" : "我喜欢的音乐",
            primaryIcon: hasHistory ? "clock.fill" : "heart.fill",
            showsSaveButton: account.provider.supports(.cloud),
            saveAccessibilityLabel: String(localized: "云盘"),
            saveAccessibilityIdentifier: "profileCloud"
        ) {
            Menu { profileMoreActions } label: { PlaylistMoreLabel() }
                .accessibilityLabel("更多操作")
        }
    }

    private func openPhoneShortcut(_ destination: Destination, requiresLogin: Bool = true) {
        if requiresLogin && !account.hasAuthCookie {
            showLogin = true
        } else {
            openDestination(destination)
        }
    }

    private var tabletPage: some View {
        List {
            // Profile / Login header
            Section {
                if account.provider.supports(.accountSync) { SyncedLoginButtons() }
                if let profile = account.profile {
                    profileHeader(profile)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0))
                        .listRowBackground(Color.clear)
                } else {
                    Button {
                        showLogin = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 32))
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("登录\(account.provider.name)")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("同步我喜欢的音乐、歌单与收藏")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    guestProfileShortcuts
                        .font(.system(size: 16, weight: .semibold))
                        .buttonStyle(.pressable)
                        .listRowSeparator(.hidden)
                }
            }

            if account.hasAuthCookie {
                Section("我的音乐") {
                    if let liked = account.likedSongsPlaylist {
                        NavigationLink(value: Destination.playlist(liked.id)) {
                            Label("我喜欢的音乐", systemImage: "heart.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            if account.hasAuthCookie {
                if !account.createdPlaylists.isEmpty || account.provider.supports(.playlistCreation) {
                    Section {
                        if account.createdPlaylists.isEmpty {
                            Text("还没有创建歌单").foregroundStyle(.secondary)
                        } else {
                            playlistShelf(account.createdPlaylists)
                        }
                    } header: {
                        HStack {
                            SectionHeader(title: LocalizedStringKey(account.provider.playlistSectionTitle), action: {
                        openDestination(.librarySection(.createdPlaylists))
                    })
                            Spacer()
                            Button {
                                showNewPlaylist = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .accessibilityLabel("新建歌单")
                            .disabled(!account.provider.supports(.playlistCreation))
                        }
                    }
                }

                if account.provider.supports(.playlistSubscriptions) || !account.subscribedPlaylists.isEmpty {
                    Section {
                        if account.subscribedPlaylists.isEmpty {
                            emptyNote("暂无收藏歌单")
                        } else {
                            playlistShelf(account.subscribedPlaylists)
                        }
                    } header: {
                        SectionHeader(title: "收藏的歌单", action: {
                        openDestination(.librarySection(.subscribedPlaylists))
                    })
                    }
                }

                if isPhone {
                    if account.provider.supports(.collectionAlbums) || !account.likedAlbums.isEmpty {
                        Section {
                            if account.likedAlbums.isEmpty {
                                emptyNote(collectionEmptyMessage("还没有收藏专辑"))
                            } else {
                            collectionShelf(count: account.likedAlbums.count) { visibleCount in
                                ForEach(account.likedAlbums.prefix(visibleCount)) { album in
                                    NavigationLink(value: Destination.album(album.id)) {
                                        CoverCardBody(coverURL: album.picUrl?.resizedImageURL(384),
                                                      title: album.name, subtitle: album.artistName)
                                    }
                                    .buttonStyle(.interactiveCard)
                                }
                            }
                            }
                        } header: {
                            SectionHeader(title: "收藏的专辑", action: {
                        openDestination(.librarySection(.albums))
                    })
                        }
                    }

                    if account.provider.supports(.collectionArtists) || !account.likedArtists.isEmpty {
                        Section {
                            if account.likedArtists.isEmpty {
                                emptyNote(collectionEmptyMessage("还没有收藏歌手"))
                            } else {
                            collectionShelf(count: account.likedArtists.count) { visibleCount in
                                ForEach(account.likedArtists.prefix(visibleCount)) { artist in
                                    NavigationLink(value: Destination.artist(artist.id)) {
                                        ProfileDetailArtistCardBody(artist: artist)
                                    }
                                    .buttonStyle(.interactiveCard)
                                }
                            }
                            }
                        } header: {
                            SectionHeader(title: "收藏的歌手", action: {
                        openDestination(.librarySection(.artists))
                    })
                        }
                    }
                }
            }

            Section {
                PlayerClearanceSpacer()
                    .listRowBackground(Color.clear)
            }
        }
    }

    /// A load failure (such as an expired login) replaces the plain empty message.
    private func collectionEmptyMessage(_ empty: String.LocalizationValue) -> String {
        account.sublistsError ?? String(localized: empty)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.secondary)
            .foregroundStyle(.secondary)
            .padding(.vertical, Theme.Spacing.control)
    }

    private func emptyNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Theme.Typography.secondary)
            .foregroundStyle(.secondary)
            .padding(.vertical, Theme.Spacing.control)
    }

    private func collectionShelf<Content: View>(count: Int, @ViewBuilder content: @escaping (Int) -> Content) -> some View {
        ProfileDetailCoverShelf(itemCount: count, content: content)
            .padding(.vertical, 8)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func playlistShelf(_ playlists: [PlaylistSummary]) -> some View {
        ProfileDetailCoverShelf(itemCount: playlists.count, resetKey: playlists.first?.id) { visibleCount in
            ForEach(playlists.prefix(visibleCount)) { playlist in
                NavigationLink(value: Destination.playlist(playlist.id)) {
                    PlaylistCoverCard(playlist: playlist, subtitle: "\(playlist.trackCount) 首")
                }
                .buttonStyle(.interactiveCard)
            }
        }
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func profileHeader(_ profile: UserProfile) -> some View {
        MusicLibraryHeaderLayout(title: profile.nickname, icon: nil, coverURL: profile.avatarUrl,
                                 circularCover: true, usesPlaylistActions: true) {
            EmptyView()
        } metadata: {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { listeningStatistics }
                    VStack(alignment: .leading, spacing: 4) { listeningStatistics }
                }
                Text("用户 ID \(account.displayUserID)")
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Text(profileMetadata)
                    .fixedSize(horizontal: false, vertical: true)
                if profileDetail.error != nil {
                    Button("账户统计加载失败，点此重试") {
                        Task {
                            await profileDetail.load(lifetime: 1800, force: true) {
                                try await NeteaseAPI.userDetail(uid: profile.userId)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        } actions: {
            profileActions
        }
    }

    private var guestProfileShortcuts: some View {
        profileActions
    }

    @ViewBuilder
    private var profileMoreActions: some View {
        if (account.provider.supports(.collectionAlbums) || account.provider.supports(.collectionArtists)), !isPhone {
            Button { openPhoneShortcut(.collections) } label: {
                Label("我的收藏", systemImage: "star")
            }
        }
        if account.provider.supports(.playRanking), isPhone {
            Button { openPhoneShortcut(.playRanking) } label: {
                Label("播放排行", image: "ProfilePlayRanking")
            }
        }
        if account.provider.supports(.downloads) {
        Button { openPhoneShortcut(.downloaded, requiresLogin: false) } label: {
            if isPhone {
                Label("我的下载", image: "ProfileDownloads")
            } else {
                Label("下载", systemImage: "arrow.down.circle.fill")
            }
        }
        }
        if account.isLoggedIn {
            Button(role: .destructive) {
                Task {
                    do { try await account.logout() }
                    catch { ToastCenter.shared.show(error.localizedDescription) }
                }
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    @ViewBuilder
    private var listeningStatistics: some View {
        if account.provider.supports(.profileStatistics) {
            Text("Lv.\(profileDetail.value?.level.map(String.init) ?? "—")")
            Text("累计听歌 \(profileDetail.value?.listenSongs?.formatted() ?? "—") 首")
        } else { Text(account.provider.name) }
    }

}

/// Global frame of the profile hero's avatar slot, published by
/// `ProfileIslandHero` and consumed by the island dock overlay.
private struct ProfileAvatarFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Compact profile header for the phone library page. The avatar itself is
/// NOT drawn here: this header only reserves its slot and reports the slot's
/// global frame, while `ProfileIslandDockOverlay` renders the avatar above
/// the page so scrolling can carry it into the Dynamic Island. At 120pt the
/// header stays balanced instead of being dominated by a giant avatar.
private struct ProfileIslandHero<Actions: View>: View {
    let artworkURL: String?
    let title: String
    let subtitle: String
    let metadataText: String
    @ViewBuilder var actions: () -> Actions
    var phoneLayout = PhonePageLayout()
    let avatarSize: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: avatarSize, height: avatarSize)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ProfileAvatarFrameKey.self,
                                               value: geometry.frame(in: .global))
                    }
                }

            Text(title)
                .font(Theme.Typography.detailTitle)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, Theme.Spacing.page)
                .padding(.horizontal, phoneLayout.contentInset)

            Text(subtitle)
                .font(Theme.Typography.secondary)
                .lineLimit(1)
                .padding(.top, Theme.Spacing.small)
                .padding(.horizontal, phoneLayout.contentInset)

            Text(metadataText)
                .font(Theme.Typography.secondary.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, Theme.Spacing.small)
                .padding(.horizontal, phoneLayout.contentInset)

            actions()
                .padding(.top, Theme.Spacing.component)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.section)
        .padding(.bottom, Theme.Spacing.section)
    }
}

/// Renders the profile avatar above the library page and docks it into the
/// Dynamic Island while the page scrolls — the Telegram settings effect.
/// The island itself is hardware and cannot be drawn by an app; the trick
/// is a black pill rendered exactly over it that stretches down to meet the
/// approaching avatar, so the two blacks read as one morphing shape. At
/// rest the avatar sits precisely in the hero's slot and follows scrolling
/// one-to-one; near the top it eases into the island and stays there until
/// the page scrolls back. Inert on devices without a Dynamic Island.
private struct ProfileIslandDockOverlay: View {
    let avatarURL: String?
    let avatarFrame: CGRect

    /// The island's frame in window coordinates, or nil when this device
    /// has no Dynamic Island (those report a ~47pt top safe area instead
    /// of ~59pt) or is not a phone.
    private var islandRect: CGRect? {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene }).first?.keyWindow,
              window.safeAreaInsets.top >= 50 else { return nil }
        let width: CGFloat = 126
        let height: CGFloat = 37
        return CGRect(x: (window.bounds.width - width) / 2, y: 11, width: width, height: height)
    }

    var body: some View {
        GeometryReader { proxy in
            if let island = islandRect, avatarFrame.width > 0 {
                let origin = proxy.frame(in: .global).origin
                let current = CGPoint(x: avatarFrame.midX, y: avatarFrame.midY)
                let target = CGPoint(x: island.midX, y: island.midY)
                // Docking begins when the rising avatar is 150pt of travel
                // away from the island's center.
                let startY = target.y + 150
                let raw = min(1, max(0, (startY - current.y) / (startY - target.y)))
                let eased = raw * raw * (3 - 2 * raw)
                let center = CGPoint(x: current.x + (target.x - current.x) * eased,
                                     y: current.y + (target.y - current.y) * eased)
                let size = avatarFrame.width + (island.height - avatarFrame.width) * eased
                let avatarRect = CGRect(x: center.x - size / 2, y: center.y - size / 2,
                                        width: size, height: size)
                // The pill is the union of the island and the travelling
                // avatar, pulled tight as docking completes so at rest it
                // coincides with the hardware island exactly.
                let grow = 5 * (1 - raw)
                let pill = island.union(avatarRect).insetBy(dx: -grow, dy: -grow)

                ZStack {
                    if raw > 0 {
                        RoundedRectangle(cornerRadius: pill.height / 2, style: .continuous)
                            .fill(Color.black)
                            .frame(width: pill.width, height: pill.height)
                            .position(x: pill.midX - origin.x, y: pill.midY - origin.y)
                            .opacity(min(1, raw / 0.12))
                    }
                    avatar
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.18 * (1 - eased)), radius: 18, y: 10)
                        .position(x: center.x - origin.x, y: center.y - origin.y)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatarURL {
            CachedAsyncImage(url: avatarURL.resizedImageURL(384), animated: false)
        } else {
            ZStack {
                Circle().fill(Color(uiColor: .secondarySystemBackground))
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
