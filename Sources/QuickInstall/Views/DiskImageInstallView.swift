import AppKit
import SwiftUI

struct DiskImageInstallView: View {
    @ObservedObject var model: DiskImageInstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                FileIcon(path: model.imageURL.path, size: 40)
                VStack(alignment: .leading) {
                    Text(model.imageURL.lastPathComponent).font(.headline)
                    Text(Paths.abbreviate(model.imageURL.deletingLastPathComponent().path))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()

            switch model.phase {
            case .mounting:
                ProgressRow(text: "Image wird geöffnet …")
            case .ready:
                ready
            case let .working(text):
                ProgressRow(text: text)
            case .finished:
                finished
            case let .failed(message):
                ErrorBox(message: message)
                Spacer()
                HStack {
                    Spacer()
                    Button("Schließen") { model.window?.close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 400)
        .alert("Bereits vorhanden", isPresented: conflictAlertShown) {
            Button("Ersetzen", role: .destructive) { model.performInstall() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(conflictMessage)
        }
    }

    // MARK: Ready

    @ViewBuilder
    private var ready: some View {
        if model.items.isEmpty {
            NoticeBox(
                systemImage: "questionmark.folder", color: .orange,
                title: "Kein Programm gefunden",
                detail: "Dieses Image enthält weder ein Programm (.app) noch ein Installationspaket (.pkg).")
            Spacer()
            HStack {
                Button("Im Finder öffnen") { model.revealInFinder(); model.window?.close() }
                Spacer()
                Button("Schließen") { model.window?.close() }.keyboardShortcut(.defaultAction)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.apps.isEmpty {
                        Text("Programme").font(.subheadline).foregroundStyle(.secondary)
                        ForEach(model.apps) { item in
                            Toggle(isOn: selectionBinding(item.url)) {
                                HStack(spacing: 10) {
                                    FileIcon(path: item.url.path)
                                    VStack(alignment: .leading) {
                                        Text(item.name).fontWeight(.medium)
                                        if let version = item.version {
                                            Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    if !model.packages.isEmpty {
                        Text("Installationspakete").font(.subheadline).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(model.packages) { item in
                            HStack(spacing: 10) {
                                FileIcon(path: item.url.path)
                                Text(item.url.lastPathComponent)
                                Spacer()
                                Button("Paket öffnen …") { model.openPackage(item) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !model.apps.isEmpty {
                DestinationPicker(store: .shared, selection: $model.destination)
            }

            HStack {
                Button("Im Finder öffnen") { model.revealInFinder() }
                Spacer()
                Button("Abbrechen") { model.window?.close() }.keyboardShortcut(.cancelAction)
                if !model.apps.isEmpty {
                    Button("Installieren") { model.requestInstall() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selected.isEmpty)
                }
            }
        }
    }

    private func selectionBinding(_ url: URL) -> Binding<Bool> {
        Binding(
            get: { model.selected.contains(url) },
            set: { isOn in
                if isOn { model.selected.insert(url) } else { model.selected.remove(url) }
            })
    }

    private var conflictAlertShown: Binding<Bool> {
        Binding(get: { !model.conflicts.isEmpty }, set: { if !$0 { model.conflicts = [] } })
    }

    private var conflictMessage: String {
        let names = model.conflicts.map(\.lastPathComponent).joined(separator: ", ")
        return "\(names) ist bereits in \(Paths.abbreviate(model.destination)) vorhanden. Die alte Version wird in den Papierkorb gelegt."
    }

    // MARK: Finished

    @ViewBuilder
    private var finished: some View {
        let allGood = model.results.allSatisfy { $0.error == nil }
        NoticeBox(
            systemImage: allGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            color: allGood ? .green : .orange,
            title: allGood ? "Installation abgeschlossen" : "Nicht alles konnte installiert werden",
            detail: model.imageTrashed ? "Das Image wurde in den Papierkorb gelegt." : "Das Image wurde ausgeworfen.")

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.results) { result in
                    HStack(spacing: 10) {
                        if let url = result.installedURL {
                            FileIcon(path: url.path)
                            VStack(alignment: .leading) {
                                Text(result.name).fontWeight(.medium)
                                Text(Paths.abbreviate(url.path)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Im Finder zeigen") { revealInFinder(url) }
                            Button("Öffnen") {
                                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                            }
                        } else {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title2)
                            VStack(alignment: .leading) {
                                Text(result.name).fontWeight(.medium)
                                Text(result.error ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        HStack {
            Spacer()
            Button("Fertig") { model.window?.close() }.keyboardShortcut(.defaultAction)
        }
    }
}
