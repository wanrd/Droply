import Darwin
import Foundation

public enum PathSanitizerError: Error, LocalizedError, Sendable, Equatable {
    case emptyPath
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Пустой путь к файлу"
        case .unsafePath(let path):
            return "Небезопасный путь к файлу: \(path)"
        }
    }
}

public enum PathSanitizer {
    public static let maxPathDepth = 32
    public static let maxSegmentBytes = 255

    /// Validates a relative path sent by the peer and returns clean path components.
    /// Rejects absolute paths, traversal (`..`), NUL bytes, control chars, bidi overrides, and oversized paths.
    public static func sanitizedComponents(from relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty else {
            throw PathSanitizerError.emptyPath
        }
        guard !containsForbiddenCharacters(relativePath) else {
            throw PathSanitizerError.unsafePath(relativePath)
        }

        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") {
            throw PathSanitizerError.unsafePath(relativePath)
        }

        let rawComponents = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard rawComponents.count <= maxPathDepth else {
            throw PathSanitizerError.unsafePath(relativePath)
        }

        var clean: [String] = []
        for component in rawComponents {
            if component.isEmpty || component == "." || component == ".." {
                throw PathSanitizerError.unsafePath(relativePath)
            }
            if component.utf8.count > maxSegmentBytes {
                throw PathSanitizerError.unsafePath(relativePath)
            }
            // Reject macOS/Windows drive-prefix ambiguity like C:
            if clean.isEmpty && component.count >= 2 && component.dropFirst().hasPrefix(":") {
                throw PathSanitizerError.unsafePath(relativePath)
            }
            clean.append(component)
        }

        guard !clean.isEmpty else {
            throw PathSanitizerError.emptyPath
        }
        return clean
    }

    /// Resolves the final URL inside `baseDirectory`, blocking symlink escapes and generating
    /// a unique filename (`name (1).ext`) if `overwriteExisting` is false.
    public static func resolveDestinationURL(
        baseDirectory: URL,
        relativePath: String,
        overwriteExisting: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        let components = try sanitizedComponents(from: relativePath)
        let canonicalBase = baseDirectory.resolvingSymlinksInPath()

        var directoryURL = baseDirectory
        for folder in components.dropLast() {
            directoryURL = directoryURL.appendingPathComponent(folder, isDirectory: true)
            if fileManager.fileExists(atPath: directoryURL.path) {
                guard !isSymlink(atPath: directoryURL.path) else {
                    throw PathSanitizerError.unsafePath(relativePath)
                }
            }
        }

        let canonicalDir = directoryURL.resolvingSymlinksInPath()
        let basePrefix = canonicalBase.path.hasSuffix("/") ? canonicalBase.path : canonicalBase.path + "/"
        guard canonicalDir.path == canonicalBase.path || canonicalDir.path.hasPrefix(basePrefix) else {
            throw PathSanitizerError.unsafePath(relativePath)
        }

        let fileName = components.last!
        let candidate = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        if !fileManager.fileExists(atPath: candidate.path) {
            guard !isSymlink(atPath: candidate.path) else {
                throw PathSanitizerError.unsafePath(relativePath)
            }
            return candidate
        }
        if overwriteExisting {
            guard !isSymlink(atPath: candidate.path), !isDirectory(atPath: candidate.path, fileManager: fileManager) else {
                throw PathSanitizerError.unsafePath(relativePath)
            }
            return candidate
        }

        let baseName = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 1
        while counter <= 10_000 {
            let uniqueName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            let nextURL = directoryURL.appendingPathComponent(uniqueName, isDirectory: false)
            if !fileManager.fileExists(atPath: nextURL.path) && !isSymlink(atPath: nextURL.path) {
                return nextURL
            }
            counter += 1
        }
        throw PathSanitizerError.unsafePath(relativePath)
    }

    public static func isSymlink(atPath path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    public static func isDirectory(atPath path: String, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func containsForbiddenCharacters(_ value: String) -> Bool {
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return true }
            if (0x202A...0x202E).contains(scalar.value) { return true }
            if (0x2066...0x2069).contains(scalar.value) { return true }
            if scalar.value == 0x200E || scalar.value == 0x200F { return true }
        }
        return false
    }
}
