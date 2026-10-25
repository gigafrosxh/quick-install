import AppKit
import UniformTypeIdentifiers

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var instance: AppDelegate?
    private var openedFilesAtLaunch = false

    static func main() {
        // Writing to the stdin of a tool that already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        instance = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(target: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = ConfigStore.shared
        if store.isFirstLaunch {
            AppActions.showSettings()
        }
        // Files passed at launch arrive before this point; show the start window otherwise.
        DispatchQueue.main.async { [self] in
            if !openedFilesAtLaunch && !store.isFirstLaunch {
                AppActions.showHome()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFilesAtLaunch = true
        for url in urls { AppActions.open(url) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ConfigStore.shared.reloadFromDisk()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppActions.showHome() }
        return true
    }

    // MARK: Menu actions

    @objc func openDocument(_ sender: Any?) { AppActions.chooseFile() }
    @objc func showSettings(_ sender: Any?) { AppActions.showSettings() }
    @objc func showUninstaller(_ sender: Any?) { AppActions.showUninstaller() }
    @objc func showHome(_ sender: Any?) { AppActions.showHome() }
}

/// Entry points shared by the menu, the start window and the Finder.
@MainActor
enum AppActions {
    static let supportedExtensions = ["dmg", "pkg", "mpkg"]

    static func open(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "dmg":
            InstallFlow.openDiskImage(url)
        case "pkg", "mpkg":
            InstallFlow.openPackage(url, source: url.lastPathComponent, isStagedCopy: false)
        default:
            let alert = NSAlert()
            alert.messageText = "Dateityp wird nicht unterstützt"
            alert.informativeText = "QuickInstall kann .dmg- und .pkg-Dateien öffnen."
            alert.runModal()
        }
    }

    static func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = "Wähle eine .dmg- oder .pkg-Datei zum Installieren."
        panel.prompt = "Installieren"
        if panel.runModal() == .OK {
            for url in panel.urls { open(url) }
        }
    }

    static func showSettings() {
        ConfigStore.shared.reloadFromDisk()
        WindowManager.shared.show(
            SettingsView(store: ConfigStore.shared),
            title: "QuickInstall – Einstellungen",
            size: NSSize(width: 620, height: 640),
            key: "settings")
    }

    static func showUninstaller() {
        WindowManager.shared.show(
            UninstallView(model: UninstallModel(), history: .shared),
            title: "Programme deinstallieren",
            size: NSSize(width: 900, height: 580),
            key: "uninstall")
    }

    static func showHome() {
        WindowManager.shared.show(
            HomeView(),
            title: "QuickInstall",
            size: NSSize(width: 520, height: 320),
            key: "home")
    }
}
