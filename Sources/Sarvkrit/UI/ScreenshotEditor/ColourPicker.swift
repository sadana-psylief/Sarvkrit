import AppKit
import SwiftUI

/// The annotation palette.
///
/// Eleven swatches rather than six, plus a way out to any colour at all. Six covers the common
/// marks and nothing else — no black for a caption on a pale screenshot, no white for one on a
/// dark screenshot, and no way to match a brand colour. A palette you have to leave the app to
/// escape is a palette that dictates what your annotations look like.
enum AnnotationPalette {
    /// Order matters: it is the order they appear, and 1–6 select the first six by keyboard.
    static let colours: [RGBAColour] = [
        .red, .orange, .yellow, .green, .blue, .purple,
        RGBAColour(r: 1, g: 0.18, b: 0.51),          // pink
        RGBAColour(r: 0.20, g: 0.78, b: 0.75),       // teal
        RGBAColour(r: 0.55, g: 0.35, b: 0.20),       // brown
        .white,
        .black,
    ]

    static let names = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple",
                        "Pink", "Teal", "Brown", "White", "Black"]

    static func name(at index: Int) -> String {
        index < names.count ? names[index] : "Colour \(index + 1)"
    }
}

/// The swatch in the toolbar, and the popover behind it.
struct ColourWell: View {
    @ObservedObject var model: EditorDocumentModel
    @State private var isShowingPalette = false

    var body: some View {
        Button { isShowingPalette.toggle() } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(nsColor: NSColor(cgColor: model.colour.cgColor) ?? .red))
                    .frame(width: 15, height: 15)
                    .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help("Colour")
        .popover(isPresented: $isShowingPalette, arrowEdge: .bottom) {
            palette
        }
    }

    private var palette: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6),
                      spacing: 8) {
                ForEach(Array(AnnotationPalette.colours.enumerated()), id: \.offset) { index, colour in
                    Button {
                        model.colour = colour
                        model.applyStyleToSelection()
                    } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(cgColor: colour.cgColor) ?? .red))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                            .overlay(
                                Circle()
                                    .strokeBorder(model.colour == colour
                                                  ? Color.accentColor : .clear, lineWidth: 2)
                                    .padding(-3))
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .help(AnnotationPalette.name(at: index))
                }
            }

            Divider()

            Button {
                // The system picker, so any colour at all is reachable — including one sampled
                // off the screen with its eyedropper, which is how you match a brand.
                let panel = NSColorPanel.shared
                panel.showsAlpha = false
                panel.color = NSColor(cgColor: model.colour.cgColor) ?? .red
                panel.setTarget(ColourPanelBridge.shared)
                panel.setAction(#selector(ColourPanelBridge.colourChanged(_:)))
                ColourPanelBridge.shared.onChange = { colour in
                    model.colour = colour
                    model.applyStyleToSelection()
                }
                panel.makeKeyAndOrderFront(nil)
            } label: {
                Label("Other Colour…", systemImage: "eyedropper.halffull")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .clickableCursor()
        }
        .padding(12)
        .frame(width: 214)
    }
}

/// Bridges `NSColorPanel`'s target/action to a closure.
///
/// A shared object rather than a per-view one: the panel is a single system-wide window, and
/// giving it a target that can be deallocated while it is still open is a crash waiting for the
/// next colour change.
@MainActor
final class ColourPanelBridge: NSObject {
    static let shared = ColourPanelBridge()

    var onChange: ((RGBAColour) -> Void)?

    @objc func colourChanged(_ sender: NSColorPanel) {
        guard let srgb = sender.color.usingColorSpace(.sRGB) else { return }
        onChange?(RGBAColour(r: Double(srgb.redComponent),
                             g: Double(srgb.greenComponent),
                             b: Double(srgb.blueComponent),
                             a: Double(srgb.alphaComponent)))
    }
}
