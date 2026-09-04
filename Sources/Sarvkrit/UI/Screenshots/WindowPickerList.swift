import AppKit
import SwiftUI

/// Choosing a window from a list instead of hunting for it with the pointer.
///
/// **Both ways exist on purpose**, chosen by a setting. Pointing is faster when the window is
/// already visible; a list is the only way to reach one that is behind something else, and it is
/// the only one that can be driven from the keyboard. Hover-picking without a visible pointer was
/// what made window capture unusable, and that is fixed either way — this is the better answer,
/// not the fix.
@MainActor
final class WindowPickerListController {
    static let shared = WindowPickerListController()

    private var panel: FloatingPanel?
    private var completion: ((CapturableWindow?) -> Void)?

    var isPresenting: Bool { panel != nil }

    func present(windows: [CapturableWindow],
                 thumbnail: @escaping (CapturableWindow) -> NSImage?,
                 completion: @escaping (CapturableWindow?) -> Void) {
        dismiss()
        let listed = WindowListFilter.presentable(windows)
        guard !listed.isEmpty else { completion(nil); return }

        var finished = false
        let finish: (CapturableWindow?) -> Void = { [weak self] picked in
            // A double-click and a Return can both arrive in one turn; without this the capture
            // would be started twice.
            guard !finished else { return }
            finished = true
            self?.dismiss()
            completion(picked)
        }
        self.completion = completion

        let content = WindowPickerListView(windows: WindowListFilter.ordered(listed),
                                           thumbnail: thumbnail,
                                           onPick: { finish($0) },
                                           onCancel: { finish(nil) })
        let size = CGSize(width: 560, height: 460)
        let visible = ScreenPlacement.screenUnderPointer()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = FloatingPanel(
            contentRect: NSRect(x: visible.midX - size.width / 2,
                                y: visible.midY - size.height / 2,
                                width: size.width, height: size.height),
            // Key, and it must be: the whole point is arrow keys, typing and Return.
            style: .init(level: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1),
                         acceptsKey: true, clickThrough: false,
                         joinsAllSpaces: true, hasShadow: true))
        panel.contentView = NSHostingView(rootView: content)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        completion = nil
    }
}

struct WindowPickerListView: View {
    let windows: [CapturableWindow]
    let thumbnail: (CapturableWindow) -> NSImage?
    let onPick: (CapturableWindow) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var visible: [CapturableWindow] {
        WindowListFilter.matching(query, in: windows)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if visible.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(width: 560, height: 460)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "macwindow.on.rectangle")
                .foregroundStyle(.secondary)
            TextField("Search windows", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                // Typing narrows the list, so the selection has to come back inside it — leaving
                // it where it was would capture a window that is no longer on screen.
                .onChange(of: query) { _, _ in selection = 0 }
                .onSubmit { pickSelected() }
            Text("\(visible.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.md)
        .background(WindowDragHandle())
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No window matches “\(query)”")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, window in
                        row(window, isSelected: index == selection)
                            .id(window.id)
                            .onTapGesture { onPick(window) }
                            .onHover { if $0 { selection = index } }
                    }
                }
                .padding(Theme.Space.sm)
            }
            .onChange(of: selection) { _, new in
                guard visible.indices.contains(new) else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(visible[new].id) }
            }
            .background(keyboard)
        }
    }

    /// Arrow keys and Return, without stealing them from the search field.
    private var keyboard: some View {
        Color.clear
            .onKeyPress(.upArrow) {
                selection = WindowListFilter.moving(from: selection, by: -1, count: visible.count)
                return .handled
            }
            .onKeyPress(.downArrow) {
                selection = WindowListFilter.moving(from: selection, by: 1, count: visible.count)
                return .handled
            }
            .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private func pickSelected() {
        guard visible.indices.contains(selection) else { return }
        onPick(visible[selection])
    }

    private func row(_ window: CapturableWindow, isSelected: Bool) -> some View {
        HStack(spacing: Theme.Space.md) {
            preview(window)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title?.isEmpty == false ? window.title! : "Untitled window")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(window.owningAppName ?? "Unknown app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(Int(window.frame.width)) × \(Int(window.frame.height))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func preview(_ window: CapturableWindow) -> some View {
        let box = CGSize(width: 96, height: 60)
        Group {
            if let image = thumbnail(window) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // A window that will not render a preview is still capturable, so it stays in the
                // list with a placeholder rather than being hidden.
                Image(systemName: "macwindow")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: box.width, height: box.height)
        .background(Color.black.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
