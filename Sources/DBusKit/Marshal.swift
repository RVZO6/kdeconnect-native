import Foundation

public enum DBusError: Error, Equatable, CustomStringConvertible {
    case invalidSignature(String)
    case truncated
    case malformed(String)
    case invalidAddress(String)
    case connectionFailed(String)
    case authenticationFailed(String)
    case disconnected
    case timeout
    case remote(name: String, message: String)

    public var description: String {
        switch self {
        case .invalidSignature(let s): "Invalid D-Bus signature: \(s)"
        case .truncated: "D-Bus message is truncated"
        case .malformed(let s): "Malformed D-Bus message: \(s)"
        case .invalidAddress(let s): "Invalid D-Bus address: \(s)"
        case .connectionFailed(let s): "D-Bus connection failed: \(s)"
        case .authenticationFailed(let s): "D-Bus authentication failed: \(s)"
        case .disconnected: "D-Bus connection closed"
        case .timeout: "D-Bus call timed out"
        case .remote(let name, let message): "\(name): \(message)"
        }
    }
}

/// A parsed single complete type.
indirect enum DBusType: Equatable {
    case basic(Character)
    case array(DBusType)
    case dictEntry(DBusType, DBusType)
    case structure([DBusType])
    case variant

    var alignment: Int {
        switch self {
        case .basic(let c):
            switch c {
            case "y", "g": 1
            case "n", "q": 2
            case "b", "i", "u", "h", "s", "o": 4
            case "x", "t", "d": 8
            default: 1
            }
        case .array: 4
        case .dictEntry, .structure: 8
        case .variant: 1
        }
    }

    static func parse(_ signature: String) throws -> [DBusType] {
        var chars = Array(signature)[...]
        var types: [DBusType] = []
        while !chars.isEmpty {
            types.append(try parseOne(&chars, signature: signature, depth: 0))
        }
        return types
    }

    private static func parseOne(_ chars: inout ArraySlice<Character>, signature: String, depth: Int) throws -> DBusType {
        guard depth < 64, let c = chars.popFirst() else { throw DBusError.invalidSignature(signature) }
        switch c {
        case "y", "b", "n", "q", "i", "u", "x", "t", "d", "s", "o", "g", "h":
            return .basic(c)
        case "v":
            return .variant
        case "a":
            if chars.first == "{" {
                chars.removeFirst()
                let key = try parseOne(&chars, signature: signature, depth: depth + 1)
                guard case .basic = key else { throw DBusError.invalidSignature(signature) }
                let value = try parseOne(&chars, signature: signature, depth: depth + 1)
                guard chars.popFirst() == "}" else { throw DBusError.invalidSignature(signature) }
                return .array(.dictEntry(key, value))
            }
            return .array(try parseOne(&chars, signature: signature, depth: depth + 1))
        case "(":
            var fields: [DBusType] = []
            while chars.first != ")" {
                guard !chars.isEmpty else { throw DBusError.invalidSignature(signature) }
                fields.append(try parseOne(&chars, signature: signature, depth: depth + 1))
            }
            chars.removeFirst()
            guard !fields.isEmpty else { throw DBusError.invalidSignature(signature) }
            return .structure(fields)
        default:
            throw DBusError.invalidSignature(signature)
        }
    }
}

/// Writes values in little-endian D-Bus wire format.
struct DBusEncoder {
    private(set) var data: [UInt8] = []

    mutating func pad(to alignment: Int) {
        while data.count % alignment != 0 { data.append(0) }
    }

    mutating func appendRaw<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        pad(to: MemoryLayout<T>.size)
        appendRaw(value)
    }

    mutating func appendString(_ s: String) {
        let bytes = Array(s.utf8)
        append(UInt32(bytes.count))
        data.append(contentsOf: bytes)
        data.append(0)
    }

    mutating func appendSignature(_ s: String) {
        let bytes = Array(s.utf8)
        data.append(UInt8(bytes.count))
        data.append(contentsOf: bytes)
        data.append(0)
    }

    mutating func encode(_ value: DBusValue) throws {
        switch value {
        case .byte(let v): data.append(v)
        case .bool(let v): append(UInt32(v ? 1 : 0))
        case .int16(let v): append(v)
        case .uint16(let v): append(v)
        case .int32(let v): append(v)
        case .uint32(let v): append(v)
        case .int64(let v): append(v)
        case .uint64(let v): append(v)
        case .double(let v): append(v.bitPattern)
        case .string(let s), .objectPath(let s): appendString(s)
        case .signature(let s): appendSignature(s)
        case .unixFD(let v): append(v)
        case .array(let element, let items):
            // Parse as a whole array type, because a dict entry is only valid inside one.
            let parsed = try DBusType.parse("a" + element)
            guard parsed.count == 1, case .array(let elementType) = parsed[0] else {
                throw DBusError.invalidSignature(element)
            }
            append(UInt32(0))
            let lengthOffset = data.count - 4
            pad(to: elementType.alignment)
            let start = data.count
            for item in items {
                guard item.signature == element else {
                    throw DBusError.malformed("array element \(item.signature) does not match \(element)")
                }
                try encode(item)
            }
            let length = UInt32(data.count - start)
            withUnsafeBytes(of: length.littleEndian) { bytes in
                for i in 0..<4 { data[lengthOffset + i] = bytes[i] }
            }
        case .dictEntry(let k, let v):
            pad(to: 8)
            try encode(k)
            try encode(v)
        case .structure(let fields):
            pad(to: 8)
            for field in fields { try encode(field) }
        case .variant(let inner):
            appendSignature(inner.signature)
            try encode(inner)
        }
    }
}

/// Reads values from D-Bus wire format. Offsets are relative to the start of
/// the message, which is how D-Bus defines alignment.
struct DBusDecoder {
    let bytes: [UInt8]
    let bigEndian: Bool
    var offset: Int
    let end: Int

    init(bytes: [UInt8], bigEndian: Bool, offset: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.bigEndian = bigEndian
        self.offset = offset
        self.end = end ?? bytes.count
    }

    mutating func align(_ alignment: Int) throws {
        let next = (offset + alignment - 1) / alignment * alignment
        guard next <= end else { throw DBusError.truncated }
        offset = next
    }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        try align(size)
        guard offset + size <= end else { throw DBusError.truncated }
        var value: T = 0
        for i in 0..<size {
            let byte = T(bytes[offset + i])
            value |= bigEndian ? byte << T(8 * (size - 1 - i)) : byte << T(8 * i)
        }
        offset += size
        return value
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < end else { throw DBusError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readString() throws -> String {
        let length = Int(try read(UInt32.self))
        return try readStringBytes(length)
    }

    mutating func readSignature() throws -> String {
        let length = Int(try readByte())
        return try readStringBytes(length)
    }

    private mutating func readStringBytes(_ length: Int) throws -> String {
        guard length >= 0, offset + length + 1 <= end else { throw DBusError.truncated }
        guard bytes[offset + length] == 0 else { throw DBusError.malformed("string not NUL-terminated") }
        guard let s = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) else {
            throw DBusError.malformed("string is not UTF-8")
        }
        offset += length + 1
        return s
    }

    mutating func decode(signature: String) throws -> [DBusValue] {
        try DBusType.parse(signature).map { try decode($0, depth: 0) }
    }

    mutating func decode(_ type: DBusType, depth: Int) throws -> DBusValue {
        guard depth < 64 else { throw DBusError.malformed("nesting too deep") }
        switch type {
        case .basic(let c):
            switch c {
            case "y": return .byte(try readByte())
            case "b":
                let v = try read(UInt32.self)
                guard v <= 1 else { throw DBusError.malformed("invalid boolean") }
                return .bool(v == 1)
            case "n": return .int16(try read(Int16.self))
            case "q": return .uint16(try read(UInt16.self))
            case "i": return .int32(try read(Int32.self))
            case "u": return .uint32(try read(UInt32.self))
            case "x": return .int64(try read(Int64.self))
            case "t": return .uint64(try read(UInt64.self))
            case "d": return .double(Double(bitPattern: try read(UInt64.self)))
            case "s": return .string(try readString())
            case "o": return .objectPath(try readString())
            case "g": return .signature(try readSignature())
            case "h": return .unixFD(try read(UInt32.self))
            default: throw DBusError.invalidSignature(String(c))
            }
        case .array(let elementType):
            let length = Int(try read(UInt32.self))
            try align(elementType.alignment)
            let arrayEnd = offset + length
            guard arrayEnd <= end else { throw DBusError.truncated }
            var items: [DBusValue] = []
            while offset < arrayEnd {
                items.append(try decode(elementType, depth: depth + 1))
            }
            guard offset == arrayEnd else { throw DBusError.malformed("array length mismatch") }
            return .array(element: Self.signature(of: elementType), items)
        case .dictEntry(let k, let v):
            try align(8)
            return .dictEntry(try decode(k, depth: depth + 1), try decode(v, depth: depth + 1))
        case .structure(let fields):
            try align(8)
            return .structure(try fields.map { try decode($0, depth: depth + 1) })
        case .variant:
            let signature = try readSignature()
            let types = try DBusType.parse(signature)
            guard types.count == 1, let inner = types.first else { throw DBusError.invalidSignature(signature) }
            return .variant(try decode(inner, depth: depth + 1))
        }
    }

    static func signature(of type: DBusType) -> String {
        switch type {
        case .basic(let c): String(c)
        case .array(let e): "a" + signature(of: e)
        case .dictEntry(let k, let v): "{" + signature(of: k) + signature(of: v) + "}"
        case .structure(let f): "(" + f.map(signature(of:)).joined() + ")"
        case .variant: "v"
        }
    }
}
