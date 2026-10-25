import Foundation
import UniformTypeIdentifiers

/// Error with a user-facing (German) message.
struct QIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Paths {
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// ~/Library/Application Support/QuickInstall
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("QuickInstall", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var userTrash: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// A path inside the user's trash that does not exist yet, e.g. "Foo 2026-10-24 18.30.12.app".
    static func uniqueTrashDestination(for url: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var name = "\(stem) \(stamp)"
        if FileManager.default.fileExists(atPath: userTrash.appendingPathComponent(name).path) {
            name += " " + String(UUID().uuidString.prefix(6))
        }
        if !ext.isEmpty { name += "." + ext }
        return userTrash.appendingPathComponent(name)
    }

    /// Creates a fresh private directory below the user's temporary directory.
    static func makeTemporaryDirectory(prefix: String = "QuickInstall") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
}

extension UTType {
    /// .dmg (UDIF disk image)
    static var diskImageFile: UTType {
        UTType("com.apple.disk-image-udif") ?? UTType(filenameExtension: "dmg") ?? .data
    }

    /// .pkg (flat installer package)
    static var installerPackageFile: UTType {
        UTType("com.apple.installer-package-archive") ?? UTType(filenameExtension: "pkg") ?? .data
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
