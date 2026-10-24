import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @State private var handlerMessage: String?
    @State private var handlerRefresh = 0

    var body: some View {
        Form {
            if store.isFirstLaunch {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Willkommen bei QuickInstall").font(.title2.bold())
                        Text("Lege fest, in welche Ordner Programme installiert werden können und welcher davon vorausgewählt ist. Beim Installieren kannst du jedes Mal per Dropdown einen anderen Ordner wählen.")
                            .foregroundStyle(.secondary)
                        Text("Damit QuickInstall sich beim Doppelklick auf .dmg- und .pkg-Dateien öffnet, lege es unten als Standard-App fest.")
                            .foregroundStyle(.secondary)
                        Button("Fertig") {
                            store.isFirstLaunch = false
                            NSApp.keyWindow?.close()
                            AppActions.showHome()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let error = store.loadError {
                Section { ErrorBox(message: error) }
            }

            Section("Zielordner") {
                ForEach(store.config.destinations) { destination in
                    HStack {
                        Button {
                            store.config.defaultDestination = destination.path
                        } label: {
                            Image(systemName: store.config.defaultDestination == destination.path ? "star.fill" : "star")
                                .foregroundStyle(.yellow)
                        }
                        .buttonStyle(.borderless)
                        .help("Als Standard vorauswählen")

                        TextField("Name", text: nameBinding(destination.path))
                            .labelsHidden()
                            .frame(width: 170)
                        Text(Paths.abbreviate(destination.path))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            store.removeDestination(destination)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.config.destinations.count <= 1)
                        .help("Aus der Liste entfernen (der Ordner selbst bleibt erhalten)")
                    }
                }
                Button("Ordner hinzufügen …") {
                    if let url = chooseFolder(message: "Wähle einen Ordner, der im Dropdown erscheinen soll.") {
                        store.addDestination(url)
                    }
                }
                Toggle("Zuletzt verwendeten Ordner vorauswählen (statt ★)", isOn: $store.config.rememberLastDestination)
            }

            Section("DMG-Installation") {
                Toggle("Vor dem Ersetzen einer vorhandenen Version fragen", isOn: $store.config.confirmBeforeReplacing)
                Toggle("Programm nach der Installation öffnen", isOn: $store.config.openAppAfterInstall)
                Toggle("Installationsdatei danach in den Papierkorb legen", isOn: $store.config.trashImageAfterInstall)
            }

            Section("PKG-Installation") {
                Picker("Pakete öffnen mit", selection: $store.config.packageMode) {
                    ForEach(PackageMode.allCases) { Text($0.title).tag($0) }
                }
                Text("QuickInstall zeigt vor der Installation Signatur, Notarisierung, Skripte und Ziel jedes Pakets an und installiert dann mit Apples „installer“. Pakete mit eigenen Installationsschritten lassen sich jederzeit im Apple-Installer öffnen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Standard-App") {
                handlerRow(title: ".dmg-Dateien", type: .diskImageFile)
                handlerRow(title: ".pkg-Dateien", type: .installerPackageFile)
                if let handlerMessage {
                    Text(handlerMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Konfigurationsdatei") {
                Text(Paths.abbreviate(store.fileURL.path))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Im Texteditor öffnen") {
                        NSWorkspace.shared.open(
                            [store.fileURL],
                            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                            configuration: NSWorkspace.OpenConfiguration())
                    }
                    Button("Im Finder zeigen") { revealInFinder(store.fileURL) }
                    Button("Neu laden") { store.reloadFromDisk() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, minHeight: 520)
    }

    private func nameBinding(_ path: String) -> Binding<String> {
        Binding(
            get: { store.config.destinations.first { $0.path == path }?.name ?? "" },
            set: { name in
                if let index = store.config.destinations.firstIndex(where: { $0.path == path }) {
                    store.config.destinations[index].name = name
                }
            })
    }

    @ViewBuilder
    private func handlerRow(title: String, type: UTType) -> some View {
        let current = NSWorkspace.shared.urlForApplication(toOpen: type)
        let isUs = current?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        HStack {
            Text(title)
            Spacer()
            if let current {
                Text(isUs ? "QuickInstall ✓" : current.deletingPathExtension().lastPathComponent)
                    .foregroundColor(isUs ? .green : .secondary)
            }
            Button("QuickInstall verwenden") { makeDefault(for: type, title: title) }
                .disabled(isUs)
        }
        .id(handlerRefresh)
    }

    private func makeDefault(for type: UTType, title: String) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { error in
            DispatchQueue.main.async {
                if let error {
                    handlerMessage = "\(title): \(error.localizedDescription) – Alternativ im Finder: Datei auswählen › Informationen › Öffnen mit › QuickInstall › Alle ändern."
                } else {
                    handlerMessage = "QuickInstall öffnet jetzt \(title)."
                }
                handlerRefresh += 1
            }
        }
    }
}

struct HomeView: View {
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("QuickInstall").font(.largeTitle.bold())
            Text("Doppelklicke eine .dmg- oder .pkg-Datei, ziehe sie hierher oder wähle sie aus.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Datei öffnen …") { AppActions.chooseFile() }
                    .keyboardShortcut(.defaultAction)
                Button("Deinstallieren …") { AppActions.showUninstaller() }
                Button("Einstellungen …") { AppActions.showSettings() }
            }
            .controlSize(.large)
        }
        .padding(30)
        .frame(minWidth: 480, minHeight: 280)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { AppActions.open(url) }
                }
            }
            return true
        }
    }
}
