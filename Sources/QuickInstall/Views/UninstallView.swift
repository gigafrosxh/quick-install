import AppKit
import SwiftUI

@MainActor
final class UninstallModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case apps = "Programme"
        case packages = "Pakete (pkg)"
        var id: String { rawValue }
    }

    @Published var tab: Tab = .apps
    @Published var search = ""
    @Published var status: String?
    @Published var busy = false

    // Apps
    @Published var apps: [InstalledApp] = []
    @Published var selectedApp: URL? { didSet { loadAppDetails() } }
    @Published var leftovers: [Leftover] = []
    @Published var leftoverSelection: Set<URL> = []
    @Published var owningPackage: String?
    @Published var appSize: Int64?
    @Published var confirmApp = false

    // Packages
    @Published var packages: [String] = []
    @Published var selectedPackage: String? { didSet { loadPackageDetails() } }
    @Published var receipt: PackageReceipt?
    @Published var packageFiles: [String] = []
    @Published var sharedFileCount = 0
    @Published var confirmPackage = false

    var filteredApps: [InstalledApp] {
        let query = search.trimmed
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var filteredPackages: [String] {
        let query = search.trimmed
        guard !query.isEmpty else { return packages }
        return packages.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var currentApp: InstalledApp? { apps.first { $0.url == selectedApp } }

    func reload() {
        let extra = ConfigStore.shared.config.destinations.map(\.url)
        Task {
            let (apps, packages) = await Task.detached {
                (AppScanner.installedApps(extraDirectories: extra), Receipts.thirdPartyIdentifiers())
            }.value
            self.apps = apps
            self.packages = packages
            if let selectedApp, !apps.contains(where: { $0.url == selectedApp }) { self.selectedApp = nil }
            if let selectedPackage, !packages.contains(selectedPackage) { self.selectedPackage = nil }
        }
    }

    /// Adds an app chosen in an open panel or dropped onto the window.
    func add(_ url: URL) {
        guard url.pathExtension == "app" else { return }
        if !apps.contains(where: { $0.url == url }) {
            apps.insert(InstalledApp(url: url), at: 0)
        }
        tab = .apps
        selectedApp = url
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Auswählen"
        if panel.runModal() == .OK, let url = panel.url { add(url) }
    }

    private func loadAppDetails() {
        leftovers = []
        leftoverSelection = []
        owningPackage = nil
        appSize = nil
        guard let app = currentApp else { return }
        Task {
            let (leftovers, owner, size) = await Task.detached {
                (LeftoverFinder.find(bundleIdentifier: app.bundleIdentifier, appName: app.name),
                 AppScanner.owningPackage(of: app.url.path),
                 LeftoverFinder.allocatedSize(of: app.url))
            }.value
            guard selectedApp == app.url else { return }
            self.leftovers = leftovers
            leftoverSelection = Set(leftovers.filter(\.matchesBundleIdentifier).map(\.url))
            owningPackage = owner
            appSize = size
        }
    }

    func uninstallApp() {
        guard let app = currentApp else { return }
        let items = [app.url] + leftovers.filter { leftoverSelection.contains($0.url) }.map(\.url)
        busy = true
        status = nil
        Task {
            defer { busy = false }
            guard await RunningApps.quit(bundleIdentifier: app.bundleIdentifier) else {
                status = "„\(app.name)“ läuft noch. Bitte beende das Programm und versuche es erneut."
                return
            }
            do {
                let failed = try await Task.detached { try Trash.move(items) }.value
                InstallHistory.shared.forgetApp(at: app.url.path)
                if failed.isEmpty {
                    status = "„\(app.name)“ und \(items.count - 1) zugehörige Objekte liegen im Papierkorb."
                } else {
                    status = "„\(app.name)“ wurde entfernt, aber diese Objekte konnten nicht verschoben werden:\n"
                        + failed.map { Paths.abbreviate($0.path) }.joined(separator: "\n")
                }
                selectedApp = nil
                reload()
            } catch ShellError.cancelled {
                status = nil
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func showOwningPackage() {
        guard let owningPackage else { return }
        search = ""
        tab = .packages
        selectedPackage = owningPackage
    }

    private func loadPackageDetails() {
        receipt = nil
        packageFiles = []
        sharedFileCount = 0
        guard let identifier = selectedPackage else { return }
        Task {
            let result = await Task.detached { () -> (PackageReceipt, [String], Int)? in
                guard let receipt = Receipts.info(identifier) else { return nil }
                let removable = Receipts.removableFiles(of: receipt)
                return (receipt, removable.files, removable.shared)
            }.value
            guard selectedPackage == identifier, let result else { return }
            receipt = result.0
            packageFiles = result.1
            sharedFileCount = result.2
        }
    }

    func removePackage() {
        guard let receipt else { return }
        let files = packageFiles
        busy = true
        status = nil
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try Receipts.remove(receipt, files: files) }.value
                InstallHistory.shared.forgetPackage(receipt.identifier)
                status = "Das Paket „\(receipt.identifier)“ wurde entfernt (\(files.count) Dateien)."
                selectedPackage = nil
                reload()
            } catch ShellError.cancelled {
                status = nil
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

struct UninstallView: View {
    @ObservedObject var model: UninstallModel
    @ObservedObject var history: InstallHistory

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 300)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let status = model.status {
                    NoticeBox(systemImage: "info.circle.fill", color: .blue, title: status, detail: nil)
                }
                switch model.tab {
                case .apps: appDetail
                case .packages: packageDetail
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disabled(model.busy)
            .overlay { if model.busy { ProgressView() } }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { model.reload() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.add(url) }
                }
            }
            return true
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 8) {
            Picker("", selection: $model.tab) {
                ForEach(UninstallModel.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Suchen", text: $model.search)
                .textFieldStyle(.roundedBorder)

            switch model.tab {
            case .apps:
                List(model.filteredApps, selection: $model.selectedApp) { app in
                    HStack(spacing: 8) {
                        FileIcon(path: app.url.path, size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.name)
                            if history.record(forAppAt: app.url.path) != nil {
                                Text("über QuickInstall installiert").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(app.url)
                }
                HStack {
                    Button("App wählen …") { model.chooseApp() }
                    Spacer()
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Liste aktualisieren")
                }
            case .packages:
                List(model.filteredPackages, id: \.self, selection: $model.selectedPackage) { identifier in
                    Text(identifier).lineLimit(1).truncationMode(.middle).tag(identifier)
                }
                HStack {
                    Spacer()
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Liste aktualisieren")
                }
            }
        }
        .padding(10)
    }

    // MARK: App detail

    @ViewBuilder
    private var appDetail: some View {
        if let app = model.currentApp {
            HStack(spacing: 14) {
                FileIcon(path: app.url.path, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.title2.bold())
                    Text([app.version.map { "Version \($0)" }, app.bundleIdentifier, model.appSize.map(Format.bytes)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Text(Paths.abbreviate(app.url.path)).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let record = history.record(forAppAt: app.url.path) {
                Text("Am \(Format.date(record.date)) aus „\(record.source)“ installiert.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let owner = model.owningPackage {
                NoticeBox(
                    systemImage: "shippingbox", color: .orange,
                    title: "Wurde mit dem Paket „\(owner)“ installiert",
                    detail: "Pakete legen oft weitere Dateien außerhalb des Programms ab. Entferne es vollständig über den Tab „Pakete“.")
                Button("Zum Paket wechseln") { model.showOwningPackage() }
            }

            Text("Zugehörige Dateien in der Library").font(.headline).padding(.top, 4)
            if model.leftovers.isEmpty {
                Text("Keine gefunden.").foregroundStyle(.secondary)
            } else {
                List(model.leftovers) { leftover in
                    Toggle(isOn: leftoverBinding(leftover.url)) {
                        HStack {
                            Text(Paths.abbreviate(leftover.url.path)).lineLimit(1).truncationMode(.middle)
                            if !leftover.matchesBundleIdentifier {
                                Text("nur Name").font(.caption2).padding(.horizontal, 5)
                                    .background(.orange.opacity(0.2), in: Capsule())
                                    .help("Nur über den Programmnamen gefunden – bitte prüfen.")
                            }
                            Spacer()
                            if let size = leftover.size {
                                Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(minHeight: 120)
            }

            Spacer()
            HStack {
                Button("Im Finder zeigen") { revealInFinder(app.url) }
                Spacer()
                Button("In den Papierkorb legen", role: .destructive) { model.confirmApp = true }
                    .keyboardShortcut(.defaultAction)
            }
            .alert("„\(app.name)“ deinstallieren?", isPresented: $model.confirmApp) {
                Button("In den Papierkorb", role: .destructive) { model.uninstallApp() }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Das Programm und \(model.leftoverSelection.count) ausgewählte zugehörige Objekte werden in den Papierkorb gelegt. Ein laufendes Programm wird vorher beendet.")
            }
        } else {
            placeholder("Wähle links ein Programm aus oder ziehe eine App in dieses Fenster.")
        }
    }

    private func leftoverBinding(_ url: URL) -> Binding<Bool> {
        Binding(
            get: { model.leftoverSelection.contains(url) },
            set: { isOn in
                if isOn { model.leftoverSelection.insert(url) } else { model.leftoverSelection.remove(url) }
            })
    }

    // MARK: Package detail

    @ViewBuilder
    private var packageDetail: some View {
        if let receipt = model.receipt {
            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.identifier).font(.title2.bold()).textSelection(.enabled)
                Text("Version \(receipt.version)" + (receipt.installDate.map { " · installiert am \(Format.date($0))" } ?? ""))
                    .foregroundStyle(.secondary)
                Text("Ziel: \(receipt.absolutePath(""))").font(.caption).foregroundStyle(.secondary)
            }

            Text("\(model.packageFiles.count) Dateien werden gelöscht")
                .font(.headline).padding(.top, 4)
            if model.sharedFileCount > 0 {
                Text("\(model.sharedFileCount) Dateien gehören auch zu anderen Paketen und bleiben erhalten.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            List(model.packageFiles.prefix(1000), id: \.self) { path in
                Text(path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            .frame(minHeight: 150)
            if model.packageFiles.count > 1000 {
                Text("… und \(model.packageFiles.count - 1000) weitere").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Paket entfernen", role: .destructive) { model.confirmPackage = true }
                    .keyboardShortcut(.defaultAction)
            }
            .alert("Paket „\(receipt.identifier)“ entfernen?", isPresented: $model.confirmPackage) {
                Button("Endgültig löschen", role: .destructive) { model.removePackage() }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("\(model.packageFiles.count) Dateien werden mit Administratorrechten endgültig gelöscht (nicht in den Papierkorb), zugehörige Hintergrunddienste werden beendet und der Paketbeleg wird entfernt.")
            }
        } else if model.selectedPackage != nil {
            ProgressRow(text: "Paketinhalt wird gelesen …")
        } else {
            placeholder("Wähle links ein installiertes Paket aus. Apple-eigene Pakete werden nicht angezeigt.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
