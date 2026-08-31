import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var feature: ShelfFeature
    let dismiss: () -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isTargeted ? 2 : 0.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .standardMotion(value: isTargeted)
        // Drag in. Registering the broad set and letting `ShelfDropReader` decide keeps the
        // files-before-text ordering in one tested place.
        .onDrop(of: [.fileURL, .url, .rtf, .png, .tiff, .plainText], isTargeted: $isTargeted) { _ in
            // The providers are ignored: `NSPasteboard.drag` carries the same drop in the form
            // `PasteboardReader` already knows how to read, so the app has one reader rather than
            // two that disagree about what a Finder file looks like.
            let items = ShelfDropReader.items(
                from: NSPasteboard(name: .drag),
                store: store,
                sourceBundleID: FrontmostAppMonitor.shared.bundleID
            )
            guard !items.isEmpty else { return false }
            store.add(items)
            ToastPresenter.shared.show(
                items.count == 1 ? "Parked on the shelf" : "\(items.count) items parked",
                symbolName: "tray.and.arrow.down.fill"
            )
            return true
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "tray.full")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("Shelf")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !store.items.isEmpty {
                Button("Clear") { store.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .clickableCursor()
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .accessibilityLabel("Close the shelf")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 34)
    }

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty {
            VStack(spacing: Theme.Space.sm) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Drop files, text or links here")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Drag them back out when you know where they go.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Theme.Space.lg)
        } else {
            ScrollView {
                LazyVGrid(columns: ShelfLayout.columns, spacing: Theme.Space.md) {
                    ForEach(store.items) { item in
                        ShelfTile(item: item, store: store)
                    }
                }
                .padding(Theme.Space.md)
            }
        }
    }
}

/// Tile metrics, in one place so the panel width and the column count can't disagree.
enum ShelfLayout {
    static let tile: CGFloat = 84
    static let thumbnail = CGSize(width: 56, height: 56)
    static let columnCount = 3

    static var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.Space.md), count: columnCount)
    }

    /// Wide enough for three tiles plus the padding between and around them.
    static var panelWidth: CGFloat {
        CGFloat(columnCount) * tile + CGFloat(columnCount + 1) * Theme.Space.md
    }
}

/// One parked item: its preview, its name, and the drag source that takes it back out.
private struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore
    @ObservedObject private var previews: ShelfThumbnails

    @State private var isHovering = false

    init(item: ShelfItem, store: ShelfStore) {
        self.item = item
        self.store = store
        // Observed so a preview arriving mid-view redraws the tile that was waiting for it.
        _previews = ObservedObject(wrappedValue: MainActor.assumeIsolated { store.previews })
    }

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(width: ShelfLayout.thumbnail.width, height: ShelfLayout.thumbnail.height)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary.opacity(0.4))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
                    // The drag source sits over the preview, which is the part you grab.
                    .overlay(
                        ShelfDragSource(item: item, store: store, dragImage: dragImage)
                            .opacity(isResolvable ? 1 : 0)
                    )

                if isHovering {
                    Button { store.remove(id: item.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .offset(x: 5, y: -5)
                    .accessibilityLabel("Remove from the shelf")
                }
            }

            Text(item.displayText)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isResolvable ? .primary : .secondary)

            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(isResolvable ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                .lineLimit(1)
        }
        .frame(width: ShelfLayout.tile)
        .opacity(isResolvable ? 1 : 0.55)
        .onHover { isHovering = $0 }
        .standardMotion(value: isHovering)
        .help(item.displayText)
    }

    private var isResolvable: Bool { store.isResolvable(item) }

    @ViewBuilder
    private var preview: some View {
        if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(4)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    /// A real Quick Look preview if one has been generated, the file's own icon meanwhile, and for
    /// non-file items whatever the payload itself provides.
    private var previewImage: NSImage? {
        switch item.kind {
        case .files:
            guard let url = store.fileURL(of: item) else { return nil }
            if let generated = MainActor.assumeIsolated({
                previews.thumbnail(
                    for: item, url: url,
                    size: ShelfLayout.thumbnail, scale: NSScreen.main?.backingScaleFactor ?? 2
                )
            }) {
                return generated
            }
            // Never nothing: the plain icon stands in until the preview lands.
            return NSWorkspace.shared.icon(forFile: url.path)

        case .image:
            return store.thumbnail(for: item, height: ShelfLayout.thumbnail.height - 8)

        case .text, .largeText, .richText:
            return nil
        }
    }

    private var dragImage: NSImage? { previewImage }

    private var fallbackSymbol: String {
        switch item.kind {
        case .files: return "doc"
        case .image: return "photo"
        case .text, .largeText, .richText: return "text.alignleft"
        }
    }

    private var subtitle: String {
        guard isResolvable else { return "Missing" }
        switch item.kind {
        case .files(let references):
            return references.count > 1 ? "\(references.count) files" : kindDescription
        case .image(_, let width, let height, _):
            return "\(width)×\(height)"
        case .text(let value):
            return "\(value.count) characters"
        case .largeText(_, _, let count):
            return "\(count) characters"
        case .richText:
            return "Styled text"
        }
    }

    private var kindDescription: String {
        guard let url = store.fileURL(of: item) else { return "File" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }
}
