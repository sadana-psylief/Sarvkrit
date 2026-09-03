import AppKit
import SwiftUI

/// The capture bar: one shortcut, every mode.
///
/// Two bars side by side, matching the shape the category has settled on — modes on the left, the
/// size of what you are about to take on the right. The split matters: the modes are a choice you
/// make constantly and the size is one you touch rarely, and putting them in one container made
/// the rare thing compete with the common one.
struct AllInOnePickerView: View {
    @State private var memory: CaptureModeMemory
    @State private var widthText: String
    @State private var heightText: String
    @State private var timerSeconds: Int
    @State private var hovered: CaptureMode?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case width, height }

    let onPick: (CaptureModeMemory, Int) -> Void
    let onCancel: () -> Void

    /// The modes this bar can start.
    ///
    /// Text recognition sits after a divider because it is the one entry that doesn't produce a
    /// picture — grouping it with the others would imply it does.
    private static let captureModes: [CaptureMode] = [.area, .fullscreen, .window, .scrolling]

    init(memory: CaptureModeMemory,
         timerSeconds: Int,
         onPick: @escaping (CaptureModeMemory, Int) -> Void,
         onCancel: @escaping () -> Void) {
        _memory = State(initialValue: memory)
        _widthText = State(initialValue: memory.pixelSize.map { String(Int($0.width)) } ?? "")
        _heightText = State(initialValue: memory.pixelSize.map { String(Int($0.height)) } ?? "")
        _timerSeconds = State(initialValue: timerSeconds)
        self.onPick = onPick
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(alignment: .center, spacing: CaptureChrome.Metrics.barGap) {
            modeBar
            sizeBar
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    // MARK: - Modes

    private var modeBar: some View {
        CaptureChrome.Bar {
            HStack(spacing: CaptureChrome.Metrics.cellGap) {
                ForEach(Self.captureModes, id: \.self) { mode in
                    cell(for: mode)
                }
                timerCell
                // One divider, before the entry that doesn't produce a picture. Fencing the timer
                // off as well implied it was a different *kind* of thing, when it is a modifier on
                // whichever mode you pick next.
                divider
                cell(for: .textRecognition)
            }
            .padding(CaptureChrome.Metrics.barPadding)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(CaptureChrome.Colours.divider)
            .frame(width: 1, height: CaptureChrome.Metrics.dividerHeight)
            .padding(.horizontal, 5)
    }

    private func cell(for mode: CaptureMode) -> some View {
        let isSelected = memory.mode == mode
        let isHovered = hovered == mode
        return Button {
            memory.mode = mode
            // Picking a mode is the decision; nothing else on the bar needs confirming.
            commit()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: CaptureChrome.Metrics.iconSize, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(CaptureChrome.Colours.icon)
                    .frame(height: CaptureChrome.Metrics.iconSize + 4)
                Text(mode.title)
                    .font(CaptureChrome.Text.label)
                    .foregroundStyle(isSelected || isHovered
                                     ? CaptureChrome.Colours.labelStrong
                                     : CaptureChrome.Colours.label)
            }
            .frame(width: CaptureChrome.Metrics.cellWidth,
                   height: CaptureChrome.Metrics.cellHeight)
            .background(
                RoundedRectangle(cornerRadius: CaptureChrome.Metrics.cellRadius,
                                 style: .continuous)
                    .fill(isSelected ? CaptureChrome.Colours.cellSelected
                          : isHovered ? CaptureChrome.Colours.cellHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .onHover { hovered = $0 ? mode : (hovered == mode ? nil : hovered) }
        .help(mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The timer is a mode-shaped control that cycles rather than a picker, so it doesn't open a
    /// menu over the screen you are about to capture.
    private var timerCell: some View {
        let isHovered = hovered == nil && timerSeconds > 0
        return Button {
            timerSeconds = [0, 3, 5, 10].first { $0 > timerSeconds } ?? 0
        } label: {
            VStack(spacing: 6) {
                Image(systemName: timerSeconds == 0 ? "timer" : "timer.circle.fill")
                    .font(.system(size: CaptureChrome.Metrics.iconSize, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(CaptureChrome.Colours.icon)
                    .frame(height: CaptureChrome.Metrics.iconSize + 4)
                Text(timerSeconds == 0 ? "Timer" : "\(timerSeconds)s")
                    .font(CaptureChrome.Text.label)
                    .foregroundStyle(timerSeconds > 0
                                     ? CaptureChrome.Colours.labelStrong
                                     : CaptureChrome.Colours.label)
            }
            .frame(width: CaptureChrome.Metrics.cellWidth,
                   height: CaptureChrome.Metrics.cellHeight)
            .background(
                RoundedRectangle(cornerRadius: CaptureChrome.Metrics.cellRadius,
                                 style: .continuous)
                    .fill(timerSeconds > 0 ? CaptureChrome.Colours.cellSelected
                          : isHovered ? CaptureChrome.Colours.cellHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help("Count down before capturing")
        .accessibilityLabel(timerSeconds == 0 ? "No timer" : "\(timerSeconds) second timer")
    }

    // MARK: - Size

    private var sizeBar: some View {
        CaptureChrome.Bar {
            HStack(spacing: 8) {
                field(text: $widthText, placeholder: "Auto", focus: .width)
                Text("×")
                    .font(CaptureChrome.Text.label)
                    .foregroundStyle(CaptureChrome.Colours.label)
                field(text: $heightText, placeholder: "Auto", focus: .height)

                Rectangle()
                    .fill(CaptureChrome.Colours.divider)
                    .frame(width: 1, height: 26)
                    .padding(.horizontal, 2)

                Button {
                    memory.aspectLocked.toggle()
                } label: {
                    Image(systemName: memory.aspectLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(memory.aspectLocked
                                         ? CaptureChrome.Colours.labelStrong
                                         : CaptureChrome.Colours.label)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(memory.aspectLocked ? CaptureChrome.Colours.cellSelected
                                                          : .clear))
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help("Lock the aspect ratio while dragging")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: CaptureChrome.Metrics.cellHeight
                   + CaptureChrome.Metrics.barPadding * 2)
        }
    }

    private func field(text: Binding<String>, placeholder: String, focus: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(CaptureChrome.Text.value)
            .foregroundStyle(CaptureChrome.Colours.labelStrong)
            .multilineTextAlignment(.center)
            .frame(width: 62, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CaptureChrome.Colours.field))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focusedField == focus
                                  ? Color.accentColor.opacity(0.9)
                                  : Color.white.opacity(0.08),
                                  lineWidth: focusedField == focus ? 2 : 1))
            .focused($focusedField, equals: focus)
            .onSubmit { commit() }
    }

    // MARK: - Commit

    private func commit() {
        var result = memory
        // Both fields or neither — half a typed size is not a size, and silently using one axis
        // would produce a selection the user did not ask for.
        if let width = Double(widthText), let height = Double(heightText),
           width > 0, height > 0 {
            result.pixelSize = CGSize(width: width, height: height)
        } else {
            result.pixelSize = nil
        }
        onPick(result, timerSeconds)
    }
}
