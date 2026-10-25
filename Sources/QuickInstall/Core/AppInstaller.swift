import Foundation

/// Copies .app bundles to their destination folder, the same as dragging them in the Finder.
enum AppInstaller {
    static func existingTarget(for app: URL, in directory: URL) -> URL? {
        let target = directory.appendingPathComponent(app.lastPathComponent)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    /// Installs `app` into `directory`. An existing copy is moved to the trash first.
    /// Falls back to an administrator prompt when the folder isn't writable (e.g. /Applications
    /// for standard users, or replacing an app owned by root).
    static func install(app: URL, into directory: URL) throws -> URL {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(app.lastPathComponent)

        if isWritable(directory) {
            var oldCopyGone = !fm.fileExists(atPath: target.path)
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                if !oldCopyGone {
                    try fm.trashItem(at: target, resultingItemURL: nil)
                    oldCopyGone = true
                }
                try fm.copyItem(at: app, to: target)
                return target
            } catch {
                // Remove a partial copy, never the previous installation.
                if oldCopyGone { try? fm.removeItem(at: target) }
            }
        }

        try installPrivileged(app: app, target: target)
        return target
    }

    private static func installPrivileged(app: URL, target: URL) throws {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        try Privileged.run(prompt: "QuickInstall möchte „\(app.deletingPathExtension().lastPathComponent)“ nach \(Paths.abbreviate(directory.path)) installieren.") { _ in
            var script = "set -e\n"
            script += "/bin/mkdir -p \(Shell.quote(directory.path))\n"
            if fm.fileExists(atPath: target.path) {
                let trashed = Paths.uniqueTrashDestination(for: target)
                script += "/bin/mv \(Shell.quote(target.path)) \(Shell.quote(trashed.path))\n"
            }
            script += "/usr/bin/ditto \(Shell.quote(app.path)) \(Shell.quote(target.path))\n"
            // Like a Finder copy: owned by the user, so the app can update itself.
            script += "/usr/sbin/chown -R \(Shell.quote(NSUserName())):admin \(Shell.quote(target.path))\n"
            return script
        }
    }

    /// Whether the folder (or the nearest existing parent, if it doesn't exist yet) is writable.
    private static func isWritable(_ directory: URL) -> Bool {
        var candidate = directory
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return FileManager.default.isWritableFile(atPath: candidate.path)
    }
}
