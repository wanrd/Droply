import Foundation

public enum MacSendItem: Sendable {
    case file(url: URL, relativePath: String, size: UInt64, isText: Bool)
    case textNote(fileName: String, data: Data)

    public var relativePath: String {
        switch self {
        case .file(_, let relativePath, _, _): return relativePath
        case .textNote(let fileName, _): return fileName
        }
    }

    public var sizeBytes: UInt64 {
        switch self {
        case .file(_, _, let size, _): return size
        case .textNote(_, let data): return UInt64(data.count)
        }
    }

    public var isText: Bool {
        switch self {
        case .file(_, _, _, let isText): return isText
        case .textNote: return true
        }
    }
}

public enum MacFileCollector {
    private static let textExtensions: Set<String> = ["txt", "md", "json", "csv", "log", "xml", "yaml", "yml", "swift", "kt"]

    public static func collect(urls: [URL]) -> [MacSendItem] {
        var result: [MacSendItem] = []
        let fm = FileManager.default

        for url in urls {
            guard !PathSanitizer.isSymlink(atPath: url.path) else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let rootName = sanitizeSegment(url.lastPathComponent)
                collectDirectory(at: url, prefix: rootName, fileManager: fm, into: &result)
            } else {
                let resValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
                if resValues?.isRegularFile == false { continue }
                let name = sanitizeSegment(url.lastPathComponent)
                let size = fileSize(url: url)
                let isText = textExtensions.contains(url.pathExtension.lowercased())
                result.append(.file(url: url, relativePath: name, size: size, isText: isText))
            }
        }
        return result
    }

    public static func buildTextNote(fileName: String, content: String) -> MacSendItem {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "note_\(Int(Date().timeIntervalSince1970))" : trimmed
        let finalName = base.contains(".") ? base : "\(base).txt"
        let safe = sanitizeSegment(finalName)
        return .textNote(fileName: safe, data: Data(content.utf8))
    }

    private static func collectDirectory(
        at directory: URL,
        prefix: String,
        fileManager: FileManager,
        into output: inout [MacSendItem]
    ) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true || PathSanitizer.isSymlink(atPath: entry.path) {
                continue
            }
            let name = sanitizeSegment(entry.lastPathComponent)
            if name == ".DS_Store" { continue }
            let relative = "\(prefix)/\(name)"
            if values?.isDirectory == true {
                collectDirectory(at: entry, prefix: relative, fileManager: fileManager, into: &output)
            } else if values?.isRegularFile != false {
                let size = fileSize(url: entry)
                let isText = textExtensions.contains(entry.pathExtension.lowercased())
                output.append(.file(url: entry, relativePath: relative, size: size, isText: isText))
            }
        }
    }

    private static func fileSize(url: URL) -> UInt64 {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
            return UInt64(max(0, size))
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            return size.uint64Value
        }
        return 0
    }

    private static func sanitizeSegment(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "item"
        }
        return cleaned
    }
}
