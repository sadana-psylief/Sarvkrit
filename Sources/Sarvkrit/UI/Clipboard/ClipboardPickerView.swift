import AppKit
import SwiftUI

/// The picker's contents: search, the history, and keyboard-only operation.
struct ClipboardPickerView: View {
    let feature: ClipboardFeature
    @ObservedObject var store: ClipboardStore
    /// Reported whenever filtering changes what's on screen, so the panel can follow.
    let onContentHeightChange: (CGFloat) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var settings: ClipboardSettings { feature.settings }

    private var results: [ClipboardStore.Result] {
        store.search(
            query,
            mode: settings.searchMode,
            sortedBy: settings.sortMode,
            pinned: settings.pinnedPosition
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            list
        }
        // Attached to the ROOT, deliberately. Key events travel up from whatever has focus — the
        // search field — so only an *ancestor* ever sees them. On a sibling, nothing arrives.
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(keys: [.return], phases: .down) { press in
            pasteSelected(asPlainText: press.modifiers.contains(.option))
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { press in
            // ⌥⌫ deletes the highlighted entry. Without the modifier this is ordinary editing in
            // the search field, which must keep working.
            guard press.modifiers.contains(.option) else { return .ignored }
            deleteSelected()
            return .handled
        }
        .onKeyPress(keys: ["p"], phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            togglePin()
            return .handled
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
        .onChange(of: results.count) { _, _ in reportHeight() }
        .onAppear {
            query = ""
            selection = 0
            searchFocused = true
            reportHeight()
            // ⌘1–5 comes through the controller's local key monitor, not onKeyPress — but the
            // decision needs the *visible* results, which only this view has.
            ClipboardPickerController.shared.handleCommandDigit = { digit in
                let visible = results
                guard visible.indices.contains(digit - 1) else { return false }
                selection = digit - 1
                pasteSelected(asPlainText: false)
                return true
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(settings.searchMode == .fuzzy ? "Search (fuzzy)" : "Search clipboard",
                      text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { pasteSelected(asPlainText: false) }
                .onChange(of: query) { _, _ in selection = 0 }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 38)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if results.isEmpty {
                        Text(query.isEmpty ? "Nothing copied yet." : "No matches.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.xl)
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            ClipboardRow(
                                result: result,
                                index: index,
                                isSelected: index == selection,
                                store: store,
                                settings: settings
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = index
                                pasteSelected(asPlainText: false)
                            }
                        }
                    }
                }
            }
            .onChange(of: selection) { _, new in
                withAnimation(nil) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func reportHeight() {
        onContentHeightChange(
            ClipboardPickerLayout.panelHeight(for: results.map(\.item), settings: settings))
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        selection = min(max(0, selection + delta), results.count - 1)
        return .handled
    }

    private func pasteSelected(asPlainText: Bool) {
        guard results.indices.contains(selection) else { return }
        let item = results[selection].item
        dismiss()
        feature.paste(item, asPlainText: asPlainText)
    }

    private func togglePin() {
        guard results.indices.contains(selection) else { return }
        let item = results[selection].item
        store.setPinned(!item.isPinned, id: item.id)
    }

    private func deleteSelected() {
        guard results.indices.contains(selection) else { return }
        store.delete(id: results[selection].item.id)
        // Keep the highlight inside the shortened list rather than pointing past the end.
        selection = min(selection, max(0, results.count - 1))
        reportHeight()
    }
}

private struct ClipboardRow: View {
    let result: ClipboardStore.Result
    let index: Int
    let isSelected: Bool
    let store: ClipboardStore
    let settings: ClipboardSettings

    @State private var isHovering = false
    @State private var showPreview = false

    private var item: ClipboardItem { result.item }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            leading

            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(item.isResolvable() ? Color.primary : Color.secondary)
                    .strikethrough(!item.isResolvable())

                // Only when there's something to say. An empty `Text` still lays out a line, which
                // is what pushed every title up off-centre and made rows look misaligned.
                if !subtitle.isEmpty || item.isPinned {
                    HStack(spacing: 4) {
                        if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
                        if !subtitle.isEmpty { Text(subtitle).font(.system(size: 10)) }
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Theme.Space.sm)

            if index < 5 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: rowHeight)
        .background(isSelected ? Color.accentColor : Color.clear)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .onHover { hovering in
            isHovering = hovering
            guard hovering else {
                // Cancelled on exit, so brushing past rows doesn't flash popovers.
                showPreview = false
                return
            }
            let delay = Double(settings.previewDelayMilliseconds) / 1_000
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if isHovering { showPreview = true }
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: .trailing) { previewContent }
    }

    private var rowHeight: CGFloat {
        // Shared with the panel sizing, so the two can never disagree about how tall a row is.
        var height = ClipboardPickerLayout.rowHeight(for: item, settings: settings)
        if item.isPinned, !ClipboardPickerLayout.hasSubtitle(item, settings: settings) {
            height = ClipboardPickerLayout.twoLineRowHeight
        }
        return height
    }

    @ViewBuilder
    private var leading: some View {
        if case .image = item.kind,
           let thumbnail = store.thumbnail(for: item, height: CGFloat(settings.imageRowHeight)) {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: ClipboardPickerLayout.iconColumnWidth * 2,
                       height: CGFloat(settings.imageRowHeight))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else if settings.showAppIcons,
                  let bundleID = item.sourceBundleID,
                  let icon = store.appIcon(forBundleID: bundleID) {
            // The app's own icon is far more scannable than "com.apple.Safari".
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // One column width for every leading element — the app icon used to be 16 and the
                // fallback symbol 18, so the text shifted 2pt depending on whether the source app
                // happened to resolve.
                .frame(width: ClipboardPickerLayout.iconColumnWidth,
                       height: ClipboardPickerLayout.iconColumnWidth)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: ClipboardPickerLayout.iconColumnWidth)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
        }
    }

    /// Bolds exactly what matched. The ranges come from the search, computed against this same
    /// `displayText` — computing them against the raw text would bold the wrong characters.
    private var highlighted: AttributedString {
        var attributed = AttributedString(result.displayText)
        guard settings.highlightMatches, !result.ranges.isEmpty else { return attributed }

        for range in result.ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].font = .system(size: 12, weight: .bold)
        }
        return attributed
    }

    @ViewBuilder
    private var previewContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if case .image = item.kind,
               let thumbnail = store.thumbnail(for: item, height: 280) {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
            } else {
                ScrollView {
                    Text(item.searchableText)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(Theme.Space.md)
        .frame(width: 320)
    }

    private var symbol: String {
        switch item.kind {
        case .text, .largeText: return "text.alignleft"
        case .richText: return "textformat"
        case .image: return "photo"
        case .files: return "doc"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        switch item.kind {
        case .image(_, let w, let h, _): parts.append("\(w)×\(h)")
        case .files(let paths): parts.append(paths.count == 1 ? "File" : "\(paths.count) files")
        case .largeText(_, _, let count): parts.append("\(count) characters")
        default: break
        }
        if item.copyCount > 1 { parts.append("copied \(item.copyCount)×") }
        if !settings.showAppIcons, let source = item.sourceBundleID {
            parts.append((source as NSString).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }
}
