import AppKit
import SwiftUI

/// Everything captured, as a shelf across the bottom of the screen.
///
/// **A shelf over the dimmed desktop rather than a window**, which is what the reference does and
/// is right for what this is: you open history to grab one thing and get on with what you were
/// doing. A window means a window to place, focus, and then close; a shelf appears over whatever
/// is already there and goes away the moment you have what you came for.
@MainActor
final class CaptureHistoryWindowController: NSObject {
    static let shared = CaptureHistoryWindowController()

    private var panel: FloatingPanel?
    private var escapeMonitor: Any?

    weak var store: CaptureHistoryStore?
    var openEditor: ((CaptureHistoryItem) -> Void)?
    var pinToScreen: ((CaptureHistoryItem) -> Void)?

    var isPresenting: Bool { panel != nil }

    func toggle() { isPresenting ? dismiss() : show() }

    func show() {
        guard let store else { return }
        dismiss()

        guard let screen = ScreenPlacement.screenUnderPointer() else { return }
        // Tall enough for the filters, a 215pt thumbnail and its caption or actions, and no
        // taller — a shelf sized as a fraction of the screen is mostly empty on a large display.
        let height: CGFloat = 360
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                           width: screen.frame.width, height: height)

        let panel = FloatingPanel(
            contentRect: frame,
            // Key, because Escape closes it and the arrows move the selection.
            style: .init(level: .modalPanel, acceptsKey: true, clickThrough: false,
                         joinsAllSpaces: true, hasShadow: false))
        panel.contentView = NSHostingView(rootView: CaptureHistoryShelf(
            store: store,
            onOpen: { [weak self] in self?.openEditor?($0); self?.dismiss() },
            onPin: { [weak self] in self?.pinToScreen?($0); self?.dismiss() },
            onDismiss: { [weak self] in self?.dismiss() }))
        panel.setFrame(frame, display: false)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            MainActor.assumeIsolated { self?.dismiss() }
            return nil
        }
    }

    func dismiss() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct CaptureHistoryShelf: View {
    @ObservedObject var store: CaptureHistoryStore
    let onOpen: (CaptureHistoryItem) -> Void
    let onPin: (CaptureHistoryItem) -> Void
    let onDismiss: () -> Void

    @State private var filter: CaptureMode?
    @State private var selection: UUID?

    private var visible: [CaptureHistoryItem] {
        guard let filter else { return store.items }
        return store.items.filter { $0.mode == filter }
    }

    /// Only the kinds actually present. A filter that can only return nothing is a dead end the
    /// user has to press to discover.
    private var availableModes: [CaptureMode] {
        CaptureMode.allCases.filter { mode in store.items.contains { $0.mode == mode } }
    }

    var body: some View {
        VStack(spacing: 16) {
            filters
            if visible.isEmpty { empty } else { row }
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
        // The row takes the remaining height and centres itself in it, so a shelf sized to the
        // screen doesn't leave a band of empty dark under the thumbnails.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CaptureChrome.Colours.surface)
        .background(VisualEffectBackground())
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            capsule("All", isOn: filter == nil) { filter = nil }
            ForEach(availableModes, id: \.self) { mode in
                capsule(mode.title, isOn: filter == mode) { filter = mode }
            }
        }
    }

    private func capsule(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.85))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(isOn ? Color.accentColor : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .clickableCursor()
    }

    private var row: some View {
        // No `scrollTo` on appear. The list is already newest-first, so the newest is at the
        // leading edge anyway — and scrolling to it pinned it flush against the shelf's left
        // edge, eating the padding and clipping the first tile.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 28) {
                ForEach(visible) { item in
                    ShelfTile(store: store, item: item,
                              isSelected: selection == item.id,
                              onSelect: { selection = selection == item.id ? nil : item.id },
                              onOpen: { onOpen(item) },
                              onPin: { onPin(item) })
                }
            }
            .padding(.horizontal, 40)
            .frame(maxHeight: .infinity)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text(store.items.isEmpty ? "Nothing captured yet" : "Nothing of that kind")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One capture on the shelf: a large thumbnail, with its actions revealed when it is chosen.
private struct ShelfTile: View {
    @ObservedObject var store: CaptureHistoryStore
    let item: CaptureHistoryItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onPin: () -> Void

    @State private var isHovering = false

    private let height: CGFloat = 215

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let thumbnail = store.thumbnail(for: item, height: height * 2) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: height * 1.4)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor
                                             : Color.white.opacity(isHovering ? 0.4 : 0.15),
                                  lineWidth: isSelected ? 3 : 1))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .overlay(CaptureDragSource(url: store.url(for: item),
                                       preview: store.thumbnail(for: item, height: 240)))
            .onTapGesture { onSelect() }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }

            if isSelected {
                HStack(spacing: 8) {
                    action("Annotate", "pencil.tip", prominent: true, onOpen)
                    action("Pin", "pin", prominent: false, onPin)
                    action("Copy", "doc.on.doc", prominent: false) {
                        guard let image = NSImage(contentsOf: store.url(for: item)),
                              let tiff = image.tiffRepresentation,
                              let rep = NSBitmapImageRep(data: tiff),
                              let png = rep.representation(using: .png, properties: [:])
                        else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setData(png, forType: .png)
                    }
                    action("Delete", "trash", prominent: false) { store.remove(id: item.id) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("\(item.dimensionText)  ·  \(CaptureHistoryGrouping.relativeTime(for: item.createdAt))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .help("\(item.mode.title) · \(item.dimensionText)")
    }

    private func action(_ title: String, _ symbol: String, prominent: Bool,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(prominent ? Color.accentColor : Color.white.opacity(0.16),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .clickableCursor()
    }
}
