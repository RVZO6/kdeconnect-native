import AppKit
import Foundation
@testable import KDEConnectKit
import Testing
@testable import KDEConnectNative

@MainActor
struct MessagesLayoutTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ uID: Int32, minutes: Double, box: SMSMessage.Box = .inbox,
                         addresses: [String] = ["+14155550101"]) -> SMSMessage {
        SMSMessage(uID: uID, threadID: 1, body: "Message \(uID)", addresses: addresses,
                   date: start.addingTimeInterval(minutes * 60), box: box)
    }

    @Test func groupsRunsAndAddsTimeLabelsAfterGaps() {
        let rows = BubbleLayout.rows(messages: [
            message(1, minutes: 0), message(2, minutes: 1),
            message(3, minutes: 2, box: .sent),
            message(4, minutes: 90, box: .sent),
        ], pending: [], isGroup: false)
        #expect(rows.map(\.showsTime) == [true, false, false, true])
        #expect(rows.map(\.startsRun) == [true, false, true, true])
        // A time label ends the run before it, so that bubble has a tail.
        #expect(rows.map(\.endsRun) == [false, true, true, true])
    }

    @Test func groupMessagesFromOtherSendersStartNewRuns() {
        let alex = "+14155550101", sam = "+14155550102"
        let rows = BubbleLayout.rows(messages: [
            message(1, minutes: 0, addresses: [alex, sam]),
            message(2, minutes: 1, addresses: [alex, sam]),
            message(3, minutes: 2, addresses: [sam, alex]),
        ], pending: [], isGroup: true)
        #expect(rows.map(\.sender) == [alex, alex, sam])
        #expect(rows.map(\.startsRun) == [true, false, true])
    }

    @Test func pendingMessagesSortByDateAndShowTheirState() {
        let failed = MessageInbox.PendingMessage(id: UUID(), threadID: 1, body: "Failed",
                                                 date: start.addingTimeInterval(30), failed: true)
        let sending = MessageInbox.PendingMessage(id: UUID(), threadID: 1, body: "Sending",
                                                  date: start.addingTimeInterval(200))
        let rows = BubbleLayout.rows(messages: [message(1, minutes: 0), message(2, minutes: 1)],
                                     pending: [sending, failed], isGroup: false)
        #expect(rows.map(\.body) == ["Message 1", "Failed", "Message 2", "Sending"])
        #expect(rows[1].status == .failed(failed.id))
        #expect(rows[3].status == .sending)
        #expect(rows[3].id == sending.id.uuidString)
        let late = MessageInbox.PendingMessage(id: UUID(), threadID: 1, body: "Late", date: start, unconfirmed: true)
        #expect(BubbleLayout.rows(messages: [], pending: [late], isGroup: false).first?.status == .unconfirmed(late.id))
    }

    @Test func titlesAndPreviews() {
        #expect(ConversationTitle.join(["Alex", "Sam"]) == "Alex & Sam")
        #expect(ConversationTitle.join(["Alex", "Sam", "Jordan"]) == "Alex, Sam & Jordan")
        #expect(ConversationTitle.join(["A", "B", "C", "D", "E"]) == "A, B & 3 more")
        #expect(ContactAvatar.initials("Alex van Rivera") == "AR")
        #expect(ContactAvatar.initials("Mom") == "M")
        #expect(ContactAvatar.initials("+1 415") == nil)
        let picture = SMSMessage(uID: 1, threadID: 1, body: "", addresses: [], date: start, box: .inbox,
                                 attachments: [SMSAttachment(partID: 1, mimeType: "image/jpeg", thumbnail: nil,
                                                             uniqueIdentifier: "a.jpg")])
        #expect(MessagePreview.text(picture) == "Image")
    }

    @Test func changedImageDataDecodesAgain() throws {
        func png(_ size: CGFloat) throws -> Data {
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                NSColor.red.setFill()
                rect.fill()
                return true
            }
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let cache = ImageCache()
        #expect(cache.image(for: "phone|alex", data: try png(8))?.size.width == 8)
        #expect(cache.image(for: "phone|alex", data: try png(16))?.size.width == 16)
    }

    @Test func largeEmojiAreOnlyEmoji() {
        #expect(Emoji.isLarge("👍"))
        #expect(Emoji.isLarge("❤️🎉"))
        #expect(Emoji.isLarge("👨‍👩‍👧"))
        #expect(!Emoji.isLarge("ok"))
        #expect(!Emoji.isLarge("1"))
        #expect(!Emoji.isLarge("👍👍👍👍"))
        #expect(!Emoji.isLarge("👍 yes"))
    }

    @Test func dayLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // A Friday, 08:00 UTC
        #expect(MessageDate.header(now.addingTimeInterval(-3600), now: now, calendar: calendar).day == "Today")
        #expect(MessageDate.header(now.addingTimeInterval(-86_400), now: now, calendar: calendar).day == "Yesterday")
        #expect(MessageDate.listLabel(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "Yesterday")
        #expect(MessageDate.daysAgo(now.addingTimeInterval(-6 * 86_400), now: now, calendar: calendar) == 6)
    }
}
