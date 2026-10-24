import Foundation
import Combine

/// Something QuickInstall installed. Used to show the origin of an app and to clean up on uninstall.
struct InstallRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case app
        case package
    }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var name: String
    var version: String?
    var bundleIdentifier: String?
    /// Installed .app bundles (absolute paths).
    var installedPaths: [String]
    /// pkgutil receipt identifiers created by a package installation.
    var packageIdentifiers: [String]
    /// File name of the .dmg/.pkg the item came from.
    var source: String
}

@MainActor
final class InstallHistory: ObservableObject {
    static let shared = InstallHistory()

    @Published private(set) var records: [InstallRecord] = []

    private let fileURL = Paths.supportDirectory.appendingPathComponent("history.json")

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? decoder.decode([InstallRecord].self, from: data) {
            records = stored
        }
    }

    func add(_ record: InstallRecord) {
        // A reinstall replaces the older entry for the same location.
        records.removeAll { old in
            !Set(old.installedPaths).isDisjoint(with: record.installedPaths)
                || !Set(old.packageIdentifiers).isDisjoint(with: record.packageIdentifiers)
        }
        records.insert(record, at: 0)
        save()
    }

    func record(forAppAt path: String) -> InstallRecord? {
        records.first { $0.installedPaths.contains(path) }
    }

    func forgetApp(at path: String) {
        records.removeAll { $0.kind == .app && $0.installedPaths.contains(path) }
        save()
    }

    func forgetPackage(_ identifier: String) {
        for index in records.indices.reversed() where records[index].packageIdentifiers.contains(identifier) {
            records[index].packageIdentifiers.removeAll { $0 == identifier }
            if records[index].packageIdentifiers.isEmpty { records.remove(at: index) }
        }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
