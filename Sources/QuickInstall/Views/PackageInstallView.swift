import AppKit
import SwiftUI

struct PackageInstallView: View {
    @ObservedObject var model: PackageInstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FileIcon(path: model.packageURL.path, size: 40)
                VStack(alignment: .leading) {
                    Text(model.title).font(.headline)
                    Text(model.source).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()

            switch model.phase {
            case .inspecting:
                ProgressRow(text: "Paket wird geprüft …")
            case .ready:
                if let details = model.details { ready(details) }
            case .installing:
                ProgressRow(text: "„\(model.title)“ wird installiert …")
            case .finished:
                finished
            case let .failed(message):
                ErrorBox(message: message)
                Spacer()
                HStack {
                    Button("Mit Apple-Installer öffnen") { model.openInAppleInstaller() }
                    Spacer()
                    Button("Schließen") { model.window?.close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 520)
    }

    // MARK: Ready

    @ViewBuilder
    private func ready(_ details: PackageDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                signatureBox(details)

                if details.hasScripts {
                    NoticeBox(
                        systemImage: "terminal", color: .orange,
                        title: "Enthält Installationsskripte",
                        detail: "Das Paket führt bei der Installation eigene Skripte mit Administratorrechten aus. Installiere es nur, wenn du dem Hersteller vertraust.")
                }
                if let note = details.inspectionNote {
                    NoticeBox(systemImage: "info.circle", color: .blue, title: "Hinweis", detail: note)
                }

                if !details.apps.isEmpty {
                    Text("Installiert diese Programme").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(details.apps, id: \.self) { path in
                        Label(Paths.abbreviate(path), systemImage: "app.dashed")
                    }
                }

                if !details.components.isEmpty {
                    Text("Bestandteile").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(details.components) { component in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(component.identifier).fontWeight(.medium).textSelection(.enabled)
                                Text(component.version).foregroundStyle(.secondary)
                                if component.hasScripts {
                                    Text("Skripte").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.orange.opacity(0.2), in: Capsule())
                                }
                            }
                            Text("\(component.fileCount) Einträge nach \(component.installLocation)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if details.supportsUserInstall {
            Picker("Installieren:", selection: $model.target) {
                ForEach(PackageTarget.allCases) { Text($0.title).tag($0) }
            }
        } else {
            Text("Ziel: Startvolume (macOS fragt nach deinem Administratorpasswort)")
                .font(.callout).foregroundStyle(.secondary)
        }

        if model.needsRiskConfirmation {
            Toggle("Ich vertraue diesem Paket und möchte es trotzdem installieren", isOn: $model.acceptRisk)
                .toggleStyle(.checkbox)
        }

        HStack {
            Button("Mit Apple-Installer öffnen") { model.openInAppleInstaller() }
                .help("Zeigt die Installationsschritte des Herstellers, z. B. Lizenz oder Komponenten-Auswahl.")
            Spacer()
            Button("Abbrechen") { model.window?.close() }.keyboardShortcut(.cancelAction)
            Button("Installieren") { model.install() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.needsRiskConfirmation && !model.acceptRisk)
        }
    }

    @ViewBuilder
    private func signatureBox(_ details: PackageDetails) -> some View {
        let signature = details.signature
        if details.gatekeeperAccepted {
            NoticeBox(
                systemImage: "checkmark.shield.fill", color: .green,
                title: signature.notarized ? "Signiert und von Apple notarisiert" : "Signiert, von macOS zugelassen",
                detail: signature.signer ?? details.gatekeeperSource)
        } else if signature.isSigned {
            NoticeBox(
                systemImage: "exclamationmark.shield.fill", color: .orange,
                title: "Signiert, aber von macOS nicht zugelassen",
                detail: [signature.signer, signature.status].compactMap { $0 }.joined(separator: "\n"))
        } else {
            NoticeBox(
                systemImage: "xmark.shield.fill", color: .red,
                title: "Nicht signiert",
                detail: "Der Hersteller dieses Pakets lässt sich nicht überprüfen.")
        }
    }

    // MARK: Finished

    @ViewBuilder
    private var finished: some View {
        NoticeBox(
            systemImage: "checkmark.circle.fill", color: .green,
            title: "Installation abgeschlossen",
            detail: model.receipts.isEmpty ? nil : "Paketbelege: " + model.receipts.joined(separator: ", "))

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.installedApps, id: \.self) { url in
                    HStack(spacing: 10) {
                        FileIcon(path: url.path)
                        Text(url.deletingPathExtension().lastPathComponent).fontWeight(.medium)
                        Spacer()
                        Button("Im Finder zeigen") { revealInFinder(url) }
                        Button("Öffnen") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
                if !model.output.trimmed.isEmpty {
                    DisclosureGroup("Ausgabe des Installers") {
                        Text(model.output.trimmed)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        HStack {
            Text("Deinstallieren geht später über Ablage › Programme deinstallieren.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Fertig") { model.window?.close() }.keyboardShortcut(.defaultAction)
        }
    }
}
