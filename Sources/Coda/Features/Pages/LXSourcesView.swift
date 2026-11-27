import SwiftUI
import UniformTypeIdentifiers

/// 洛雪音源 management: import LX Music source scripts (file or link), pick
/// the active one, delete them. The active source joins gray-track unblocking
/// as one more resolver; nothing runs until a source is imported here.
struct LXSourcesView: View {
    @ObservedObject private var store = LXSourceStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showFileImporter = false
    @State private var showFilePicker = false
    @State private var showURLImport = false
    @State private var importURLText = ""
    @State private var importError: String?
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.sources.isEmpty {
                        Text("还没有导入音源")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.sources) { record in
                        Button {
                            store.setActive(record.id)
                        } label: {
                            sourceRow(record)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets { store.delete(store.sources[index]) }
                    }
                    if store.activeID != nil {
                        Button("不使用音源", role: .destructive) { store.setActive(nil) }
                    }
                } header: {
                    Text("我的音源")
                } footer: {
                    Text("点按一个音源设为当前使用。当前音源会在歌曲置灰、无法播放时参与解锁取链。")
                }

                Section("导入音源") {
                    Button {
                        #if os(iOS)
                        showFilePicker = true
                        #else
                        showFileImporter = true
                        #endif
                    } label: {
                        Label("从文件导入", systemImage: "doc.badge.plus")
                    }
                    Button {
                        importURLText = ""
                        showURLImport = true
                    } label: {
                        Label("从链接导入", systemImage: "link.badge.plus")
                    }
                    Button {
                        if let text = Platform.pasteboardString, !text.isEmpty {
                            importText(text)
                        } else {
                            importError = "剪贴板是空的，先复制音源脚本内容再来"
                        }
                    } label: {
                        Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                    }
                    if isImporting { ProgressView("正在导入…") }
                }

                Section {
                    Text("音源是第三方提供的脚本，只在软件内的隔离环境中运行：它只能拿到当前要播放的那首歌的信息，接触不到你的账号、歌单和文件。取链接时，歌曲信息会发给音源所使用的解析服务。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("洛雪音源")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.javaScript, .plainText, .text, .data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { Task { await importFromFile(url) } }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showFilePicker) {
                LXDocumentPicker { url in Task { await importFromFile(url) } }
                    .ignoresSafeArea()
            }
            #endif
            .alert("从链接导入", isPresented: $showURLImport) {
                TextField("https://…", text: $importURLText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Button("导入") { Task { await importFromURL() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("粘贴洛雪音源脚本（.js）的直链")
            }
            .alert("导入失败", isPresented: Binding(get: { importError != nil },
                                                    set: { if !$0 { importError = nil } })) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func sourceRow(_ record: LXSourceRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.name).font(.body.weight(.medium)).lineLimit(1)
                    if !record.version.isEmpty {
                        Text(record.version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !record.platformSummary.isEmpty {
                    Text(record.platformSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !record.author.isEmpty {
                    Text("作者：\(record.author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if store.activeID == record.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("当前使用")
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Import

    private func importText(_ text: String) {
        do {
            let record = try store.importSource(text: text)
            ToastCenter.shared.show("已导入「\(record.name)」")
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importFromFile(_ url: URL) async {
        isImporting = true
        defer { isImporting = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                importError = "这个文件不是文本脚本"
                return
            }
            importText(text)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importFromURL() async {
        guard let url = URL(string: importURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            importError = "链接格式不对"
            return
        }
        isImporting = true
        defer { isImporting = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else {
                importError = "下载到的不是文本脚本"
                return
            }
            importText(text)
        } catch {
            importError = error.localizedDescription
        }
    }
}

#if os(iOS)
import UIKit

/// Direct UIKit document picker. SwiftUI's fileImporter can silently drop
/// the selection in sideloaded apps — the picker runs out of process and the
/// handoff back into a sheet-hosted view may never call back — so iOS file
/// imports go through the classic delegate-based picker instead.
struct LXDocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.javaScript, .plainText, .text, .data], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
#endif
