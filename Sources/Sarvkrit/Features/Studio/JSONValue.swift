import Foundation

/// Any JSON value, held verbatim.
///
/// **This exists to keep somebody else's work.** A project written by a newer build carries fields
/// this one has never heard of, and the choice is between dropping them on save — quietly deleting
/// work — and holding them untouched. `CaptureBackground.Fill` already takes the second option for
/// a single case; a document with dozens of future fields needs a general answer.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    indirect case array([JSONValue])
    indirect case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            // Unreachable for well-formed JSON, and null is the one value that cannot mislead.
            self = .null
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

/// A `CodingKey` built from a string, for reading and writing fields whose names are not known
/// until runtime.
struct StudioCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
    init(_ name: String) { self.stringValue = name }
}
