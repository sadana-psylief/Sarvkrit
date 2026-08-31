import SwiftUI

struct ShelfDetailView: View {
    @ObservedObject var feature: ShelfFeature
    @ObservedObject var store: ShelfStore
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Shelf", isOn: app.binding(for: feature))
            } footer: {
                Text("""
                    Drag files, text or links onto the shelf, then drag them back out when you know \
                    where they go.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open when I drag to a screen edge", isOn: Binding(
                    get: { feature.opensFromScreenEdge },
                    set: { feature.opensFromScreenEdge = $0 }
                ))
                if feature.opensFromScreenEdge {
                    Picker("Edge", selection: Binding(
                        get: { feature.screenEdge },
                        set: { feature.screenEdge = $0 }
                    )) {
                        ForEach(ScreenPlacement.Edge.allCases) { Text($0.title).tag($0) }
                    }
                }
                Toggle("Open when I start dragging", isOn: Binding(
                    get: { feature.opensWhenDraggingStarts },
                    set: { feature.opensWhenDraggingStarts = $0 }
                ))
                Toggle("Open with ⌃⌥S", isOn: Binding(
                    get: { feature.globalShortcutEnabled },
                    set: { feature.globalShortcutEnabled = $0 }
                ))
            } header: {
                Text("Opening")
            } footer: {
                Text("""
                    You can also open the shelf from the Sarvkrit menu. Every one of these works \
                    without any permission — the screen edge because macOS tells a window when a \
                    drag passes over it, drag-to-open because watching the mouse needs no \
                    permission the way watching the keyboard would, and the shortcut because it's \
                    registered with the system rather than by listening for keys.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("On the shelf") {
                    Text(store.items.isEmpty ? "Nothing" : "\(store.items.count)")
                        .foregroundStyle(.secondary)
                }
                if !store.items.isEmpty {
                    Button("Clear the Shelf", role: .destructive) { store.clear() }
                }
            } header: {
                Text("Contents")
            } footer: {
                Text("""
                    Files are held as references, not copies. Taking something off the shelf never \
                    deletes your file, and Sarvkrit follows a file that's renamed or moved while \
                    it's parked. Text and images you drop are stored inside Sarvkrit and do go when \
                    you remove them.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
