import Foundation

struct ScanSession: Identifiable, Hashable {
    let id: String          // folder name, stable
    let url: URL
    var name: String
    let date: Date
    let frames: Int
    let bytes: Int64
}

/// Lists, renames and deletes recorded scans in Documents/scan_*.
final class SessionStore: ObservableObject {
    @Published var sessions: [ScanSession] = []

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.creationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var list: [ScanSession] = []
        for d in dirs where d.lastPathComponent.hasPrefix("scan_") {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let meta = Self.readMeta(d)
            let name = (meta["name"] as? String) ?? d.lastPathComponent
            let date = (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            list.append(ScanSession(id: d.lastPathComponent, url: d, name: name, date: date,
                                    frames: Self.countFrames(d), bytes: Self.folderSize(d)))
        }
        sessions = list.sorted { $0.date > $1.date }
    }

    func rename(_ s: ScanSession, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rename(url: s.url, to: trimmed)
        reload()
    }

    func rename(url: URL, to name: String) {
        var meta = Self.readMeta(url)
        meta["name"] = name
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url.appendingPathComponent("meta.json"))
        }
    }

    func delete(_ s: ScanSession) {
        try? FileManager.default.removeItem(at: s.url)
        reload()
    }

    // MARK: helpers

    static func readMeta(_ dir: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func countFrames(_ dir: URL) -> Int {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("poses.jsonl")) else { return 0 }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    static func folderSize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// File-system-safe version of a user name for the exported zip.
    static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = name.components(separatedBy: bad).joined(separator: "_")
        return cleaned.isEmpty ? "scan" : cleaned
    }
}
