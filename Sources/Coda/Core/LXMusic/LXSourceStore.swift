import Foundation
import Combine

/// One imported LX source script, as listed on the 洛雪音源 page.
struct LXSourceRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var version: String
    var author: String
    var summary: String
    var declared: [String: LXDeclaredSource]
    var importedAt: Date

    /// Platform display names in a stable order, e.g. "QQ音乐 · 网易云音乐".
    var platformSummary: String {
        let order = ["tx", "wy", "kg", "kw", "mg", "qs"]
        return order.filter { declared[$0] != nil }
            .map { declared[$0]?.name ?? $0 }
            .joined(separator: " · ")
    }
}

enum LXSourceStoreError: LocalizedError {
    case emptyScript
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .emptyScript: return "文件是空的"
        case .unreadableFile: return "读不到这个文件"
        }
    }
}

/// Owns the imported LX sources: metadata in preferences, script bodies as
/// files under Application Support, and the runtime of the active source.
@MainActor
final class LXSourceStore: ObservableObject {
    static let shared = LXSourceStore()

    @Published private(set) var sources: [LXSourceRecord] = []
    @Published private(set) var activeID: String?

    private var cachedRuntime: LXRuntime?
    private var cachedRuntimeID: String?

    private static let recordsKey = "lxmusic.records.v1"
    private static let activeKey = "lxmusic.activeID"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.recordsKey),
           let decoded = try? JSONDecoder().decode([LXSourceRecord].self, from: data) {
            sources = decoded
        }
        activeID = UserDefaults.standard.string(forKey: Self.activeKey)
        if let activeID, !sources.contains(where: { $0.id == activeID }) {
            self.activeID = nil
        }
    }

    var activeSource: LXSourceRecord? {
        guard let activeID else { return nil }
        return sources.first { $0.id == activeID }
    }

    // MARK: - Import / remove / activate

    /// Validates a script by really loading it in the runtime — an import
    /// only lands in the list once the source has declared its platforms.
    @discardableResult
    func importSource(text: String) throws -> LXSourceRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LXSourceStoreError.emptyScript }
        let header = Self.parseHeader(trimmed)
        let runtime = try LXRuntime(script: trimmed, scriptInfo: [
            "name": header.name, "version": header.version, "author": header.author,
        ])
        let record = LXSourceRecord(
            id: UUID().uuidString,
            name: header.name.isEmpty ? (runtime.declaredSources.values.first?.name ?? "未命名音源") : header.name,
            version: header.version,
            author: header.author,
            summary: header.summary,
            declared: runtime.declaredSources,
            importedAt: Date())
        try writeScript(trimmed, id: record.id)
        sources.append(record)
        persist()
        if activeID == nil { setActive(record.id) }
        return record
    }

    func delete(_ record: LXSourceRecord) {
        sources.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: scriptURL(id: record.id))
        if activeID == record.id {
            activeID = nil
            cachedRuntime = nil
            cachedRuntimeID = nil
        }
        persist()
    }

    func setActive(_ id: String?) {
        activeID = id
        cachedRuntime = nil
        cachedRuntimeID = nil
        UserDefaults.standard.set(id, forKey: Self.activeKey)
        objectWillChange.send()
    }

    // MARK: - Runtime access

    /// The active source's runtime, built on first use and kept while the
    /// same source stays active.
    func activeRuntime() -> LXRuntime? {
        guard let record = activeSource else { return nil }
        if cachedRuntimeID == record.id, let cachedRuntime { return cachedRuntime }
        guard let text = try? String(contentsOf: scriptURL(id: record.id), encoding: .utf8),
              let runtime = try? LXRuntime(script: text, scriptInfo: [
                  "name": record.name, "version": record.version, "author": record.author,
              ])
        else { return nil }
        cachedRuntime = runtime
        cachedRuntimeID = record.id
        return runtime
    }

    // MARK: - Storage

    private func persist() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: Self.recordsKey)
        }
    }

    private func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("LXSources", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func scriptURL(id: String) -> URL {
        // The directory was created on first import; fall back to a path in
        // the same place for reads/deletes of already-imported sources.
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LXSources/\(id).js")
    }

    private func writeScript(_ text: String, id: String) throws {
        let url = try directory().appendingPathComponent("\(id).js")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Header parsing

    private struct Header {
        var name = ""
        var version = ""
        var author = ""
        var summary = ""
    }

    /// Reads the `@name` / `@version` / `@author` / `@description` lines of
    /// the script's leading comment block, like LX Music itself does.
    private static func parseHeader(_ script: String) -> Header {
        var header = Header()
        let head = script.prefix(2000)
        for line in head.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("@") || text.contains("@") else { continue }
            for key in ["name", "version", "author", "description"] {
                guard let range = text.range(of: "@\(key)") else { continue }
                let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "name": header.name = value
                case "version": header.version = value
                case "author": header.author = value
                case "description": header.summary = value
                default: break
                }
            }
        }
        return header
    }
}
