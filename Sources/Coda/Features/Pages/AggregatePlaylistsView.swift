import SwiftUI

// MARK: - Library section （「我的」页底部）

/// The aggregate-playlist shelf pinned to the bottom of the library page.
/// Aggregate playlists belong to no platform account, so this section is
/// shown regardless of which account is active or whether anyone is
/// signed in at all.
struct AggregatePlaylistSection: View {
    @ObservedObject private var store = AggregatePlaylistStore.shared
    @State private var selectedPlaylistID: UUID?
    @State private var showImport = false
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("聚合歌单")
                    .font(.title3.weight(.bold))
                Spacer()
                Button {
                    showImport = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                Button {
                    newPlaylistName = ""
                    showNewPlaylist = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建聚合歌单")
                .alert("新建聚合歌单", isPresented: $showNewPlaylist) {
                    TextField("歌单名称", text: $newPlaylistName)
                    Button("创建") {
                        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        store.create(name: name)
                    }
                    Button("取消", role: .cancel) {}
                }
            }
            .padding(.horizontal, 16)
            .sheet(isPresented: $showImport) {
                AggregateImportSheet()
            }

            if store.playlists.isEmpty {
                Text("把不同平台的歌收进同一张歌单，在这里新建或导入。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(store.playlists) { playlist in
                            Button {
                                selectedPlaylistID = playlist.id
                            } label: {
                                CoverCardBody(
                                    coverURL: playlist.coverURLString?.resizedImageURL(384),
                                    title: playlist.name,
                                    subtitle: "\(playlist.tracks.count) 首"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .sheet(item: Binding(
            get: { selectedPlaylistID.map { AggregatePlaylistRef(id: $0) } },
            set: { selectedPlaylistID = $0?.id }
        )) { ref in
            NavigationStack {
                AggregatePlaylistDetailView(playlistID: ref.id)
            }
        }
    }
}

private struct AggregatePlaylistRef: Identifiable {
    let id: UUID
}

// MARK: - Detail

struct AggregatePlaylistDetailView: View {
    let playlistID: UUID

    @ObservedObject private var store = AggregatePlaylistStore.shared
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false

    private var playlist: AggregatePlaylist? { store.playlist(id: playlistID) }

    var body: some View {
        Group {
            if let playlist {
                List {
                    Section {
                        header(playlist)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        ForEach(playlist.tracks, id: \.aggregateIdentity) { track in
                            row(track)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        store.remove(trackIdentity: track.aggregateIdentity, from: playlistID)
                                    } label: {
                                        Label("从聚合歌单移除", systemImage: "trash")
                                    }
                                }
                        }
                        .onMove { store.moveTracks(in: playlistID, from: $0, to: $1) }
                        .onDelete { store.deleteTracks(in: playlistID, at: $0) }
                    } header: {
                        if !playlist.sourceSummary.isEmpty {
                            Text(playlist.sourceSummary)
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                Text("歌单已删除")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(playlist?.name ?? "聚合歌单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Menu {
                    Button {
                        renameText = playlist?.name ?? ""
                        showRename = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除歌单", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("歌单名称", text: $renameText)
            Button("保存") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.rename(id: playlistID, to: name) }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除这张聚合歌单？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.delete(id: playlistID)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func header(_ playlist: AggregatePlaylist) -> some View {
        VStack(spacing: 14) {
            CachedAsyncImage(url: playlist.coverURLString?.resizedImageURL(512))
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                )
            Text(playlist.name)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text("\(playlist.tracks.count) 首")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                guard let first = playlist.tracks.first else { return }
                playFrom(first, in: playlist)
            } label: {
                Label("播放全部", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(playlist.tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    /// The player only ever plays one platform at a time, so an aggregate
    /// playlist plays as the tapped track's platform slice, in list order,
    /// switching the app's platform first when needed. Each song still
    /// plays from the platform it was collected from, and a song that
    /// fails on its own platform falls into the usual unblock path.
    private func playFrom(_ tapped: Track, in playlist: AggregatePlaylist) {
        let target = MusicProvider(rawValue: tapped.platformSong?.source.rawValue ?? "netease") ?? .netease
        let subset = playlist.tracks.filter {
            ($0.platformSong?.source ?? .netease).rawValue == target.rawValue
        }
        let start = subset.first { $0.aggregateIdentity == tapped.aggregateIdentity } ?? subset.first
        guard let start else { return }
        let needsSwitch = MusicProviderContext.shared.current != target
        Task {
            if needsSwitch {
                try? await MusicAccountManager.shared.selectProvider(target)
                ToastCenter.shared.show("已切换到\(target.name)，播放歌单中该平台的 \(subset.count) 首")
            }
            player.play(tracks: subset, source: .none, startAt: start)
        }
    }

    private func row(_ track: Track) -> some View {
        Button {
            guard let playlist else { return }
            playFrom(track, in: playlist)
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(track.artistNames)
                            .lineLimit(1)
                        Text("·")
                        Text(track.aggregateSourceName)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add-to sheet

/// Picker shown from a track's menu: choose an existing aggregate
/// playlist, or create a new one and add the track to it.
struct AggregateAddSheet: View {
    let track: Track

    @ObservedObject private var store = AggregatePlaylistStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newPlaylistName = ""
                        showNewPlaylist = true
                    } label: {
                        Label("新建聚合歌单并加入", systemImage: "plus.circle")
                    }
                }
                if store.playlists.isEmpty {
                    Text("还没有聚合歌单，新建一个吧。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Section("我的聚合歌单") {
                        ForEach(store.playlists) { playlist in
                            let contains = playlist.tracks.contains {
                                $0.aggregateIdentity == track.aggregateIdentity
                            }
                            Button {
                                add(to: playlist)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .foregroundStyle(.primary)
                                        Text("\(playlist.tracks.count) 首")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if contains {
                                        Text("已包含")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加到聚合歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("新建聚合歌单", isPresented: $showNewPlaylist) {
                TextField("歌单名称", text: $newPlaylistName)
                Button("创建并加入") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let playlist = store.create(name: name)
                    add(to: playlist)
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func add(to playlist: AggregatePlaylist) {
        switch store.add(track, to: playlist.id) {
        case .added:
            ToastCenter.shared.show("已添加到「\(playlist.name)」")
        case .duplicate:
            ToastCenter.shared.show("这首歌已在「\(playlist.name)」里")
        }
        dismiss()
    }
}

// MARK: - Whole-playlist import

/// Imports one of the active account's platform playlists wholesale into
/// a new aggregate playlist.
struct AggregateImportSheet: View {
    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var store = AggregatePlaylistStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importingID: Int?
    @State private var errorMessage: String?

    private var candidates: [PlaylistSummary] {
        var seen = Set<Int>()
        return (account.createdPlaylists + account.subscribedPlaylists)
            .filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                if !account.hasAuthCookie {
                    Text("先登录\(account.provider.name)，才能导入这个平台的歌单。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if candidates.isEmpty {
                    Text("这个平台下还没有可导入的歌单。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Section("\(account.provider.name)的歌单") {
                        ForEach(candidates) { summary in
                            Button {
                                Task { await importPlaylist(summary) }
                            } label: {
                                HStack(spacing: 12) {
                                    CachedAsyncImage(url: summary.coverURL?.resizedImageURL(96), animated: false)
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(Color.secondary.opacity(0.15))
                                        )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(summary.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(summary.trackCount) 首")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if importingID == summary.id {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(importingID != nil)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("导入平台歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func importPlaylist(_ summary: PlaylistSummary) async {
        importingID = summary.id
        errorMessage = nil
        defer { importingID = nil }
        let content = PlaylistContent(playlistID: summary.id)
        await content.load(allowNetwork: true, summary: summary)
        // The first page lands with load(); the rest streams in behind it.
        for _ in 0..<60 where content.isLoading || content.isLoadingMore {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let tracks = content.tracks
        guard !tracks.isEmpty else {
            errorMessage = "没能拿到这张歌单的歌曲，请稍后再试。"
            return
        }
        store.importPlaylist(name: summary.name, tracks: tracks)
        ToastCenter.shared.show("已导入「\(summary.name)」，共 \(tracks.count) 首")
        dismiss()
    }
}
