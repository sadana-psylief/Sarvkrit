import Foundation

/// Hand-written coding for `AnnotationElement.Kind`.
///
/// **Swift's synthesised enum `Codable` throws on an unrecognised case key.** That would mean one
/// annotation made by a newer build renders the *entire* document unopenable — and then the
/// obvious recovery, "ignore what we can't read", silently deletes the user's work the next time
/// they save. Neither is acceptable, so unknown elements are decoded into `.unknown` and written
/// back out byte-for-byte.
///
/// This is the same reasoning `ClipboardItem`'s hand-written decoder records: a format that real
/// users' data is already in cannot be changed casually.
extension AnnotationElement.Kind: Codable {
    private enum Keys: String, CodingKey {
        case type, payload
    }

    /// Stable across releases — these strings are in every saved file.
    private enum Name {
        static let arrow = "arrow"
        static let line = "line"
        static let rectangle = "rectangle"
        static let ellipse = "ellipse"
        static let text = "text"
        static let highlighter = "highlighter"
        static let pencil = "pencil"
        static let spotlight = "spotlight"
        static let counter = "counter"
        static let blur = "blur"
        static let pixelate = "pixelate"
        static let emoji = "emoji"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case Name.arrow:       self = .arrow(try container.decode(ArrowElement.self, forKey: .payload))
        case Name.line:        self = .line(try container.decode(LineElement.self, forKey: .payload))
        case Name.rectangle:   self = .rectangle(try container.decode(ShapeElement.self, forKey: .payload))
        case Name.ellipse:     self = .ellipse(try container.decode(ShapeElement.self, forKey: .payload))
        case Name.text:        self = .text(try container.decode(TextElement.self, forKey: .payload))
        case Name.highlighter: self = .highlighter(try container.decode(HighlightElement.self, forKey: .payload))
        case Name.pencil:      self = .pencil(try container.decode(PencilElement.self, forKey: .payload))
        case Name.spotlight:   self = .spotlight(try container.decode(SpotlightElement.self, forKey: .payload))
        case Name.counter:     self = .counter(try container.decode(CounterElement.self, forKey: .payload))
        case Name.blur:        self = .blur(try container.decode(PixelFilterElement.self, forKey: .payload))
        case Name.pixelate:    self = .pixelate(try container.decode(PixelFilterElement.self, forKey: .payload))
        case Name.emoji:       self = .emoji(try container.decode(EmojiElement.self, forKey: .payload))
        default:
            let blob = try container.decode(AnyCodableValue.self, forKey: .payload)
            self = .unknown(type: type, raw: try AnyCodableValue.canonicalData(blob))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .arrow(let value):       try container.encode(Name.arrow, forKey: .type);       try container.encode(value, forKey: .payload)
        case .line(let value):        try container.encode(Name.line, forKey: .type);        try container.encode(value, forKey: .payload)
        case .rectangle(let value):   try container.encode(Name.rectangle, forKey: .type);   try container.encode(value, forKey: .payload)
        case .ellipse(let value):     try container.encode(Name.ellipse, forKey: .type);     try container.encode(value, forKey: .payload)
        case .text(let value):        try container.encode(Name.text, forKey: .type);        try container.encode(value, forKey: .payload)
        case .highlighter(let value): try container.encode(Name.highlighter, forKey: .type); try container.encode(value, forKey: .payload)
        case .pencil(let value):      try container.encode(Name.pencil, forKey: .type);      try container.encode(value, forKey: .payload)
        case .spotlight(let value):   try container.encode(Name.spotlight, forKey: .type);   try container.encode(value, forKey: .payload)
        case .counter(let value):     try container.encode(Name.counter, forKey: .type);     try container.encode(value, forKey: .payload)
        case .blur(let value):        try container.encode(Name.blur, forKey: .type);        try container.encode(value, forKey: .payload)
        case .pixelate(let value):    try container.encode(Name.pixelate, forKey: .type);    try container.encode(value, forKey: .payload)
        case .emoji(let value):       try container.encode(Name.emoji, forKey: .type);       try container.encode(value, forKey: .payload)
        case .unknown(let type, let raw):
            try container.encode(type, forKey: .type)
            // Re-emitted exactly as it arrived. Anything less loses the newer build's work.
            try container.encode(try JSONDecoder().decode(AnyCodableValue.self, from: raw),
                                 forKey: .payload)
        }
    }
}

/// A JSON value of unknown shape, kept intact across a decode/encode round trip.
///
/// Exists only so an unrecognised annotation can be carried through untouched.
///
/// The bytes are held **canonically** — encoded with sorted keys — because `JSONEncoder` does not
/// promise a stable key order. Without that, decoding and re-encoding the same payload produces
/// different `Data` each time, and `.unknown` elements would compare unequal to themselves.
enum AnyCodableValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AnyCodableValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: AnyCodableValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unrepresentable JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension AnyCodableValue {
    /// Sorted-key JSON, so the same value always produces the same bytes.
    static func canonicalData(_ value: AnyCodableValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
