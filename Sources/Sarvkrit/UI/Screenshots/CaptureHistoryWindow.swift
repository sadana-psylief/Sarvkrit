import AppKit
import SwiftUI

/// A browsable window of everything captured.
///
/// A window rather than a strip in the settings pane. History is something you go *looking* in —
/// to find the shot from an hour ago and drag it somewhere — and a horizontally scrolling row
/// buried under a list of toggles is not somewhere you can look.
@MainActor
final class CaptureHistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = CaptureHistoryWindowController()

    private var window: NSWindow?
    weak var store: CaptureHistoryStore?
    var openEditor: ((CaptureHistoryItem) -> Void)?
    var pinToScreen: ((CaptureHistoryItem) -> Void)?

    func show() {
        guard let store else { return }

        if let window {
            ActivationPolicyLease.shared.acquire()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Captures"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 620, height: 420)
        window.center()
        window.delegate = self
        window.contentView = NSHostingView(rootView: CaptureHistoryView(
            store: store,
            onOpen: { [weak self] in self?.openEditor?($0) },
            onPin: { [weak self] in self?.pinToScreen?($0) }))
        self.window = window

        ActivationPolicyLease.shared.acquire()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        ActivationPolicyLease.shared.release()
    }
}

struct CaptureHistoryView: View {
    @ObservedObject var store: CaptureHistoryStore
    let onOpen: (CaptureHistoryItem) -> Void
    let onPin: (CaptureHistoryItem) -> Void

    @State private var filter: CaptureMode?
    @State private var selection: UUID?

    private var visible: [CaptureHistoryItem] {
        guard let filter else { return store.items }
        return store.items.filter { $0.mode == filter }
    }

    /// Only the modes actually present. A filter that can only ever return nothing is a dead end
    /// the user has to discover by pressing it.
    private var availableModes: [CaptureMode] {
        CaptureMode.allCases.filter { mode in store.items.contains { $0.mode == mode } }
    }

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if visible.isEmpty { emptyState } else { grid }
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            capsule("All", isOn: filter == nil) { filter = nil }
            ForEach(availableModes, id: \.self) { mode in
                capsule(mode.title, isOn: filter == mode) { filter = mode }
            }
            Spacer()
            if !store.items.isEmpty {
                Text("\(store.items.count) kept")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete All", role: .destructive) { store.clear() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .padding(.top, 22)   // clear of the transparent title bar
    }

    private func capsule(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isOn ? Color.accentColor : Color.secondary.opacity(0.14),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .clickableCursor()
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(CaptureHistoryGrouping.grouped(visible), id: \.0) { section, items in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(items) { item in
                                CaptureTile(store: store, item: item,
                                            isSelected: selection == item.id,
                                            onSelect: { selection = item.id },
                                            onOpen: { onOpen(item) },
                                            onPin: { onPin(item) })
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(store.items.isEmpty ? "Nothing captured yet" : "Nothing of that kind")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if store.items.isEmpty {
                Text("Press ⌃⇧A to capture an area.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One capture in the grid.
private struct CaptureTile: View {
    @ObservedObject var store: CaptureHistoryStore
    let item: CaptureHistoryItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onPin: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                // A fixed 4:3 plate with the capture fitted inside, so a row of mixed shapes
                // still lines up. Filling instead would crop the content the user is scanning for.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                if let thumbnail = store.thumbnail(for: item, height: 300) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }

                if isHovering { actions }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor
                                             : Color.primary.opacity(0.10),
                                  lineWidth: isSelected ? 2 : 1))
            .overlay(CaptureDragSource(url: store.url(for: item),
                                       preview: store.thumbnail(for: item, height: 200)))

            HStack(spacing: 6) {
                Image(systemName: item.mode.symbolName)
                    .font(.system(size: 10))
                Text(item.dimensionText)
                    .monospacedDigit()
                Text("·")
                Text(CaptureHistoryGrouping.relativeTime(for: item.createdAt))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { onOpen() }
        .help("\(item.mode.title) · \(item.dimensionText)")
    }

    private var actions: some View {
        ZStack {
            Color.black.opacity(0.4)
            HStack(spacing: 10) {
                action("pencil.tip", "Annotate", onOpen)
                action("pin", "Pin to screen", onPin)
                action("doc.on.doc", "Copy") {
                    guard let image = NSImage(contentsOf: store.url(for: item)),
                          let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(png, forType: .png)
                }
                action("trash", "Delete") { store.remove(id: item.id) }
            }
        }
        .transition(.opacity)
    }

    private func action(_ symbol: String, _ label: String,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.88), in: Circle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help(label)
        .accessibilityLabel(label)
    }
}
