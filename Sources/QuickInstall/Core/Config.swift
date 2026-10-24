import Foundation
import Combine

struct Destination: Codable, Hashable, Identifiable {
    var name: String
    var path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: Paths.expand(path), isDirectory: true) }
}

enum PackageMode: String, Codable, CaseIterable, Identifiable {
    /// Show the package's contents and signature, then install it via `installer`.
    case quickInstall
    /// Hand the package straight to Apple's Installer.app.
    case appleInstaller

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickInstall: return "QuickInstall (Inhalt prüfen, dann installieren)"
        case .appleInstaller: return "Apple-Installer"
        }
    }
}

/// Contents of ~/Library/Application Support/QuickInstall/config.json.
/// Missing keys fall back to their defaults, so the file can be edited by hand.
struct AppConfig: Codable, Equatable {
    var destinations: [Destination] = AppConfig.defaultDestinations
    var defaultDestination: String = "/Applications"
    var rememberLastDestination = false
    var lastDestination: String?
    var confirmBeforeReplacing = true
    var openAppAfterInstall = false
    var trashImageAfterInstall = false
    var packageMode: PackageMode = .quickInstall

    static let defaultDestinations = [
        Destination(name: "Programme", path: "/Applications"),
        Destination(name: "Programme (nur ich)", path: "~/Applications"),
        Destination(name: "Dienstprogramme", path: "/Applications/Utilities"),
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        destinations = try container.decodeIfPresent([Destination].self, forKey: .destinations) ?? defaults.destinations
        if destinations.isEmpty { destinations = defaults.destinations }
        defaultDestination = try container.decodeIfPresent(String.self, forKey: .defaultDestination) ?? destinations[0].path
        rememberLastDestination = try container.decodeIfPresent(Bool.self, forKey: .rememberLastDestination) ?? defaults.rememberLastDestination
        lastDestination = try container.decodeIfPresent(String.self, forKey: .lastDestination)
        confirmBeforeReplacing = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeReplacing) ?? defaults.confirmBeforeReplacing
        openAppAfterInstall = try container.decodeIfPresent(Bool.self, forKey: .openAppAfterInstall) ?? defaults.openAppAfterInstall
        trashImageAfterInstall = try container.decodeIfPresent(Bool.self, forKey: .trashImageAfterInstall) ?? defaults.trashImageAfterInstall
        packageMode = try container.decodeIfPresent(PackageMode.self, forKey: .packageMode) ?? defaults.packageMode
    }

    /// The folder preselected in the destination dropdown.
    var preferredDestination: String {
        if rememberLastDestination, let lastDestination { return lastDestination }
        return defaultDestination
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: AppConfig {
        didSet { if config != oldValue { save() } }
    }
    /// True until the user has confirmed the settings window shown on first launch.
    @Published var isFirstLaunch: Bool
    @Published var loadError: String?

    let fileURL: URL

    private init() {
        fileURL = Paths.supportDirectory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: fileURL) {
            isFirstLaunch = false
            do {
                config = try JSONDecoder().decode(AppConfig.self, from: data)
            } catch {
                config = AppConfig()
                loadError = "config.json konnte nicht gelesen werden: \(error.localizedDescription)"
            }
        } else {
            isFirstLaunch = true
            config = AppConfig()
            save()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            loadError = "config.json konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    /// Picks up changes made to config.json in a text editor.
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let fresh = try JSONDecoder().decode(AppConfig.self, from: data)
            loadError = nil
            if fresh != config { config = fresh }
        } catch {
            loadError = "config.json enthält einen Fehler und wurde nicht übernommen: \(error.localizedDescription)"
        }
    }

    func addDestination(_ url: URL) {
        let path = Paths.abbreviate(url.path)
        guard !config.destinations.contains(where: { Paths.expand($0.path) == url.path }) else { return }
        let name = FileManager.default.displayName(atPath: url.path)
        config.destinations.append(Destination(name: name, path: path))
    }

    func removeDestination(_ destination: Destination) {
        guard config.destinations.count > 1 else { return }
        config.destinations.removeAll { $0.path == destination.path }
        if config.defaultDestination == destination.path {
            config.defaultDestination = config.destinations[0].path
        }
        if config.lastDestination == destination.path {
            config.lastDestination = nil
        }
    }

    func noteUsed(_ path: String) {
        config.lastDestination = path
    }
}
