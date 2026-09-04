import Foundation

/// Hand-written coding for `CaptureBackground.Fill`.
///
/// **Swift's synthesised enum `Codable` throws on an unrecognised case key** — and for a
/// background that failure is quieter and worse than it sounds. `CaptureDocumentFile.decode`
/// catches a decode error and opens the file *flat*, so one fill written by a newer build does not
/// show an error: it silently downgrades every annotation in the document to pixels. That is the
/// same trap `AnnotationElement.Kind` already guards against, on the same rule — an older build
/// must never silently delete a newer build's work.
///
/// **The wire shape is exactly what the synthesised coder produced**, `_0` keys included, so files
/// already written keep opening. That is the whole reason this is more than a few lines.
extension CaptureBackground.Fill: Codable {

    /// Case names as they appear in saved files. Renaming one orphans every document using it.
    private enum Name {
        static let none = "none"
        static let solid = "solid"
        static let gradient = "gradient"
        static let mesh = "mesh"
        static let builtIn = "builtIn"
        static let image = "image"
    }

    private struct CaseKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ name: String) { stringValue = name }
    }

    /// Swift names an unlabelled associated value `_0`; the labelled ones keep their labels.
    private enum Payload: String, CodingKey {
        case unlabelled = "_0"
        case id
        case fileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKey.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "a fill with no case"))
        }

        switch key.stringValue {
        case Name.none:
            self = .none
        case Name.solid:
            let inner = try container.nestedContainer(keyedBy: Payload.self, forKey: key)
            self = .solid(try inner.decode(RGBAColour.self, forKey: .unlabelled))
        case Name.gradient:
            let inner = try container.nestedContainer(keyedBy: Payload.self, forKey: key)
            self = .gradient(try inner.decode(GradientSpec.self, forKey: .unlabelled))
        case Name.mesh:
            let inner = try container.nestedContainer(keyedBy: Payload.self, forKey: key)
            self = .mesh(try inner.decode(MeshSpec.self, forKey: .unlabelled))
        case Name.builtIn:
            let inner = try container.nestedContainer(keyedBy: Payload.self, forKey: key)
            self = .builtIn(id: try inner.decode(String.self, forKey: .id))
        case Name.image:
            let inner = try container.nestedContainer(keyedBy: Payload.self, forKey: key)
            self = .image(fileName: try inner.decode(String.self, forKey: .fileName))
        default:
            let blob = try container.decode(AnyCodableValue.self, forKey: key)
            self = .unknown(type: key.stringValue,
                            raw: try AnyCodableValue.canonicalData(blob))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .none:
            // An empty object, which is what the synthesised coder wrote for a payloadless case.
            _ = container.nestedContainer(keyedBy: Payload.self, forKey: CaseKey(Name.none))
        case .solid(let colour):
            var inner = container.nestedContainer(keyedBy: Payload.self,
                                                  forKey: CaseKey(Name.solid))
            try inner.encode(colour, forKey: .unlabelled)
        case .gradient(let spec):
            var inner = container.nestedContainer(keyedBy: Payload.self,
                                                  forKey: CaseKey(Name.gradient))
            try inner.encode(spec, forKey: .unlabelled)
        case .mesh(let spec):
            var inner = container.nestedContainer(keyedBy: Payload.self,
                                                  forKey: CaseKey(Name.mesh))
            try inner.encode(spec, forKey: .unlabelled)
        case .builtIn(let id):
            var inner = container.nestedContainer(keyedBy: Payload.self,
                                                  forKey: CaseKey(Name.builtIn))
            try inner.encode(id, forKey: .id)
        case .image(let fileName):
            var inner = container.nestedContainer(keyedBy: Payload.self,
                                                  forKey: CaseKey(Name.image))
            try inner.encode(fileName, forKey: .fileName)
        case .unknown(let type, let raw):
            // Re-emitted exactly as it arrived. Anything less loses the newer build's work.
            try container.encode(try JSONDecoder().decode(AnyCodableValue.self, from: raw),
                                 forKey: CaseKey(type))
        }
    }
}

/// Decoding that tolerates a **missing** key, as well as an unknown one.
///
/// Swift's synthesised decoder throws `keyNotFound` for an absent key *even when the property has a
/// default*, so every property added to this struct breaks every document written before it. That
/// already happened twice — `spacing` and `isAutoBalanced` were both added after the first files
/// were saved — and the symptom is the same one the `Fill` codec above is about: the throw reaches
/// `CaptureDocumentFile.decode`, which opens the capture flat and loses every annotation in it.
///
/// `decodeIfPresent` with the property's own default makes an added property a non-event. Encoding
/// stays synthesised; only reading is forgiving.
extension CaptureBackground {
    enum CodingKeys: String, CodingKey {
        case fill, padding, cornerRadius, shadow, aspect, spacing, isAutoBalanced
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CaptureBackground()
        self.init()
        fill = try container.decodeIfPresent(Fill.self, forKey: .fill) ?? fallback.fill
        padding = try container.decodeIfPresent(CGFloat.self, forKey: .padding) ?? fallback.padding
        cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)
            ?? fallback.cornerRadius
        // `.shadow` is itself optional, so "absent" and "explicitly null" have to stay distinct:
        // a document that says there is no shadow must not get the default one back.
        shadow = container.contains(.shadow)
            ? try container.decodeIfPresent(Shadow.self, forKey: .shadow)
            : fallback.shadow
        aspect = try container.decodeIfPresent(AspectRatio.self, forKey: .aspect) ?? fallback.aspect
        spacing = try container.decodeIfPresent(CGFloat.self, forKey: .spacing) ?? fallback.spacing
        isAutoBalanced = try container.decodeIfPresent(Bool.self, forKey: .isAutoBalanced)
            ?? fallback.isAutoBalanced
    }
}

/// The same tolerance for the shadow, for the same reason: it is four properties that have all
/// gained defaults once already, and a document written without one of them must still open.
extension CaptureBackground.Shadow {
    enum CodingKeys: String, CodingKey { case radius, offsetY, opacity, colour }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CaptureBackground.Shadow()
        self.init()
        radius = try container.decodeIfPresent(CGFloat.self, forKey: .radius) ?? fallback.radius
        offsetY = try container.decodeIfPresent(CGFloat.self, forKey: .offsetY) ?? fallback.offsetY
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? fallback.opacity
        colour = try container.decodeIfPresent(RGBAColour.self, forKey: .colour) ?? fallback.colour
    }
}
