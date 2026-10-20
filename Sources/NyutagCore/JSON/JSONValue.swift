// Нютаг. Динамический JSON: содержимое событий Matrix разнородно, поэтому держим его как дерево, а не как Codable-структуры.

import Foundation

public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Не JSON-значение")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Доступ

public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var int: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value == value.rounded() && abs(value) < 9_007_199_254_740_992: return Int(value)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var object: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var isNull: Bool { self == .null }

    /// Значение по пути: `event["content", "m.relates_to", "event_id"]`.
    subscript(path: String...) -> JSONValue? {
        var current: JSONValue? = self
        for key in path {
            current = current?[key]
            if current == nil { return nil }
        }
        return current
    }
}

// MARK: - Разбор и сериализация

public extension JSONValue {
    init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Разбор из строки. Метка обязательна: без неё литерал станет `.string`.
    init(parsing string: String) throws {
        try self.init(data: Data(string.utf8))
    }

    /// Компактный JSON (порядок ключей не гарантирован). Для подписей нужен `canonicalJSON`.
    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Canonical JSON по спецификации Matrix (приложение «Signing JSON»): ключи отсортированы по кодовым точкам,
    /// без пробелов, строки без лишнего экранирования, целые числа как есть.
    func canonicalJSON() -> String {
        var out = ""
        appendCanonical(to: &out)
        return out
    }

    private func appendCanonical(to out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .int(let value):
            out += String(value)
        case .double(let value):
            // Спецификация запрещает дроби в подписываемом JSON; целые double печатаем как целые.
            if value == value.rounded(), abs(value) < 1e15 {
                out += String(Int(value))
            } else {
                out += String(value)
            }
        case .string(let value):
            Self.appendEscaped(value, to: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.appendCanonical(to: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            // Сортировка по кодовым точкам Unicode, не по локали.
            let keys = object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                Self.appendEscaped(key, to: &out)
                out += ":"
                object[key]!.appendCanonical(to: &out)
            }
            out += "}"
        }
    }

    private static func appendEscaped(_ string: String, to out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case let s where s.value < 0x20:
                out += String(format: "\\u%04x", s.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

// MARK: - Литералы

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
