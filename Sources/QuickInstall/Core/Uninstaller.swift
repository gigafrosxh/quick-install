import AppKit
import Foundation

// MARK: - Installed apps

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let version: String?
    let bundleIdentifier: String?

    var id: URL { url }

    init(url: URL) {
        let bundle = Bundle(url: url)
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        bundleIdentifier = bundle?.bundleIdentifier
    }
}

enum AppScanner {
    /// Third-party apps in the usual folders plus the configured destinations.
    static func installedApps(extraDirectories: [URL]) -> [InstalledApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ] + extraDirectories
        var seenDirectories = Set<String>()
        directories = directories.filter { seenDirectories.insert($0.standardizedFileURL.path).inserted }

        var apps: [InstalledApp] = []
        var seenApps = Set<String>()
        for directory in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for entry in entries where entry.pathExtension == "app" {
                guard seenApps.insert(entry.resolvingSymlinksInPath().path).inserted else { continue }
                let app = InstalledApp(url: entry)
                // Apple's own apps are protected by the system and shouldn't be removed here.
                if app.bundleIdentifier?.hasPrefix("com.apple.") == true { continue }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The pkgutil receipt that installed the file at `path`, if any.
    static func owningPackage(of path: String) -> String? {
        guard let result = try? Shell.run("/usr/sbin/pkgutil", ["--file-info", path]), result.succeeded else { return nil }
        return result.stdout
            .split(separator: "\n")
            .filter { $0.hasPrefix("pkgid:") }
            .map { String($0.dropFirst("pkgid:".count)).trimmed }
            .first { !$0.hasPrefix("com.apple.") }
    }
}

// MARK: - Leftover files

struct Leftover: Identifiable, Hashable {
    let url: URL
    /// nil when the size isn't computed (app containers would trigger a privacy prompt).
    let size: Int64?
    /// Matched by bundle identifier (reliable) rather than only by the app's name.
    let matchesBundleIdentifier: Bool

    var id: URL { url }
}

enum LeftoverFinder {
    private static let userLibraryFolders = [
        "Application Support", "Application Scripts", "Caches", "Containers", "Group Containers",
        "Cookies", "HTTPStorages", "LaunchAgents", "Logs", "Preferences", "Preferences/ByHost",
        "Saved Application State", "WebKit",
    ]
    private static let systemLibraryFolders = [
        "Application Support", "Caches", "LaunchAgents", "LaunchDaemons", "Logs", "Preferences",
        "PrivilegedHelperTools",
    ]
    private static let protectedFolders: Set<String> = ["Containers", "Group Containers"]

    static func find(bundleIdentifier: String?, appName: String) -> [Leftover] {
        let userLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let systemLibrary = URL(fileURLWithPath: "/Library")
        return search(userLibrary, folders: userLibraryFolders, bundleIdentifier: bundleIdentifier, appName: appName, allowNameMatch: true)
            + search(systemLibrary, folders: systemLibraryFolders, bundleIdentifier: bundleIdentifier, appName: appName, allowNameMatch: false)
    }

    private static func search(_ library: URL, folders: [String], bundleIdentifier: String?, appName: String, allowNameMatch: Bool) -> [Leftover] {
        let id = bundleIdentifier?.lowercased() ?? ""
        let name = appName.lowercased()
        var results: [Leftover] = []

        for folder in folders {
            let directory = library.appendingPathComponent(folder)
            let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                let entryName = entry.lastPathComponent.lowercased()
                let byIdentifier = !id.isEmpty && containsToken(entryName, id)
                let stem = (entryName as NSString).deletingPathExtension
                let byName = allowNameMatch && name.count >= 3 && (entryName == name || stem == name)
                guard byIdentifier || byName else { continue }
                let size = protectedFolders.contains(folder) ? nil : allocatedSize(of: entry)
                results.append(Leftover(url: entry, size: size, matchesBundleIdentifier: byIdentifier))
            }
        }
        return results
    }

    /// True if `token` occurs in `value` delimited by start/end or one of ". _-".
    /// Matches "com.foo.app.plist" and "ABCDE12345.com.foo.app" but not "com.foo.application".
    static func containsToken(_ value: String, _ token: String) -> Bool {
        let delimiters: Set<Character> = [".", "_", "-", " "]
        var range = value.startIndex..<value.endIndex
        while let found = value.range(of: token, range: range) {
            let startOK = found.lowerBound == value.startIndex
                || delimiters.contains(value[value.index(before: found.lowerBound)])
            let endOK = found.upperBound == value.endIndex || delimiters.contains(value[found.upperBound])
            if startOK && endOK { return true }
            range = found.upperBound..<value.endIndex
        }
        return false
    }

    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }

        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

// MARK: - Trash

enum Trash {
    /// Moves items to the user's trash. Items the user may not move are moved with
    /// administrator rights (one password prompt). Returns the items that could not be moved.
    @discardableResult
    static func move(_ urls: [URL]) throws -> [URL] {
        var needsAdmin: [URL] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                needsAdmin.append(url)
            }
        }
        guard !needsAdmin.isEmpty else { return [] }

        let output = try Privileged.run(prompt: "QuickInstall benötigt Administratorrechte, um Dateien in den Papierkorb zu legen.") { _ in
            needsAdmin.map { url in
                let destination = Paths.uniqueTrashDestination(for: url)
                return "/bin/mv -f \(Shell.quote(url.path)) \(Shell.quote(destination.path)) || echo \(Shell.quote("FAILED:" + url.path))"
            }.joined(separator: "\n") + "\nexit 0\n"
        }
        let failed = Set(output.split(separator: "\n").filter { $0.hasPrefix("FAILED:") }.map { String($0.dropFirst("FAILED:".count)) })
        return needsAdmin.filter { failed.contains($0.path) }
    }
}

// MARK: - Package receipts

struct PackageReceipt: Hashable {
    let identifier: String
    let version: String
    let volume: String
    let location: String
    let installDate: Date?

    /// Absolute path for a path listed by `pkgutil --files`.
    func absolutePath(_ relative: String) -> String {
        URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent(location)
            .appendingPathComponent(relative)
            .standardizedFileURL.path
    }
}

enum Receipts {
    static func thirdPartyIdentifiers() -> [String] {
        PackageInstaller.receipts().filter { !$0.hasPrefix("com.apple.") }.sorted()
    }

    static func info(_ identifier: String) -> PackageReceipt? {
        guard let result = try? Shell.run("/usr/sbin/pkgutil", ["--pkg-info-plist", identifier]), result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let time = (plist["install-time"] as? NSNumber)?.doubleValue
        return PackageReceipt(
            identifier: identifier,
            version: plist["pkg-version"] as? String ?? "?",
            volume: plist["volume"] as? String ?? "/",
            location: plist["install-location"] as? String ?? "",
            installDate: time.map { Date(timeIntervalSince1970: $0) })
    }

    /// Absolute paths of the files (or directories) a receipt lists that still exist.
    static func paths(of receipt: PackageReceipt, directories: Bool) -> [String] {
        let flag = directories ? "--only-dirs" : "--only-files"
        guard let result = try? Shell.run("/usr/sbin/pkgutil", [flag, "--files", receipt.identifier, "--volume", receipt.volume]),
              result.succeeded
        else { return [] }
        return result.stdout.split(separator: "\n").map { receipt.absolutePath(String($0)) }.filter { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
            return exists && (directories ? isDirectory.boolValue : true)
        }
    }

    /// Files of `receipt` that no other third-party package also claims.
    static func removableFiles(of receipt: PackageReceipt) -> (files: [String], shared: Int) {
        let files = paths(of: receipt, directories: false)
        var claimedElsewhere = Set<String>()
        for other in thirdPartyIdentifiers() where other != receipt.identifier {
            guard let otherReceipt = info(other) else { continue }
            claimedElsewhere.formUnion(paths(of: otherReceipt, directories: false))
        }
        let removable = files.filter { !claimedElsewhere.contains($0) }
        return (removable, files.count - removable.count)
    }

    /// Folders that must never be removed even when they end up empty.
    private static let protectedDirectories: Set<String> = [
        "/usr/local", "/usr/local/bin", "/usr/local/lib", "/usr/local/include", "/usr/local/share",
        "/usr/local/etc", "/usr/local/sbin", "/opt/homebrew",
    ]

    private static func isProtected(_ path: String) -> Bool {
        let depth = path.split(separator: "/").count
        let home = NSHomeDirectory()
        return depth <= 2 || protectedDirectories.contains(path) || path == home
            || (path.hasPrefix(home + "/") && path.dropFirst(home.count + 1).split(separator: "/").count <= 2)
    }

    /// Stops launchd jobs, deletes the package's files and empty folders and forgets the receipt.
    static func remove(_ receipt: PackageReceipt, files: [String]) throws {
        let directories = paths(of: receipt, directories: true)
            .filter { !isProtected($0) }
            .sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        let uid = getuid()

        try Privileged.run(prompt: "QuickInstall möchte das Paket „\(receipt.identifier)“ entfernen.") { dir in
            let filesList = dir.appendingPathComponent("files")
            let directoriesList = dir.appendingPathComponent("dirs")
            try Data(files.joined(separator: "\0").utf8).write(to: filesList)
            try Data(directories.joined(separator: "\0").utf8).write(to: directoriesList)

            var script = ""
            for file in files where file.hasSuffix(".plist") {
                if file.hasPrefix("/Library/LaunchDaemons/") {
                    script += "/bin/launchctl bootout system \(Shell.quote(file)) 2>/dev/null\n"
                } else if file.hasPrefix("/Library/LaunchAgents/") {
                    script += "/bin/launchctl bootout gui/\(uid) \(Shell.quote(file)) 2>/dev/null\n"
                }
            }
            if !files.isEmpty {
                script += "/usr/bin/xargs -0 /bin/rm -f < \(Shell.quote(filesList.path))\n"
            }
            if !directories.isEmpty {
                // rmdir only removes folders that are empty now.
                script += "/usr/bin/xargs -0 /bin/rmdir < \(Shell.quote(directoriesList.path)) 2>/dev/null\n"
            }
            script += "/usr/sbin/pkgutil --forget \(Shell.quote(receipt.identifier)) --volume \(Shell.quote(receipt.volume)) >/dev/null\n"
            script += "exit 0\n"
            return script
        }
    }
}

// MARK: - Running apps

enum RunningApps {
    /// Asks running instances of the app to quit. Returns false if one is still running after a few seconds.
    @MainActor
    static func quit(bundleIdentifier: String?) async -> Bool {
        guard let bundleIdentifier else { return true }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !running.isEmpty else { return true }
        for app in running { app.terminate() }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if running.allSatisfy(\.isTerminated) { return true }
        }
        return false
    }
}
