import AppKit
import Foundation

/// Sample conversations for demo mode. The numbers are in the 555-01xx
/// range, which is reserved for fiction.
enum DemoMessages {
    static let alex = "+14155550101", sam = "+14155550102", jordan = "+14155550103"
    static let mom = "+14155550104", priya = "+14155550105"

    static let contacts: [ContactBook.Contact] = [
        .init(id: "demo-alex", name: "Alex Rivera", numbers: ["(415) 555-0101"]),
        .init(id: "demo-sam", name: "Sam Chen", numbers: ["415-555-0102"]),
        .init(id: "demo-jordan", name: "Jordan Lee", numbers: ["+1 415 555 0103"]),
        .init(id: "demo-mom", name: "Mom", numbers: ["4155550104"]),
        .init(id: "demo-priya", name: "Priya Patel", numbers: ["+1 (415) 555-0105"]),
    ]

    static func messages(now: Date) -> [SMSMessage] {
        var uID: Int32 = 0
        var result: [SMSMessage] = []
        func add(_ thread: Int64, _ minutesAgo: Double, _ box: SMSMessage.Box, _ body: String, _ addresses: [String],
                 attachments: [SMSAttachment] = []) {
            uID += 1
            result.append(SMSMessage(uID: uID, threadID: thread, body: body, addresses: addresses,
                                     date: now.addingTimeInterval(-minutesAgo * 60), box: box, attachments: attachments))
        }
        let day = 24.0 * 60
        add(1, day + 130, .inbox, "Did you see the game last night?", [alex])
        add(1, day + 128, .sent, "Only the second half 😅", [alex])
        add(1, day + 128, .sent, "That last goal though", [alex])
        add(1, 125, .inbox, "Are we still on for 6?", [alex])
        add(1, 124, .sent, "Yes! I'll book a table at Luca's", [alex])
        add(1, 120, .inbox, "Perfect", [alex])
        add(1, 120, .inbox, "👍", [alex])
        add(1, 14, .inbox, "Running about 10 minutes late, sorry!", [alex])

        add(2, 3 * day, .sent, "Can you send me the photos from Saturday?", [sam])
        add(2, 3 * day - 6, .inbox, "", [sam],
            attachments: [SMSAttachment(partID: 1, mimeType: "image/png", thumbnail: lakePicture(),
                                        uniqueIdentifier: "demo-lake.png")])
        add(2, 3 * day - 6, .inbox, "The lake one is my favourite", [sam])
        add(2, 190, .inbox, "Can you send me the address for Sunday? https://maps.example.com/trailhead", [sam])

        let group = [jordan, alex, sam]
        add(3, 2 * day, .inbox, "Who's in for hiking on Sunday?", group)
        add(3, 2 * day - 3, .inbox, "Me! What time?", [alex, jordan, sam])
        add(3, 2 * day - 5, .sent, "Count me in", group)
        add(3, 2 * day - 9, .inbox, "8 am at the trailhead?", [sam, jordan, alex])
        add(3, day + 40, .inbox, "Bring snacks 🥾", group)

        add(4, day - 200, .inbox, "Call me when you can ❤️", [mom])
        add(5, 2 * day + 300, .inbox, "Your verification code is 482913. Do not share it with anyone.", ["72345"])
        add(6, 5 * day, .sent, "Thanks for the ride!", [jordan])
        add(6, 5 * day - 2, .inbox, "Any time", [jordan])
        add(7, 8 * day, .inbox, "This is the dental office. Reply YES to confirm your appointment on Monday at 10 am.",
            ["+14155550199"])
        add(7, 8 * day - 30, .sent, "YES", ["+14155550199"])
        add(8, 15 * day, .inbox, "Happy birthday!! 🎉", [priya])
        return result
    }

    /// A small sky-and-water gradient, as a phone's picture preview.
    private static func lakePicture() -> Data? {
        let size = NSSize(width: 240, height: 180)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.16, green: 0.42, blue: 0.62, alpha: 1),
                                NSColor(red: 0.45, green: 0.72, blue: 0.86, alpha: 1),
                                NSColor(red: 0.98, green: 0.80, blue: 0.58, alpha: 1)])?
                .draw(in: rect, angle: 90)
            NSColor(red: 0.18, green: 0.32, blue: 0.24, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: rect.height * 0.42, width: rect.width, height: 6)).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
