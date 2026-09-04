import SwiftUI

/// The emoji tool's picker: pick one here, then click the image to place it.
///
/// A popover rather than a row in the toolbar because forty-eight emoji do not fit beside the
/// other controls, and a `Menu` renders emoji at label size — far too small to pick from quickly.
struct EmojiPicker: View {
    @ObservedObject var model: EditorDocumentModel
    @ObservedObject private var recents = EmojiRecents.shared
    @State private var isPresented = false

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 6)

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 4) {
                Text(model.emoji).font(.system(size: 17))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help("Emoji — pick one, then click the image to place it")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !recents.emoji.isEmpty {
                    section("Recent", recents.emoji)
                }
                ForEach(EmojiCatalogue.groups) { group in
                    section(group.title, group.emoji)
                }
            }
            .padding(12)
        }
        .frame(width: 218, height: 320)
    }

    private func section(_ title: String, _ emoji: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(emoji, id: \.self) { value in
                    Button {
                        model.emoji = value
                        recents.record(value)
                        // Placing is the next click on the image, so the tool has to be the emoji
                        // tool — otherwise picking one silently does nothing.
                        model.tool = .emoji
                        model.applyEmojiToSelection()
                        isPresented = false
                    } label: {
                        Text(value)
                            .font(.system(size: 19))
                            .frame(width: 30, height: 28)
                            .background(model.emoji == value ? Color.accentColor.opacity(0.28)
                                                             : .clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                }
            }
        }
    }
}
