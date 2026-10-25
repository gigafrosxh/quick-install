import AppKit
import SwiftUI

struct FileIcon: View {
    let path: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
    }
}

struct ProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBox: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NoticeBox: View {
    let systemImage: String
    let color: Color
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Dropdown with the configured target folders plus "Anderer Ordner …".
struct DestinationPicker: View {
    @ObservedObject var store: ConfigStore
    @Binding var selection: String
    @State private var lastValid = ""

    private static let otherTag = "__other__"

    var body: some View {
        Picker("Installieren nach:", selection: $selection) {
            ForEach(store.config.destinations) { destination in
                Text("\(destination.name) – \(Paths.abbreviate(destination.path))").tag(destination.path)
            }
            if selection != Self.otherTag, !store.config.destinations.contains(where: { $0.path == selection }) {
                Text(Paths.abbreviate(selection)).tag(selection)
            }
            Divider()
            Text("Anderer Ordner …").tag(Self.otherTag)
        }
        .onAppear { lastValid = selection }
        .onChange(of: selection) { newValue in
            guard newValue == Self.otherTag else {
                lastValid = newValue
                return
            }
            // Open the panel outside of the view update.
            DispatchQueue.main.async {
                if let url = chooseFolder(message: "Wähle den Ordner, in den das Programm installiert werden soll.") {
                    store.addDestination(url)
                    selection = store.config.destinations.first { Paths.expand($0.path) == url.path }?.path ?? url.path
                } else {
                    selection = lastValid
                }
            }
        }
    }
}

@MainActor
func chooseFolder(message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Auswählen"
    panel.message = message
    return panel.runModal() == .OK ? panel.url : nil
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
