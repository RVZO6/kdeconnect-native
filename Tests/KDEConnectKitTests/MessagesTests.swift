import DBusKit
import Foundation
import Observation
import Testing
@testable import KDEConnectKit

@MainActor
struct MessagesTests {
    /// The daemon's `(isa(s)xiixxxa(xsss))` structure, in a variant.
    private func wire(uID: Int32, thread: Int64, body: String, addresses: [String], date: Int64, type: Int32,
                      attachments: [DBusValue] = []) -> DBusValue {
        .variant(.structure([
            .int32(1), .string(body), .array(element: "(s)", addresses.map { .structure([.string($0)]) }),
            .int64(date), .int32(type), .int32(1), .int64(thread), .int32(uID), .int64(-1),
            .array(element: "(xsss)", attachments),
        ]))
    }

    /// `show` waits only a short time; the demo answer can take longer on a
    /// busy machine, such as a CI runner. Wait until the load ends.
    private func loaded(_ inbox: MessageInbox, thread: Int64) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while inbox.transcripts[thread]?.isLoading != false, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func message(_ uID: Int32, thread: Int64, _ body: String = "Hi", minutes: Double, box: SMSMessage.Box = .inbox,
                         addresses: [String] = ["+14155550101"]) -> SMSMessage {
        SMSMessage(uID: uID, threadID: thread, body: body, addresses: addresses,
                   date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60), box: box)
    }

    @Test func parsesTheDaemonsMessageStructure() throws {
        let preview = Data([0x89, 0x50, 0x4E, 0x47])
        let value = wire(uID: 44, thread: 22, body: "Hello", addresses: ["+14155550101", "+14155550102"],
                         date: 1_765_063_869_402, type: 2,
                         attachments: [.structure([.int64(7), .string("image/jpeg"),
                                                   .string(preview.base64EncodedString()), .string("PART_7.jpg")])])
        let message = try #require(SMSMessage(value))
        #expect(message.uID == 44)
        #expect(message.threadID == 22)
        #expect(message.body == "Hello")
        #expect(message.addresses == ["+14155550101", "+14155550102"])
        #expect(message.date == Date(timeIntervalSince1970: 1_765_063_869.402))
        #expect(message.box == .sent)
        #expect(!message.isIncoming)
        #expect(message.attachments == [SMSAttachment(partID: 7, mimeType: "image/jpeg", thumbnail: preview,
                                                      uniqueIdentifier: "PART_7.jpg")])
    }

    @Test func rejectsOtherStructures() {
        #expect(SMSMessage(.string("not a message")) == nil)
        #expect(SMSMessage(.structure([.int32(1), .string("short")])) == nil)
    }

    @Test func comparesPhoneNumbersAsKDEConnectDoes() {
        #expect(PhoneNumber.canonical("+1 (415) 555-0101") == "14155550101")
        #expect(PhoneNumber.canonical("0044 7700 900123") == "447700900123")
        #expect(PhoneNumber.canonical("ACME Bank") == "acme bank")
        #expect(PhoneNumber.matches("+1 415 555 0101", "(415) 555-0101"))
        #expect(PhoneNumber.matches("+44 7700 900123", "07700 900123"))
        #expect(!PhoneNumber.matches("+1 415 555 0101", "+1 415 555 0102"))
        // Short codes and names match only as a whole.
        #expect(PhoneNumber.matches("72345", "72345"))
        #expect(!PhoneNumber.matches("2345", "72345"))
        #expect(!PhoneNumber.matches("bank", "acme bank"))
    }

    @Test func readsVCards() throws {
        let card = """
        BEGIN:VCARD\r
        VERSION:2.1\r
        N:Rivera;Alex;;;\r
        item1.TEL;CELL:+1 415 555\r
         0101\r
        TEL;TYPE=home:tel:4155550199\r
        PHOTO;ENCODING=BASE64;TYPE=JPEG:iVBORw==\r
        END:VCARD\r
        """
        let contact = try #require(ContactBook.parseVCard(card, id: "a"))
        #expect(contact.name == "Alex Rivera")
        #expect(contact.numbers == ["+1 415 5550101", "4155550199"])
        #expect(contact.photo == Data(base64Encoded: "iVBORw=="))
        let formatted = try #require(ContactBook.parseVCard("BEGIN:VCARD\nFN:Sam\\, Jr.\nTEL:5550102\nEND:VCARD", id: "b"))
        #expect(formatted.name == "Sam, Jr.")
        #expect(ContactBook.parseVCard("BEGIN:VCARD\nFN:No Number\nEND:VCARD", id: "c") == nil)
    }

    @Test func findsContactsByNumber() {
        let book = ContactBook(deviceId: "phone")
        book.showDemo([.init(id: "alex", name: "Alex Rivera", numbers: ["(415) 555-0101"])])
        #expect(book.name(for: "+14155550101") == "Alex Rivera")
        #expect(book.name(for: "+14155550102") == "+14155550102")
    }

    @Test func keepsTheNewestMessagePerConversation() {
        let inbox = MessageInbox(deviceId: "phone", isDemo: false) { nil }
        inbox.apply([message(1, thread: 1, minutes: 1), message(2, thread: 2, minutes: 5), message(3, thread: 1, minutes: 9)])
        #expect(inbox.conversations.map(\.uID) == [3, 2])
        // An older message, such as one from a thread request, changes nothing.
        inbox.apply([message(4, thread: 2, minutes: 0)])
        #expect(inbox.conversations.map(\.uID) == [3, 2])
    }

    @Test func fillsOpenTranscriptsInOrderWithoutDuplicates() {
        let inbox = MessageInbox(deviceId: "phone", isDemo: false) { nil }
        inbox.apply([message(5, thread: 1, minutes: 5)])
        inbox.open(1)
        inbox.apply([message(5, thread: 1, minutes: 5), message(3, thread: 1, minutes: 3), message(4, thread: 1, minutes: 4)])
        #expect(inbox.transcripts[1]?.messages.map(\.uID) == [3, 4, 5])
        // A conversation that is not open keeps no transcript.
        inbox.apply([message(6, thread: 2, minutes: 6)])
        #expect(inbox.transcripts[2] == nil)
    }

    @Test func pagingCountsOnlyMessagesOfOpenTranscripts() {
        let inbox = MessageInbox(deviceId: "phone", isDemo: false) { nil }
        // Messages of a closed conversation are not kept, so they must not
        // move the offset for older messages.
        inbox.apply((1...5).map { message(Int32($0), thread: 1, minutes: Double($0)) })
        #expect(inbox.olderOffset(1) == 0)
        inbox.open(1)
        inbox.apply([message(5, thread: 1, minutes: 5), message(4, thread: 1, minutes: 4)])
        #expect(inbox.olderOffset(1) == 2)
        inbox.reconnected()
        #expect(inbox.olderOffset(1) == 0)
    }

    @Test func thePhonesCopyReplacesAPendingMessage() throws {
        let inbox = MessageInbox(deviceId: "phone", isDemo: false) { nil }
        inbox.apply([message(1, thread: 1, minutes: 0)])
        inbox.open(1)
        inbox.send("  On my way!\n", on: .conversation(1))
        let sent = try #require(inbox.pending.first)
        #expect(sent.body == "On my way!")
        // Without a daemon, the send fails, and the message stays to try again.
        #expect(sent.failed)
        let echo = SMSMessage(uID: 2, threadID: 1, body: "On my way!", addresses: ["+14155550101"],
                              date: .now, box: .sent)
        inbox.apply([echo])
        #expect(inbox.pending.isEmpty)
        #expect(inbox.transcripts[1]?.messages.first { $0.uID == 2 }?.localID == sent.id)
    }

    @Test func aNewConversationOpensItsThreadWhenThePhoneReportsIt() {
        let inbox = MessageInbox(deviceId: "phone", isDemo: false) { nil }
        inbox.page = .newConversation(address: "415-555-0103")
        inbox.send("Hello", on: inbox.page)
        let echo = SMSMessage(uID: 9, threadID: 42, body: "Hello", addresses: ["+14155550103"], date: .now, box: .sent)
        inbox.apply([echo])
        #expect(inbox.page == .conversation(42))
        #expect(inbox.pending.isEmpty)
        #expect(inbox.transcripts[42]?.messages.map(\.uID) == [9])
    }

    @Test func oneReportConfirmsOnePendingMessage() {
        let inbox = MessageInbox(deviceId: "phone", isDemo: false) { nil }
        inbox.apply([message(1, thread: 1, minutes: 0)])
        inbox.send("OK", on: .conversation(1))
        inbox.send("OK", on: .conversation(1))
        let echo = SMSMessage(uID: 2, threadID: 1, body: "OK", addresses: ["+14155550101"], date: .now, box: .sent)
        // The same message comes as a signal, then again in a list refresh.
        inbox.apply([echo])
        inbox.apply([echo])
        #expect(inbox.pending.count == 1)
    }

    @Test func laterMessagesToANewConversationMoveToItsThread() {
        let inbox = MessageInbox(deviceId: "phone", isDemo: false) { nil }
        inbox.page = .newConversation(address: "415-555-0103")
        inbox.send("Hello", on: inbox.page)
        inbox.send("Are you there?", on: inbox.page)
        inbox.apply([SMSMessage(uID: 9, threadID: 42, body: "Hello", addresses: ["+14155550103"], date: .now, box: .sent)])
        #expect(inbox.page == .conversation(42))
        #expect(inbox.pending.map(\.body) == ["Are you there?"])
        #expect(inbox.pending.first?.threadID == 42)
    }

    @Test func aReconnectAllowsOlderMessagesAgain() async throws {
        let store = KDEConnectStore()
        store.showDemo()
        let inbox = store.inbox(for: try #require(store.selectedDeviceId))
        await inbox.show(1)
        await loaded(inbox, thread: 1)
        // The demo answers with the whole conversation.
        #expect(inbox.transcripts[1]?.reachedStart == true)
        inbox.reconnected()
        #expect(inbox.transcripts[1]?.reachedStart == false)
    }

    @Test func aPhoneReconnectWithoutABusReconnectStartsPagingAgain() async throws {
        let store = KDEConnectStore()
        store.showDemo()
        let id = try #require(store.selectedDeviceId)
        let inbox = store.inbox(for: id)
        await inbox.show(1)
        await loaded(inbox, thread: 1)
        #expect(inbox.transcripts[1]?.reachedStart == true)
        // The phone came back: the daemon loads its plugins again.
        var signal = DBusMessage(kind: .signal)
        signal.sender = ":1.5"
        signal.path = "/modules/kdeconnect/devices/\(id)"
        signal.interface = "org.kde.kdeconnect.device"
        signal.member = "pluginsChanged"
        store.handleSignal(signal)
        #expect(inbox.transcripts[1]?.reachedStart == false)
        #expect(inbox.olderOffset(1) == 0)
    }

    @Test func aResetAppliesWaitingSignalsWithoutPagingState() throws {
        let inbox = MessageInbox(deviceId: "phone", isDemo: false) { nil }
        inbox.apply([message(1, thread: 1, minutes: 1)])
        inbox.open(1)
        var signal = DBusMessage(kind: .signal)
        signal.member = "conversationUpdated"
        signal.body = [wire(uID: 2, thread: 1, body: "New", addresses: ["+14155550101"],
                            date: 1_800_000_000_000 + 120_000, type: 1)]
        inbox.handle(signal)
        // The phone reconnects while the signal waits for its batch.
        inbox.reconnected()
        #expect(inbox.conversations.first?.uID == 2)
        #expect(inbox.olderOffset(1) == 0)
    }

    @Test func aContactLookupWithoutMatchUpdatesWhenContactsLoad() {
        let book = ContactBook(deviceId: "phone")
        nonisolated(unsafe) var changed = false
        withObservationTracking {
            _ = book.contact(for: "+14155550101")
        } onChange: {
            changed = true
        }
        book.showDemo([.init(id: "alex", name: "Alex", numbers: ["4155550101"])])
        #expect(changed)
    }

    @Test func aLoadAskedForDuringALoadRunsAfterIt() async {
        let reads = Counter()
        let gate = Gate()
        let book = ContactBook(deviceId: "phone") { _ in
            let read = reads.increment()
            // Hold the first read open until the test asked for a second load.
            if read == 1 { gate.startAndWait() }
            return [.init(id: "alex", name: read == 1 ? "Alex" : "Alex Rivera", numbers: ["4155550101"])]
        }
        let first = Task { await book.load() }
        // Wait on the main actor, without blocking a thread of the pool
        // that runs the read.
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.hasStarted, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.hasStarted)
        // The phone synced while the first load reads the files.
        await book.load()
        #expect(reads.value == 1)
        gate.open()
        await first.value
        #expect(reads.value == 2)
        #expect(book.name(for: "+14155550101") == "Alex Rivera")
    }

    @Test func eachPhoneHasItsOwnContacts() {
        let store = KDEConnectStore()
        let first = store.contacts(for: "phone-a"), second = store.contacts(for: "phone-b")
        first.showDemo([.init(id: "a", name: "Alex", numbers: ["4155550101"])])
        second.showDemo([.init(id: "b", name: "Bea", numbers: ["4155550101"])])
        #expect(store.contacts(for: "phone-a").name(for: "+14155550101") == "Alex")
        #expect(store.contacts(for: "phone-b").name(for: "+14155550101") == "Bea")
    }

    @Test func demoConversationsLoad() async throws {
        let store = KDEConnectStore()
        store.showDemo()
        let device = try #require(store.selectedDevice)
        #expect(device.has(.sms))
        let inbox = store.inbox(for: device.id)
        #expect(inbox.conversations.count == 8)
        // The page opens only after the messages are loaded.
        await inbox.show(1)
        await loaded(inbox, thread: 1)
        #expect(inbox.page == .conversation(1))
        #expect(inbox.transcripts[1]?.messages.count == 8)
        #expect(inbox.transcripts[1]?.isLoading == false)
        #expect(store.contacts(for: device.id).name(for: "+14155550101") == "Alex Rivera")
    }
}

/// Lets a test hold a read open. Only the reader blocks, and the test, on
/// the main actor, opens the gate; so the read always makes progress.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let release = DispatchSemaphore(value: 0)

    var hasStarted: Bool { lock.withLock { started } }

    /// Marks the read as started, then blocks until `open`, for at most
    /// 5 seconds, so that a failed test cannot hang.
    func startAndWait() {
        lock.withLock { started = true }
        _ = release.wait(timeout: .now() + 5)
    }

    func open() {
        release.signal()
    }
}

/// A thread-safe count for test closures that run off the main actor.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
