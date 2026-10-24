import AppKit
import SwiftUI

@MainActor
enum InstallFlow {
    static func openDiskImage(_ url: URL) {
        let model = DiskImageInstallModel(imageURL: url)
        model.window = WindowManager.shared.show(
            DiskImageInstallView(model: model),
            title: url.lastPathComponent,
            size: NSSize(width: 580, height: 460),
            onClose: { model.cleanup() })
        model.start()
    }

    static func openPackage(_ url: URL, source: String, isStagedCopy: Bool) {
        if ConfigStore.shared.config.packageMode == .appleInstaller {
            openInAppleInstaller(url)
            return
        }
        let model = PackageInstallModel(packageURL: url, source: source, isStagedCopy: isStagedCopy)
        model.window = WindowManager.shared.show(
            PackageInstallView(model: model),
            title: url.lastPathComponent,
            size: NSSize(width: 620, height: 600),
            onClose: { model.cleanup() })
        model.start()
    }

    static func openInAppleInstaller(_ url: URL) {
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
}

struct InstallResult: Identifiable {
    let id = UUID()
    let name: String
    let installedURL: URL?
    let error: String?
}

// MARK: - Disk images

@MainActor
final class DiskImageInstallModel: ObservableObject {
    enum Phase {
        case mounting
        case ready
        case working(String)
        case finished
        case failed(String)
    }

    let imageURL: URL
    weak var window: NSWindow?

    @Published var phase: Phase = .mounting
    @Published var items: [ImageItem] = []
    @Published var selected: Set<URL> = []
    @Published var destination: String
    @Published var conflicts: [URL] = []
    @Published var results: [InstallResult] = []
    @Published var imageTrashed = false

    private var mounted: MountedImage?
    private var keepMounted = false

    init(imageURL: URL) {
        self.imageURL = imageURL
        destination = ConfigStore.shared.config.preferredDestination
    }

    var apps: [ImageItem] { items.filter { $0.kind == .app } }
    var packages: [ImageItem] { items.filter { $0.kind == .package } }
    var destinationURL: URL { URL(fileURLWithPath: Paths.expand(destination), isDirectory: true) }

    func start() {
        let url = imageURL
        Task {
            do {
                let image = try await Task.detached { try DiskImage.attach(url) }.value
                mounted = image
                let found = await Task.detached { image.mountPoints.flatMap { DiskImage.scan($0) } }.value
                items = found
                selected = Set(found.filter { $0.kind == .app }.map(\.url))
                if apps.isEmpty, packages.count == 1 {
                    // The usual "installer in a DMG" case: go straight to the package.
                    openPackage(packages[0])
                } else {
                    phase = .ready
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func requestInstall() {
        let chosen = apps.filter { selected.contains($0.url) }
        let existing = chosen.compactMap { AppInstaller.existingTarget(for: $0.url, in: destinationURL) }
        if !existing.isEmpty && ConfigStore.shared.config.confirmBeforeReplacing {
            conflicts = existing
        } else {
            performInstall()
        }
    }

    func performInstall() {
        conflicts = []
        let chosen = apps.filter { selected.contains($0.url) }
        let directory = destinationURL
        let source = imageURL.lastPathComponent
        ConfigStore.shared.noteUsed(destination)

        Task {
            var results: [InstallResult] = []
            for item in chosen {
                phase = .working("„\(item.name)“ wird nach \(Paths.abbreviate(directory.path)) kopiert …")
                do {
                    let target = try await Task.detached { try AppInstaller.install(app: item.url, into: directory) }.value
                    results.append(InstallResult(name: item.name, installedURL: target, error: nil))
                    InstallHistory.shared.add(InstallRecord(
                        kind: .app, name: item.name, version: item.version,
                        bundleIdentifier: item.bundleIdentifier, installedPaths: [target.path],
                        packageIdentifiers: [], source: source))
                } catch ShellError.cancelled {
                    results.append(InstallResult(name: item.name, installedURL: nil, error: "Abgebrochen."))
                } catch {
                    results.append(InstallResult(name: item.name, installedURL: nil, error: error.localizedDescription))
                }
            }
            self.results = results
            await finish(success: results.allSatisfy { $0.error == nil })
        }
    }

    private func finish(success: Bool) async {
        let config = ConfigStore.shared.config
        phase = .working("Image wird ausgeworfen …")
        await detach()
        if success && config.trashImageAfterInstall {
            imageTrashed = (try? FileManager.default.trashItem(at: imageURL, resultingItemURL: nil)) != nil
        }
        if config.openAppAfterInstall {
            for url in results.compactMap(\.installedURL) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        phase = .finished
    }

    func openPackage(_ item: ImageItem) {
        phase = .working("Paket wird vorbereitet …")
        let source = imageURL.lastPathComponent
        Task {
            do {
                let copy = try await Task.detached { try PackageInstaller.stage(item.url) }.value
                InstallFlow.openPackage(copy, source: source, isStagedCopy: true)
                if apps.isEmpty {
                    window?.close()
                } else {
                    phase = .ready
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Opens the mounted volume in the Finder and leaves it mounted.
    func revealInFinder() {
        guard let mountPoint = mounted?.mountPoints.first else { return }
        keepMounted = true
        NSWorkspace.shared.open(mountPoint)
    }

    private func detach() async {
        guard let image = mounted, !keepMounted else { return }
        mounted = nil
        await Task.detached { DiskImage.detach(image) }.value
    }

    func cleanup() {
        guard let image = mounted, !keepMounted else { return }
        mounted = nil
        DispatchQueue.global(qos: .utility).async { DiskImage.detach(image) }
    }
}

// MARK: - Packages

@MainActor
final class PackageInstallModel: ObservableObject {
    enum Phase {
        case inspecting
        case ready
        case installing
        case finished
        case failed(String)
    }

    let packageURL: URL
    let source: String
    let isStagedCopy: Bool
    weak var window: NSWindow?

    @Published var phase: Phase = .inspecting
    @Published var details: PackageDetails?
    @Published var target: PackageTarget = .system
    @Published var acceptRisk = false
    @Published var output = ""
    @Published var receipts: [String] = []

    private var keepFile = false

    init(packageURL: URL, source: String, isStagedCopy: Bool) {
        self.packageURL = packageURL
        self.source = source
        self.isStagedCopy = isStagedCopy
    }

    var title: String { details?.title ?? packageURL.deletingPathExtension().lastPathComponent }
    var needsRiskConfirmation: Bool { details?.gatekeeperAccepted != true }
    var installedApps: [URL] {
        (details?.apps ?? [])
            .map { path in target == .currentUser ? NSHomeDirectory() + path : path }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func start() {
        let url = packageURL
        Task {
            do {
                details = try await Task.detached { try PackageInspector.inspect(url) }.value
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func install() {
        guard let details else { return }
        phase = .installing
        let url = packageURL
        let target = target
        let title = title
        Task {
            do {
                let result = try await Task.detached {
                    try PackageInstaller.install(url, title: title, target: target, knownIdentifiers: details.identifiers)
                }.value
                output = result.output
                receipts = result.receipts
                InstallHistory.shared.add(InstallRecord(
                    kind: .package, name: title, version: details.version, bundleIdentifier: nil,
                    installedPaths: installedApps.map(\.path), packageIdentifiers: result.receipts, source: source))
                if ConfigStore.shared.config.trashImageAfterInstall && !isStagedCopy {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                phase = .finished
            } catch ShellError.cancelled {
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func openInAppleInstaller() {
        keepFile = true
        InstallFlow.openInAppleInstaller(packageURL)
        window?.close()
    }

    func cleanup() {
        guard isStagedCopy, !keepFile else { return }
        try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent())
    }
}
