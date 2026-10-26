import Foundation
import Testing
@testable import DBusKit

@Suite struct MarshalTests {
    @Test func helloMatchesReferenceBytes() throws {
        // Bytes that libdbus produces for the first Hello call.
        var hello = DBusMessage.methodCall(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                           interface: "org.freedesktop.DBus", member: "Hello")
        hello.serial = 1
        let bytes = try hello.serialize()
        #expect(Array(bytes.prefix(12)) == [0x6c, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0])
        #expect(bytes.count % 8 == 0)
        let parsed = try DBusMessage.parse(bytes)
        #expect(parsed == hello)
    }

    @Test func roundTripsEveryType() throws {
        var message = DBusMessage(kind: .signal)
        message.serial = 42
        message.path = "/modules/kdeconnect"
        message.interface = "org.kde.kdeconnect.daemon"
        message.member = "test"
        message.body = [
            .byte(7), .bool(true), .int16(-3), .uint16(9), .int32(-100_000), .uint32(4_000_000_000),
            .int64(-1 << 40), .uint64(1 << 63), .double(3.25), .string("héllo"), .objectPath("/a/b"),
            .signature("a{sv}"),
            .stringArray([]),
            .stringArray(["one", "two"]),
            .array(element: "x", [.int64(1), .int64(2)]),
            .stringDict(["charge": .int32(35), "isCharging": .bool(false), "names": .stringArray(["LAN"])]),
            .structure([.byte(1), .variant(.uint32(5))]),
            .variant(.array(element: "(sv)", [.structure([.string("k"), .variant(.double(1))])])),
        ]
        let parsed = try DBusMessage.parse(try message.serialize())
        #expect(parsed == message)
        #expect(parsed.bodySignature == "ybnqiuxtdsogasasaxa{sv}(yv)v")
    }

    @Test func emptyArrayOfStructsKeepsPadding() throws {
        var encoder = DBusEncoder()
        try encoder.encode(.array(element: "(ii)", []))
        // 4 length bytes, then padding to the 8-byte struct boundary.
        #expect(encoder.data == [0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func decodesBigEndian() throws {
        var d = DBusDecoder(bytes: [0, 0, 0, 3, 0x61, 0x62, 0x63, 0], bigEndian: true)
        #expect(try d.decode(signature: "s") == [.string("abc")])
    }

    @Test func rejectsInvalidSignatures() {
        for bad in ["a", "(", "()", "a{vs}", "a{s}", "z", "{ss}"] {
            #expect(throws: DBusError.self) { try DBusType.parse(bad) }
        }
    }

    @Test func rejectsTruncatedInput() throws {
        var message = DBusMessage.methodCall(destination: "d", path: "/p", interface: "i.f", member: "m",
                                             body: [.string("payload")])
        message.serial = 3
        let bytes = try message.serialize()
        #expect(throws: DBusError.self) { try DBusMessage.parse(Array(bytes.dropLast(3))) }
    }

    @Test func totalLengthMatchesSerializedSize() throws {
        var message = DBusMessage.methodCall(destination: "d", path: "/p", interface: "i.f", member: "m",
                                             body: [.stringArray(["a", "bb", "ccc"])])
        message.serial = 9
        let bytes = try message.serialize()
        #expect(try DBusMessage.totalLength(ofHeader: Array(bytes.prefix(16))) == bytes.count)
    }

    @Test func parsesUnixAddresses() throws {
        #expect(try DBusAddress.unixPath("unix:path=/tmp/dbus-abc,guid=123") == "/tmp/dbus-abc")
        #expect(try DBusAddress.unixPath("tcp:host=x;unix:path=/tmp/x%20y") == "/tmp/x y")
        #expect(throws: DBusError.self) { try DBusAddress.unixPath("unix:abstract=foo") }
    }

    @Test func accessorsUnwrapVariants() {
        let dict = DBusValue.stringDict(["name": .string("Phone"), "isReachable": .bool(true), "charge": .int32(80)])
        let parsed = dict.dictValue
        #expect(parsed?["name"]?.stringValue == "Phone")
        #expect(parsed?["isReachable"]?.boolValue == true)
        #expect(parsed?["charge"]?.intValue == 80)
    }

    @Test func rejectsOverlongSignature() {
        var encoder = DBusEncoder()
        #expect(throws: DBusError.self) { try encoder.encode(.signature(String(repeating: "s", count: 256))) }
        var message = DBusMessage.methodCall(destination: "d", path: "/p", interface: "i.f", member: "m",
                                             body: Array(repeating: .byte(1), count: 256))
        message.serial = 1
        #expect(throws: DBusError.self) { try message.serialize() }
    }

    @Test func rejectsEmbeddedNul() throws {
        var encoder = DBusEncoder()
        #expect(throws: DBusError.self) { try encoder.encode(.string("a\u{0}b")) }
        var d = DBusDecoder(bytes: [3, 0, 0, 0, 0x61, 0, 0x62, 0], bigEndian: false)
        #expect(throws: DBusError.self) { try d.decode(signature: "s") }
    }

    @Test func rejectsBodyWithoutSignature() throws {
        var message = DBusMessage.methodCall(destination: "d", path: "/p", interface: "i.f", member: "m")
        message.serial = 1
        var bytes = try message.serialize()
        // Claim a 4-byte body that the header does not describe.
        bytes[4] = 4
        bytes += [0, 0, 0, 0]
        #expect(throws: DBusError.self) { try DBusMessage.parse(bytes) }
    }

    @Test func rejectsReplyWithoutReplySerial() throws {
        var reply = DBusMessage(kind: .methodReturn)
        reply.serial = 2
        #expect(throws: DBusError.self) { try DBusMessage.parse(try reply.serialize()) }
    }
}
