import Foundation

/// A single D-Bus value. Arrays carry their element signature so that empty
/// arrays still marshal with the correct type.
public indirect enum DBusValue: Equatable, Sendable {
    case byte(UInt8)
    case bool(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    case unixFD(UInt32)
    case array(element: String, [DBusValue])
    case dictEntry(DBusValue, DBusValue)
    case structure([DBusValue])
    case variant(DBusValue)

    public var signature: String {
        switch self {
        case .byte: "y"
        case .bool: "b"
        case .int16: "n"
        case .uint16: "q"
        case .int32: "i"
        case .uint32: "u"
        case .int64: "x"
        case .uint64: "t"
        case .double: "d"
        case .string: "s"
        case .objectPath: "o"
        case .signature: "g"
        case .unixFD: "h"
        case .array(let element, _): "a" + element
        case .dictEntry(let k, let v): "{" + k.signature + v.signature + "}"
        case .structure(let fields): "(" + fields.map(\.signature).joined() + ")"
        case .variant: "v"
        }
    }

    // MARK: Convenience constructors

    public static func stringArray(_ values: [String]) -> DBusValue {
        .array(element: "s", values.map { .string($0) })
    }

    public static func stringDict(_ values: [String: DBusValue]) -> DBusValue {
        .array(element: "{sv}", values.sorted { $0.key < $1.key }.map { .dictEntry(.string($0.key), .variant($0.value)) })
    }

    // MARK: Convenience accessors

    /// Removes any number of variant wrappers.
    public var unwrapped: DBusValue {
        if case .variant(let inner) = self { return inner.unwrapped }
        return self
    }

    public var stringValue: String? {
        switch unwrapped {
        case .string(let s), .objectPath(let s), .signature(let s): s
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = unwrapped { return b }
        return nil
    }

    public var intValue: Int? {
        switch unwrapped {
        case .byte(let v): Int(v)
        case .int16(let v): Int(v)
        case .uint16(let v): Int(v)
        case .int32(let v): Int(v)
        case .uint32(let v): Int(v)
        case .int64(let v): Int(v)
        case .uint64(let v): Int(exactly: v)
        default: nil
        }
    }

    public var arrayValue: [DBusValue]? {
        if case .array(_, let items) = unwrapped { return items }
        return nil
    }

    public var stringArrayValue: [String]? {
        arrayValue?.compactMap(\.stringValue)
    }

    /// Converts an `a{s*}` array into a dictionary keyed by the string key.
    public var dictValue: [String: DBusValue]? {
        guard let items = arrayValue else { return nil }
        var result: [String: DBusValue] = [:]
        for item in items {
            guard case .dictEntry(let k, let v) = item, let key = k.stringValue else { return nil }
            result[key] = v
        }
        return result
    }
}
