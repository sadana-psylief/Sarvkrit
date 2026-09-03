import AppKit
import SwiftUI

/// The mode picker, floated over the frozen screen.
struct AllInOnePickerView: View {
    @State private var memory: CaptureModeMemory
    @State private var widthText: String
    @State private var heightText: String
    @State private var timerSeconds: Int

    let onPick: (CaptureModeMemory, Int) -> Void
    let onCancel: () -> Void

    /// Only the modes All-In-One can start. Scrolling and text recognition have their own
    /// shortcuts and their own flows; listing them here would offer a button that behaves
    /// unlike its neighbours.
    private static let modes: [CaptureMode] = [.area, .window, .fullscreen]

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
        VStack(spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(Self.modes, id: \.self) { mode in
                    modeButton(mode)
                }
            }

            if memory.mode == .area {
                HStack(spacing: Theme.Space.xs) {
                    sizeField("Width", text: $widthText)
                    Text("×").foregroundStyle(.secondary)
                    sizeField("Height", text: $heightText)
                    Toggle(isOn: $memory.aspectLocked) {
                        Image(systemName: memory.aspectLocked ? "lock" : "lock.open")
                    }
                    .toggleStyle(.button)
                    .help("Lock the aspect ratio while dragging")
                }
                .font(.caption)
            }

            HStack(spacing: Theme.Space.sm) {
                Picker("Timer", selection: $timerSeconds) {
                    Text("No timer").tag(0)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                }
                .labelsHidden()
                .frame(width: 96)

                Button("Capture") { pick() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Space.md)
        .frame(width: 380)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        // The panel is borderless, so the background is the only thing that can move it.
        .background(WindowDragHandle())
    }

    private func modeButton(_ mode: CaptureMode) -> some View {
        Button {
            memory.mode = mode
        } label: {
            VStack(spacing: 4) {
                Image(systemName: mode.symbolName).font(.system(size: 18))
                Text(mode.title).font(.caption2)
            }
            .frame(width: 84, height: 56)
            .background(memory.mode == mode ? Color.accentColor.opacity(0.2) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .clickableCursor()
    }

    private func sizeField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .monospacedDigit()
            .accessibilityLabel(label)
    }

    private func pick() {
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
