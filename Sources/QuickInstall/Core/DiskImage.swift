import Foundation

struct MountedImage {
    let imageURL: URL
    let mountPoints: [URL]
}

/// An installable item found inside a mounted disk image.
struct ImageItem: Identifiable, Hashable {
    enum Kind {
        case app
        case package
    }

    let url: URL
    let kind: Kind
    let version: String?
    let bundleIdentifier: String?

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum DiskImage {
    /// Mounts the image read-only and hidden from the Finder sidebar.
    static func attach(_ url: URL) throws -> MountedImage {
        // Images with a license agreement wait for "Y" on stdin before mounting.
        let result = try Shell.run(
            "/usr/bin/hdiutil",
            ["attach", url.path, "-nobrowse", "-noautoopen", "-readonly", "-plist"],
            input: String(repeating: "Y\n", count: 8))
        guard result.succeeded else {
            throw ShellError.failed(command: "hdiutil attach", result: result)
        }

        // A license text may precede the plist on stdout.
        let output = result.stdout
        let xml = output.range(of: "<?xml").map { String(output[$0.lowerBound...]) } ?? output
        guard let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw QIError("Die Ausgabe von hdiutil konnte nicht gelesen werden.")
        }

        let mountPoints = entities
            .compactMap { $0["mount-point"] as? String }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !mountPoints.isEmpty else {
            throw QIError("Das Image enthält kein lesbares Volume.")
        }
        return MountedImage(imageURL: url, mountPoints: mountPoints)
    }

    static func detach(_ image: MountedImage) {
        for mountPoint in image.mountPoints {
            let result = try? Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
            if result?.succeeded != true {
                _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
            }
        }
    }

    /// Finds .app bundles and installer packages, ignoring symlinks such as the usual
    /// "Applications" alias next to the app.
    static func scan(_ directory: URL, depth: Int = 2) -> [ImageItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }

        var items: [ImageItem] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }

            switch entry.pathExtension.lowercased() {
            case "app":
                let bundle = Bundle(url: entry)
                items.append(ImageItem(
                    url: entry,
                    kind: .app,
                    version: bundle?.infoDictionary?["CFBundleShortVersionString"] as? String,
                    bundleIdentifier: bundle?.bundleIdentifier))
            case "pkg", "mpkg":
                items.append(ImageItem(url: entry, kind: .package, version: nil, bundleIdentifier: nil))
            default:
                if values?.isDirectory == true, depth > 1 {
                    items += scan(entry, depth: depth - 1)
                }
            }
        }
        return items
    }
}
