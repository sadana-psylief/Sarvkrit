import AppKit
import SwiftUI

/// The "keep scrolling" prompt shown during a scrolling capture.
///
/// **Bound to an observable rather than rebuilt.** The session used to hand a fresh
/// `NSHostingView` to the panel on every captured frame, which destroys a mouse-down in progress
/// on Done — so "I pressed Done and nothing happened" was a real report, at whatever rate the
/// user happened to be scrolling.
@MainActor
final class ScrollCaptureHUDModel: ObservableObject {
    @Published var frameCount = 0
    /// Set when the stitcher could not match a frame, so the advice can change from generic
    /// encouragement to the specific thing that went wrong.
    @Published var missedAFrame = false
}

struct ScrollCaptureHUDView: View {
    @ObservedObject var model: ScrollCaptureHUDModel
    let onFinish: () -> Void
    let onCancel: () -> Void

    private var detail: String {
        if model.missedAFrame {
            return "Scroll more slowly, and in one direction"
        }
        return model.frameCount == 0
            ? "Sarvkrit takes a frame as you go"
            : "\(model.frameCount) frames captured"
    }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: model.missedAFrame ? "exclamationmark.triangle" : "arrow.down.doc")
                .font(.system(size: 18))
                .foregroundStyle(model.missedAFrame ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scroll to capture")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
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
