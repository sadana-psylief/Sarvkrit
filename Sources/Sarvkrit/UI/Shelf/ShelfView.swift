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
                LazyVStack(spacing: 0) {
                    ForEach(store.items) { item in
                        ShelfRow(item: item, store: store, feature: feature)
                        if item.id != store.items.last?.id {
                            Divider().padding(.leading, Theme.Space.md)
                        }
                    }
                }
            }
        }
    }
}

/// One parked item, and the drag source that takes it back out.
private struct ShelfRow: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore
    @ObservedObject var feature: ShelfFeature

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayText)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(isResolvable ? .primary : .secondary)
                if !isResolvable {
                    Text("File is missing")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            if isHovering {
                Button { store.remove(id: item.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .accessibilityLabel("Remove from the shelf")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 36)
        .background(isHovering ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Drag out. Greenfield in this app — nothing here dragged anything before.
        //
        // A file vends its own URL rather than a promise: the file already exists on disk, so the
        // receiving app can just take it, and a promise would be a needless round trip. Text and
        // images vend their value directly.
        .onDrag(
            { provider },
            preview: { dragPreview }
        )
        .opacity(isResolvable ? 1 : 0.6)
    }

    private var isResolvable: Bool { store.isResolvable(item) }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .files:
            Image(nsImage: fileIcon)
                .resizable()
                .frame(width: 18, height: 18)
        case .image:
            if let thumbnail = store.thumbnail(for: item, height: 18) {
                Image(nsImage: thumbnail).frame(height: 18)
            } else {
                Image(systemName: "photo").frame(width: 18)
            }
        case .text, .largeText, .richText:
            Image(systemName: "text.alignleft")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }

    private var fileIcon: NSImage {
        guard case .files(let references) = item.kind,
              let first = references.first,
              let url = store.resolve(first)
        else { return NSWorkspace.shared.icon(forFileType: "public.data") }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var dragPreview: some View {
        Text(item.displayText)
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
    }

    private var provider: NSItemProvider {
        switch item.kind {
        case .files(let references):
            // Only the first: `NSItemProvider` carries one item, and a multi-file group is dragged
            // out one row at a time rather than pretending otherwise.
            if let first = references.first, let url = store.resolve(first) {
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
            return NSItemProvider()

        case .text(let value):
            return NSItemProvider(object: value as NSString)

        case .largeText(let fileName, let preview, _):
            guard let data = store.readPayload(fileName),
                  let value = String(data: data, encoding: .utf8)
            else { return NSItemProvider(object: preview as NSString) }
            return NSItemProvider(object: value as NSString)

        case .richText(_, let plain):
            // Plain text on the way out: an `NSItemProvider` carrying RTF needs a promise, and the
            // plain twin is stored precisely so this path never depends on the rtf file surviving.
            return NSItemProvider(object: plain as NSString)

        case .image(let fileName, _, _, _):
            guard let data = store.readPayload(fileName), let image = NSImage(data: data) else {
                return NSItemProvider()
            }
            return NSItemProvider(object: image)
        }
    }
}
