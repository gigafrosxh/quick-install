import Foundation

// MARK: - Inspection

struct PackageComponent: Identifiable, Hashable {
    let identifier: String
    let version: String
    let installLocation: String
    let fileCount: Int
    /// Absolute paths of .app bundles the component installs.
    let apps: [String]
    let hasScripts: Bool

    var id: String { identifier }
}

struct PackageSignature: Hashable {
    let isSigned: Bool
    /// "Status:" line of `pkgutil --check-signature`.
    let status: String
    /// First certificate in the chain, e.g. "Developer ID Installer: Foo Inc (ABCDE12345)".
    let signer: String?
    let notarized: Bool
}

struct PackageDetails {
    let url: URL
    let title: String
    let components: [PackageComponent]
    let signature: PackageSignature
    /// Gatekeeper (`spctl --assess --type install`) would allow this package.
    let gatekeeperAccepted: Bool
    let gatekeeperSource: String?
    let supportsUserInstall: Bool
    let distributionHasScripts: Bool
    /// Set when the package layout could not be read (e.g. old bundle-style packages).
    let inspectionNote: String?

    var hasScripts: Bool { distributionHasScripts || components.contains { $0.hasScripts } }
    var fileCount: Int { components.reduce(0) { $0 + $1.fileCount } }
    var apps: [String] { components.flatMap(\.apps) }
    var identifiers: [String] { components.map(\.identifier) }
    var version: String? { components.first?.version }
}

enum PackageInspector {
    static func inspect(_ url: URL) throws -> PackageDetails {
        let fm = FileManager.default
        let work = try Paths.makeTemporaryDirectory(prefix: "QuickInstall-inspect")
        defer { try? fm.removeItem(at: work) }

        let signature = signature(of: url)
        let gatekeeper = try? Shell.run("/usr/sbin/spctl", ["--assess", "--type", "install", "-vv", url.path])
        let gatekeeperSource = gatekeeper?.stderr
            .split(separator: "\n")
            .first { $0.hasPrefix("source=") }
            .map { String($0.dropFirst("source=".count)) }
        var title = url.deletingPathExtension().lastPathComponent

        // Expands the XML metadata and BOMs; the payload stays compressed.
        let expanded = work.appendingPathComponent("expanded")
        let expandResult = try Shell.run("/usr/sbin/pkgutil", ["--expand", url.path, expanded.path])
        guard expandResult.succeeded else {
            return PackageDetails(
                url: url, title: title, components: [], signature: signature,
                gatekeeperAccepted: gatekeeper?.succeeded == true, gatekeeperSource: gatekeeperSource,
                supportsUserInstall: false, distributionHasScripts: false,
                inspectionNote: "Der Paketinhalt konnte nicht gelesen werden. Die Installation ist trotzdem möglich.")
        }

        var supportsUserInstall = false
        var distributionHasScripts = false
        var componentDirectories = [expanded]

        let distribution = expanded.appendingPathComponent("Distribution")
        if let document = try? XMLDocument(contentsOf: distribution) {
            if let value = (try? document.nodes(forXPath: "//title"))?.first?.stringValue?.trimmed,
               !value.isEmpty, !looksLikeLocalizationKey(value) {
                title = value
            }
            if let domains = (try? document.nodes(forXPath: "//domains"))?.first as? XMLElement {
                supportsUserInstall = domains.attribute(forName: "enable_currentUserHome")?.stringValue == "true"
            }
            // Distribution scripts run JavaScript checks; installer plugins show custom UI.
            distributionHasScripts = fm.fileExists(atPath: expanded.appendingPathComponent("Plugins").path)
            componentDirectories = ((try? fm.contentsOfDirectory(at: expanded, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "pkg" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        return PackageDetails(
            url: url,
            title: title,
            components: componentDirectories.compactMap(component(at:)),
            signature: signature,
            gatekeeperAccepted: gatekeeper?.succeeded == true,
            gatekeeperSource: gatekeeperSource,
            supportsUserInstall: supportsUserInstall,
            distributionHasScripts: distributionHasScripts,
            inspectionNote: nil)
    }

    private static func component(at directory: URL) -> PackageComponent? {
        guard let document = try? XMLDocument(contentsOf: directory.appendingPathComponent("PackageInfo")),
              let root = document.rootElement()
        else { return nil }

        let identifier = root.attribute(forName: "identifier")?.stringValue ?? directory.lastPathComponent
        let version = root.attribute(forName: "version")?.stringValue ?? "?"
        var location = root.attribute(forName: "install-location")?.stringValue ?? "/"
        if location.isEmpty { location = "/" }
        let declaredScripts = ((try? document.nodes(forXPath: "/pkg-info/scripts/*")) ?? []).isEmpty == false
        let hasScripts = declaredScripts
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("Scripts").path)

        var fileCount = 0
        var apps: [String] = []
        let bom = directory.appendingPathComponent("Bom")
        if let listing = try? Shell.run("/usr/bin/lsbom", ["-s", bom.path]), listing.succeeded {
            var seen = Set<String>()
            for line in listing.stdout.split(separator: "\n") {
                fileCount += 1
                let parts = line.split(separator: "/").filter { $0 != "." }
                guard let appIndex = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { continue }
                let relative = parts[...appIndex].joined(separator: "/")
                if seen.insert(relative).inserted {
                    apps.append((location as NSString).appendingPathComponent(relative))
                }
            }
        }

        return PackageComponent(
            identifier: identifier, version: version, installLocation: location,
            fileCount: fileCount, apps: apps, hasScripts: hasScripts)
    }

    static func signature(of url: URL) -> PackageSignature {
        guard let result = try? Shell.run("/usr/sbin/pkgutil", ["--check-signature", url.path]) else {
            return PackageSignature(isSigned: false, status: "Unbekannt", signer: nil, notarized: false)
        }
        let lines = result.stdout.split(separator: "\n").map { $0.trimmed }
        let status = lines.first { $0.hasPrefix("Status:") }
            .map { String($0.dropFirst("Status:".count)).trimmed } ?? "keine Signatur"
        let signer = lines.first { $0.hasPrefix("1. ") }.map { String($0.dropFirst(3)) }
        let notarized = lines.contains { $0.hasPrefix("Notarization:") && $0.contains("trusted") }
        let isSigned = result.succeeded && !status.lowercased().contains("no signature")
        return PackageSignature(isSigned: isSigned, status: status, signer: signer, notarized: notarized)
    }

    private static func looksLikeLocalizationKey(_ value: String) -> Bool {
        !value.contains(" ") && value.contains("_") && value == value.uppercased()
    }
}

// MARK: - Installation

enum PackageTarget: String, CaseIterable, Identifiable {
    case system
    case currentUser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Für alle Benutzer (Startvolume)"
        case .currentUser: return "Nur für mich (Benutzerordner)"
        }
    }
}

enum PackageInstaller {
    static func receipts(volume: String? = nil) -> Set<String> {
        var arguments = ["--pkgs"]
        if let volume { arguments += ["--volume", volume] }
        guard let result = try? Shell.run("/usr/sbin/pkgutil", arguments), result.succeeded else { return [] }
        return Set(result.stdout.split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty })
    }

    /// Installs with Apple's `installer` tool and returns its output plus the receipts it created.
    static func install(_ package: URL, title: String, target: PackageTarget, knownIdentifiers: [String]) throws -> (output: String, receipts: [String]) {
        let volume = target == .currentUser ? NSHomeDirectory() : nil
        let before = receipts(volume: volume)

        let output: String
        switch target {
        case .system:
            output = try Privileged.run(prompt: "QuickInstall möchte „\(title)“ installieren.") { _ in
                "/usr/sbin/installer -pkg \(Shell.quote(package.path)) -target / 2>&1\n"
            }
        case .currentUser:
            output = try Shell.check(
                "/usr/sbin/installer", ["-pkg", package.path, "-target", "CurrentUserHomeDirectory"]).stdout
        }

        let after = receipts(volume: volume)
        var created = after.subtracting(before)
        created.formUnion(knownIdentifiers.filter { after.contains($0) })
        return (output, created.sorted())
    }

    /// Copies a package out of a disk image so the image can be ejected independently.
    static func stage(_ package: URL) throws -> URL {
        let directory = try Paths.makeTemporaryDirectory(prefix: "QuickInstall-staged")
        let copy = directory.appendingPathComponent(package.lastPathComponent)
        try FileManager.default.copyItem(at: package, to: copy)
        return copy
    }
}
