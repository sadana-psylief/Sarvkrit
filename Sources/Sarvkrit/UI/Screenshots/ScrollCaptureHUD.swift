import AppKit
import SwiftUI

/// The "keep scrolling" prompt shown during a scrolling capture.
struct ScrollCaptureHUDView: View {
    let frameCount: Int
    let onFinish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scroll slowly to capture")
                    .font(.subheadline.weight(.semibold))
                Text(frameCount == 0
                     ? "Sarvkrit takes a frame each time you pause"
                     : "\(frameCount) frames captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Button("Done", action: onFinish).keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Space.md)
        .frame(width: 400)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        .background(WindowDragHandle())
    }
}
