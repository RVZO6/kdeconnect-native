import Foundation

public struct DBusMessage: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case methodCall = 1
        case methodReturn = 2
        case error = 3
        case signal = 4
    }

    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let noReplyExpected = Flags(rawValue: 0x1)
        public static let noAutoStart = Flags(rawValue: 0x2)
    }

    public var kind: Kind
    public var flags: Flags = []
    public var serial: UInt32 = 0
    public var path: String?
    public var interface: String?
    public var member: String?
    public var errorName: String?
    public var replySerial: UInt32?
    public var destination: String?
    public var sender: String?
    public var body: [DBusValue] = []

    public init(kind: Kind) { self.kind = kind }

    public static func methodCall(destination: String?, path: String, interface: String?, member: String, body: [DBusValue] = []) -> DBusMessage {
        var m = DBusMessage(kind: .methodCall)
        m.destination = destination
        m.path = path
        m.interface = interface
        m.member = member
        m.body = body
        return m
    }

    public var bodySignature: String { body.map(\.signature).joined() }

    /// The first string argument, which is the human-readable text for error replies.
    public var errorMessage: String { body.first?.stringValue ?? "" }

    // MARK: Wire format

    static let maxMessageSize = 128 * 1024 * 1024

    public func serialize() throws -> [UInt8] {
        var bodyEncoder = DBusEncoder()
        for value in body { try bodyEncoder.encode(value) }

        var fields: [DBusValue] = []
        func field(_ code: UInt8, _ value: DBusValue) {
            fields.append(.structure([.byte(code), .variant(value)]))
        }
        if let path { field(1, .objectPath(path)) }
        if let interface { field(2, .string(interface)) }
        if let member { field(3, .string(member)) }
        if let errorName { field(4, .string(errorName)) }
        if let replySerial { field(5, .uint32(replySerial)) }
        if let destination { field(6, .string(destination)) }
        if let sender { field(7, .string(sender)) }
        if !body.isEmpty { field(8, .signature(bodySignature)) }

        var header = DBusEncoder()
        header.encode(fixed: [UInt8(ascii: "l"), kind.rawValue, flags.rawValue, 1])
        header.append(UInt32(bodyEncoder.data.count))
        header.append(serial)
        try header.encode(.array(element: "(yv)", fields))
        header.pad(to: 8)
        return header.data + bodyEncoder.data
    }

    /// Returns the total length of the message that starts with `prefix`,
    /// which must hold at least 16 bytes.
    static func totalLength(ofHeader prefix: [UInt8]) throws -> Int {
        guard prefix.count >= 16 else { throw DBusError.truncated }
        let bigEndian: Bool
        switch prefix[0] {
        case UInt8(ascii: "l"): bigEndian = false
        case UInt8(ascii: "B"): bigEndian = true
        default: throw DBusError.malformed("unknown endianness")
        }
        var d = DBusDecoder(bytes: prefix, bigEndian: bigEndian, offset: 4)
        let bodyLength = Int(try d.read(UInt32.self))
        _ = try d.read(UInt32.self)
        let fieldsLength = Int(try d.read(UInt32.self))
        let headerLength = (16 + fieldsLength + 7) / 8 * 8
        let total = headerLength + bodyLength
        guard total <= maxMessageSize else { throw DBusError.malformed("message too large") }
        return total
    }

    public static func parse(_ bytes: [UInt8]) throws -> DBusMessage {
        guard bytes.count >= 16 else { throw DBusError.truncated }
        let bigEndian = bytes[0] == UInt8(ascii: "B")
        guard let kind = Kind(rawValue: bytes[1]) else { throw DBusError.malformed("unknown message type") }
        var d = DBusDecoder(bytes: bytes, bigEndian: bigEndian, offset: 4)
        let bodyLength = Int(try d.read(UInt32.self))
        var message = DBusMessage(kind: kind)
        message.flags = Flags(rawValue: bytes[2])
        message.serial = try d.read(UInt32.self)

        guard case .array(_, let fields) = try d.decode(.array(.structure([.basic("y"), .variant])), depth: 0) else {
            throw DBusError.malformed("header fields")
        }
        var signature = ""
        for case .structure(let pair) in fields where pair.count == 2 {
            guard case .byte(let code) = pair[0] else { continue }
            let value = pair[1].unwrapped
            switch code {
            case 1: message.path = value.stringValue
            case 2: message.interface = value.stringValue
            case 3: message.member = value.stringValue
            case 4: message.errorName = value.stringValue
            case 5: if case .uint32(let s) = value { message.replySerial = s }
            case 6: message.destination = value.stringValue
            case 7: message.sender = value.stringValue
            case 8: signature = value.stringValue ?? ""
            default: break
            }
        }
        try d.align(8)
        guard d.offset + bodyLength <= bytes.count else { throw DBusError.truncated }
        var bodyDecoder = DBusDecoder(bytes: bytes, bigEndian: bigEndian, offset: d.offset, end: d.offset + bodyLength)
        message.body = try bodyDecoder.decode(signature: signature)
        return message
    }
}

extension DBusEncoder {
    mutating func encode(fixed bytes: [UInt8]) {
        pad(to: 1)
        for b in bytes { appendRaw(b) }
    }
}
