import CoreGraphics
import Foundation

/// A bezel drawn around the recording.
///
/// **Data, not image assets** — the same argument `BackgroundCatalogue` makes for gradients. A set
/// of device photographs large enough for a 4K canvas would add tens of megabytes to a menu-bar
/// utility, be wrong at every aspect ratio but the one they were shot at, and need @2x variants.
/// A bezel is a rounded rectangle, an inset and a colour.
struct DeviceFrame: Codable, Equatable, Identifiable {

    struct Colourway: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var body: RGBAColour
        /// A hairline highlight along the bezel's inner edge, which is what stops a flat rectangle
        /// reading as a border rather than as a device.
        var rim: RGBAColour
    }

    var id: String
    var name: String
    /// Bezel thickness as a fraction of the *shorter* side, so it stays in proportion at any size.
    var bezelFraction: Double
    /// The device's own screen corner radius, as a fraction of the shorter side.
    var screenCornerFraction: Double
    var outerCornerFraction: Double
    var colourways: [Colourway]
    /// Native aspect, used to suggest a frame that matches the recording.
    var aspect: Double

    static let macBook = DeviceFrame(
        id: "macbook", name: "MacBook", bezelFraction: 0.018,
        screenCornerFraction: 0.012, outerCornerFraction: 0.028,
        colourways: [
            .init(id: "space-black", name: "Space Black",
                  body: RGBAColour(hex: "1D1D1F"), rim: RGBAColour(hex: "3A3A3C")),
            .init(id: "silver", name: "Silver",
                  body: RGBAColour(hex: "C9CBCD"), rim: RGBAColour(hex: "E8E9EA")),
        ],
        aspect: 16.0 / 10.0)

    static let iPhone = DeviceFrame(
        id: "iphone", name: "iPhone", bezelFraction: 0.035,
        screenCornerFraction: 0.09, outerCornerFraction: 0.12,
        colourways: [
            .init(id: "titanium", name: "Natural Titanium",
                  body: RGBAColour(hex: "8F8A81"), rim: RGBAColour(hex: "C7C2B8")),
            .init(id: "black", name: "Black Titanium",
                  body: RGBAColour(hex: "1F1F21"), rim: RGBAColour(hex: "45454A")),
        ],
        aspect: 9.0 / 19.5)

    static let iPad = DeviceFrame(
        id: "ipad", name: "iPad", bezelFraction: 0.045,
        screenCornerFraction: 0.035, outerCornerFraction: 0.055,
        colourways: [
            .init(id: "space-grey", name: "Space Grey",
                  body: RGBAColour(hex: "53565A"), rim: RGBAColour(hex: "7E8287")),
            .init(id: "silver", name: "Silver",
                  body: RGBAColour(hex: "D5D7D9"), rim: RGBAColour(hex: "F0F1F2")),
        ],
        aspect: 4.0 / 3.0)

    static let all: [DeviceFrame] = [.macBook, .iPhone, .iPad]

    static func frame(id: String) -> DeviceFrame? { all.first { $0.id == id } }

    /// The frame whose aspect is nearest the recording's.
    ///
    /// **A default, never a lock.** Detection that overrides the picker is worse than no detection:
    /// somebody recording a phone-shaped window on a Mac wants whichever they choose.
    static func suggested(for size: CGSize) -> DeviceFrame? {
        guard size.width > 0, size.height > 0 else { return nil }
        let aspect = Double(size.width / size.height)
        return all.min { abs($0.aspect - aspect) < abs($1.aspect - aspect) }
    }
}

/// Which device frame a project is wearing, if any.
struct DeviceFrameSelection: Codable, Equatable {
    var frameID: String?
    var colourwayID: String?

    init() {}

    var isOn: Bool { frameID != nil }

    func resolved() -> (frame: DeviceFrame, colourway: DeviceFrame.Colourway)? {
        guard let frameID, let frame = DeviceFrame.frame(id: frameID) else { return nil }
        let colourway = frame.colourways.first { $0.id == colourwayID } ?? frame.colourways[0]
        return (frame, colourway)
    }
}
