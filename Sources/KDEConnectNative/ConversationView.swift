import AppKit
import KDEConnectKit
import SwiftUI

/// One conversation: bubbles that scroll from the bottom, and a text field
/// under them. For a new conversation, only the messages sent from here.
struct ConversationView: View {
    let inbox: MessageInbox
    let contacts: ContactBook
    let page: MessageInbox.Page
    @FocusState private var composing: Bool
    @State private var scroll = ScrollPosition()
    /// The visible height of the transcript, without the header. Start
    /// near the real value, so that the first frame does not change.
    @State private var viewport: CGFloat = MessagesPopover.size.height - 120
    /// True while all bubbles fit in the view, so that there is no scrolling.
    @State private var contentFits = true

    private var threadID: Int64? {
        if case .conversation(let id) = page { id } else { nil }
    }

    private var newAddress: String? {
        if case .newConversation(let address) = page { address } else { nil }
    }

    private var addresses: [String] {
        if let threadID, let newest = inbox.conversations.first(where: { $0.threadID == threadID }) {
            return newest.addresses
        }
        return newAddress.map { [$0] } ?? []
    }

    var body: some View {
        let isGroup = addresses.count > 1
        let transcript = threadID.flatMap { inbox.transcripts[$0] }
        let pending = inbox.pending.filter { message in
            if let threadID { return message.threadID == threadID }
            return message.threadID == nil && message.address == newAddress
        }
        let rows = BubbleLayout.rows(messages: transcript?.messages ?? [], pending: pending, isGroup: isGroup)
        // The text field is below the scroll view, not in a bar over it. A
        // bar's inset arrives one frame late, which makes the last bubble jump.
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    if let threadID, let transcript, !transcript.reachedStart {
                        OlderMessagesRow(isLoading: transcript.isLoading, isPaused: transcript.olderPaused,
                                         showsSpinner: transcript.isLoadingOlder && !contentFits) {
                            inbox.loadOlder(threadID)
                        }
                    }
                    ForEach(rows) { row in
                        BubbleRowView(row: row, isGroup: isGroup,
                                      inbox: inbox, contacts: contacts, page: page)
                            .transition(row.isOutgoing ? BubbleRowView.sent : BubbleRowView.received)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                // A short conversation fills the height, with its bubbles at
                // the bottom. Else the top edge effect reaches down to them.
                .frame(minHeight: viewport, alignment: .bottom)
            }
            .onScrollGeometryChange(for: TranscriptGeometry.self) { geometry in
                TranscriptGeometry(
                    viewport: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom,
                    content: geometry.contentSize.height)
            } action: { _, geometry in
                viewport = max(0, geometry.viewport)
                contentFits = geometry.content <= viewport + 1
            }
            .scrollPosition($scroll)
            .defaultScrollAnchor(.bottom)
            .safeAreaBar(edge: .top) { header }
            ComposeBar(text: draft, focused: $composing, send: send)
        }
        // Only a new last message animates; the first page and older pages
        // appear at once.
        .animation(.spring(duration: 0.35, bounce: 0.28), value: rows.last?.id)
        // A sent bubble brightens when the phone confirms it.
        .animation(.easeOut(duration: 0.25), value: rows.map(\.status))
        .onAppear {
            if let threadID { inbox.open(threadID) }
            composing = true
        }
        .onChange(of: threadID) { _, id in
            if let id { inbox.open(id) }
        }
        .onExitCommand { inbox.page = .list }
    }

    private var header: some View {
        PageHeader(back: { inbox.page = .list }) {
            VStack(spacing: 3) {
                ContactAvatar(addresses: addresses, contacts: contacts, size: 34)
                Text(ConversationTitle.text(for: addresses, contacts: contacts))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
        }
    }

    private var draft: Binding<String> {
        Binding(get: { inbox.drafts[page] ?? "" }, set: { inbox.drafts[page] = $0.isEmpty ? nil : $0 })
    }

    private func send() {
        guard let text = inbox.drafts[page], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inbox.send(text, on: page)
        inbox.drafts[page] = nil
        withAnimation(.snappy(duration: 0.3)) { scroll.scrollTo(edge: .bottom) }
    }
}

private struct TranscriptGeometry: Equatable {
    var viewport: CGFloat
    var content: CGFloat
}

// MARK: Layout

/// One bubble, with what the layout must know about the bubbles near it.
struct BubbleRow: Identifiable, Equatable {
    enum Status: Equatable {
        case none
        case sending
        /// The ID of a pending message that this Mac can send again, or nil
        /// when the phone reported the failure.
        case failed(UUID?)
        /// The phone did not report the pending message back in time.
        case unconfirmed(UUID)
    }

    let id: String
    let body: String
    let attachments: [SMSAttachment]
    let isOutgoing: Bool
    /// The sender of an incoming message in a group.
    let sender: String?
    let date: Date
    var status = Status.none
    /// The day and time show above this bubble.
    var showsTime = false
    /// The first bubble in a run from one sender: more space above it, and
    /// the sender's name in a group.
    var startsRun = true
    /// The last bubble in a run: it has the tail.
    var endsRun = true
}

enum BubbleLayout {
    /// A time label after a gap of more than an hour, as in Messages.
    static let timeGap: TimeInterval = 3600

    static func rows(messages: [SMSMessage], pending: [MessageInbox.PendingMessage], isGroup: Bool) -> [BubbleRow] {
        var rows = messages.map { message in
            BubbleRow(id: message.localID?.uuidString ?? "m\(message.uID)", body: message.body,
                      attachments: message.attachments, isOutgoing: !message.isIncoming,
                      sender: isGroup && message.isIncoming ? message.addresses.first : nil, date: message.date,
                      status: message.box == .failed ? .failed(nil) : .none)
        }
        rows += pending.map { message in
            BubbleRow(id: message.id.uuidString, body: message.body, attachments: [], isOutgoing: true, sender: nil,
                      date: message.date,
                      status: message.failed ? .failed(message.id)
                          : message.unconfirmed ? .unconfirmed(message.id) : .sending)
        }
        // Pending messages are the newest, but the phone's clock can be ahead.
        rows = rows.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        for index in rows.indices {
            let previous = index > 0 ? rows[index - 1] : nil
            rows[index].showsTime = previous.map { rows[index].date.timeIntervalSince($0.date) > timeGap } ?? true
            let continues = previous.map {
                !rows[index].showsTime && $0.isOutgoing == rows[index].isOutgoing && $0.sender == rows[index].sender
            } ?? false
            rows[index].startsRun = !continues
            if index > 0 { rows[index - 1].endsRun = !continues }
        }
        return rows
    }
}

// MARK: Bubbles

private struct BubbleRowView: View {
    let row: BubbleRow
    let isGroup: Bool
    let inbox: MessageInbox
    let contacts: ContactBook
    let page: MessageInbox.Page

    /// A sent bubble rises out of the text field.
    static let sent = AnyTransition.asymmetric(
        insertion: .offset(y: 28).combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)).combined(with: .opacity),
        removal: .opacity)
    /// A received bubble grows out of its tail.
    static let received = AnyTransition.asymmetric(
        insertion: .scale(scale: 0.75, anchor: .bottomLeading).combined(with: .opacity),
        removal: .opacity)

    private static let avatarSize: CGFloat = 26

    var body: some View {
        VStack(spacing: 2) {
            if row.showsTime {
                let label = MessageDate.header(row.date)
                Text("\(Text(label.day).fontWeight(.semibold)) \(label.time)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }
            if let sender = row.sender, row.startsRun {
                Text(contacts.contact(for: sender).map { ConversationTitle.firstName($0.name) } ?? sender)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.avatarSize + 6 + 12)
                    .padding(.top, row.showsTime ? 0 : 6)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if isGroup, !row.isOutgoing {
                    if row.endsRun, let sender = row.sender {
                        ContactAvatar(addresses: [sender], contacts: contacts, size: Self.avatarSize)
                    } else {
                        Color.clear.frame(width: Self.avatarSize, height: 1)
                    }
                }
                if row.isOutgoing { Spacer(minLength: 56) }
                if let problem {
                    Button(action: retry) {
                        Image(systemName: problem.symbol)
                            .font(.system(size: 17))
                            .foregroundStyle(.white, problem.color)
                    }
                    .buttonStyle(.plain)
                    .help("Try Again")
                    .padding(.bottom, 6)
                }
                MessageBubble(row: row, inbox: inbox)
                    // Dim until the phone reports the message back.
                    .opacity(row.status == .sending ? 0.55 : 1)
                    .contextMenu { menu }
                if !row.isOutgoing { Spacer(minLength: 56) }
            }
            .padding(.top, row.startsRun && !row.showsTime && row.sender == nil ? 8 : 0)
            if let problem {
                Text(problem.caption)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(problem.captionStyle)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
                    .padding(.top, 1)
                    .transition(.opacity)
            }
        }
    }

    /// A failed or unconfirmed message has a symbol and a caption. A
    /// caption while sending would show and hide within a second, and move
    /// every bubble above it.
    private var problem: (symbol: String, color: Color, caption: String, captionStyle: AnyShapeStyle)? {
        switch row.status {
        case .failed: ("exclamationmark.circle.fill", .red, "Not Delivered", AnyShapeStyle(.red))
        case .unconfirmed: ("questionmark.circle.fill", .orange, "Not Confirmed", AnyShapeStyle(.secondary))
        case .none, .sending: nil
        }
    }

    /// The pending copy, which can be sent again or deleted.
    private var pendingID: UUID? {
        switch row.status {
        case .failed(let id): id
        case .unconfirmed(let id): id
        case .none, .sending: nil
        }
    }

    /// A message that the phone reported as failed has no pending copy;
    /// send its text again.
    private func retry() {
        if let pendingID { inbox.retry(pendingID) } else { inbox.send(row.body, on: page) }
    }

    @ViewBuilder
    private var menu: some View {
        if !row.body.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.body, forType: .string)
            }
        }
        if problem != nil {
            Button("Try Again", systemImage: "arrow.clockwise", action: retry)
            if let pendingID {
                Button("Delete", systemImage: "trash", role: .destructive) { inbox.discard(pendingID) }
            }
        }
    }
}

/// The top row of a conversation that may have older messages. They load
/// when the row scrolls into view, and again when a load ends while the row
/// is still in view, as in a short conversation. The spinner shows only
/// after the user scrolled up to it, and only for a slow load, so that it
/// does not flash.
private struct OlderMessagesRow: View {
    /// Any request for this conversation runs.
    let isLoading: Bool
    let isPaused: Bool
    let showsSpinner: Bool
    let load: () -> Void
    @State private var isSlow = false
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(isSlow && showsSpinner ? 1 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .onAppear {
                isVisible = true
                load()
            }
            .onDisappear { isVisible = false }
            .onChange(of: isLoading || isPaused) { _, busy in
                if !busy, isVisible { load() }
            }
            .task(id: showsSpinner) {
                isSlow = false
                guard showsSpinner else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) { isSlow = true }
            }
    }
}

private struct MessageBubble: View {
    let row: BubbleRow
    let inbox: MessageInbox

    /// The tail sticks out this far on its side.
    nonisolated static let tailInset: CGFloat = 4

    var body: some View {
        VStack(alignment: row.isOutgoing ? .trailing : .leading, spacing: 3) {
            ForEach(row.attachments) { attachment in
                AttachmentView(attachment: attachment, inbox: inbox)
                    .padding(row.isOutgoing ? .trailing : .leading, Self.tailInset)
            }
            if !row.body.isEmpty {
                if Emoji.isLarge(row.body) {
                    // A few emoji alone show large, without a bubble.
                    Text(row.body)
                        .font(.system(size: 40))
                        .padding(.horizontal, Self.tailInset)
                } else {
                    text
                }
            }
        }
    }

    private var text: some View {
        Text(Links.attributed(row.body))
            .font(.system(size: 13))
            .foregroundStyle(row.isOutgoing ? Color.white : Color.primary)
            .tint(row.isOutgoing ? .white : .blue)
            .padding(.leading, 11 + (row.isOutgoing ? 0 : Self.tailInset))
            .padding(.trailing, 11 + (row.isOutgoing ? Self.tailInset : 0))
            .padding(.vertical, 6)
            .frame(minWidth: 44)
            .background {
                BubbleShape(tail: row.endsRun)
                    .fill(row.isOutgoing ? Color.outgoingBubble : Color.incomingBubble)
                    .scaleEffect(x: row.isOutgoing ? -1 : 1)
            }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A rounded bubble. With a tail, its bottom-left corner sweeps out into a
/// point, as in Messages; mirror it for a sent bubble.
struct BubbleShape: Shape {
    var tail: Bool

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(17, h / 2)
        // The body starts here; the tail's point is at the left edge.
        let x0 = MessageBubble.tailInset
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: r), radius: r)
        p.addLine(to: CGPoint(x: w, y: h - r))
        p.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: w - r, y: h), radius: r)
        if tail {
            p.addLine(to: CGPoint(x: x0 + 21, y: h))
            p.addCurve(to: CGPoint(x: x0 + 7, y: h - 4),
                       control1: CGPoint(x: x0 + 16, y: h), control2: CGPoint(x: x0 + 12, y: h))
            p.addCurve(to: CGPoint(x: 0, y: h),
                       control1: CGPoint(x: x0 + 4, y: h - 1), control2: CGPoint(x: x0, y: h + 0.5))
            p.addCurve(to: CGPoint(x: x0, y: h - 11),
                       control1: CGPoint(x: 0, y: h), control2: CGPoint(x: x0, y: h - 1))
        } else {
            p.addLine(to: CGPoint(x: x0 + r, y: h))
            p.addArc(tangent1End: CGPoint(x: x0, y: h), tangent2End: CGPoint(x: x0, y: h - r), radius: r)
        }
        p.addLine(to: CGPoint(x: x0, y: r))
        p.addArc(tangent1End: CGPoint(x: x0, y: 0), tangent2End: CGPoint(x: x0 + r, y: 0), radius: r)
        p.closeSubpath()
        return p
    }
}

/// A picture preview, or a chip for another kind of file. A click asks the
/// phone for the file and opens it.
private struct AttachmentView: View {
    let attachment: SMSAttachment
    let inbox: MessageInbox

    var body: some View {
        Button { inbox.openAttachment(attachment) } label: {
            if let data = attachment.thumbnail,
               let image = ImageCache.thumbnails.image(for: "\(inbox.deviceId)|\(attachment.id)", data: data) {
                let size = Self.fitted(image.size)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08)))
                    .overlay {
                        if attachment.mimeType.hasPrefix("video/") {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white, .black.opacity(0.35))
                        }
                    }
            } else {
                Label(MessagePreview.kind(attachment.mimeType), systemImage: "paperclip")
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.incomingBubble, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .overlay {
            if inbox.downloading.contains(attachment.uniqueIdentifier) {
                ProgressView().controlSize(.small)
            }
        }
        .help("Open")
    }

    /// At most 210 points wide and 240 high, and at least 60 on each side.
    static func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 210, height: 160) }
        let scale = min(210 / size.width, 240 / size.height)
        return CGSize(width: max(60, size.width * scale), height: max(60, size.height * scale))
    }
}

/// The text field at the bottom. The send button comes out when there is
/// text. Return sends; Option-Return starts a new line.
private struct ComposeBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField("Text Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused(focused)
                .onSubmit(send)
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 7)
            if canSend {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, Color.outgoingBubble)
                }
                .buttonStyle(.plain)
                .help("Send")
                .padding(.trailing, 3)
                .padding(.bottom, 3)
                .transition(.scale(0.3, anchor: .center).combined(with: .opacity))
            }
        }
        .frame(minHeight: 32)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.opacity(0.6))
                .strokeBorder(Color.primary.opacity(0.14))
        }
        .animation(.snappy(duration: 0.2), value: canSend)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
}

// MARK: Helpers

extension Color {
    static let outgoingBubble = Color(nsColor: .systemBlue)
    /// The grey of a received bubble in Messages, in light and dark.
    static let incomingBubble = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.23, green: 0.23, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1)
    })
}

enum Emoji {
    /// One to three emoji and nothing else.
    static func isLarge(_ text: String) -> Bool {
        (1...3).contains(text.count) && text.allSatisfy { character in
            guard let first = character.unicodeScalars.first else { return false }
            return first.properties.isEmojiPresentation
                || (first.properties.isEmoji && character.unicodeScalars.count > 1)
        }
    }
}

@MainActor
enum Links {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The text, with web addresses as underlined links.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector, text.contains(".") else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let target = Range(range, in: result) else { continue }
            result[target].link = url
            result[target].underlineStyle = .single
        }
        return result
    }
}

/// Decoded images, so that a view update does not decode them again. Each
/// image keeps its data: new data under the same key, such as a changed
/// contact photo, decodes again.
@MainActor
final class ImageCache {
    static let avatars = ImageCache()
    static let thumbnails = ImageCache()

    private final class Entry {
        let data: Data
        let image: NSImage

        init(data: Data, image: NSImage) {
            self.data = data
            self.image = image
        }
    }

    private let cache = NSCache<NSString, Entry>()

    func image(for key: String, data: Data) -> NSImage? {
        if let entry = cache.object(forKey: key as NSString), entry.data == data { return entry.image }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(Entry(data: data, image: image), forKey: key as NSString)
        return image
    }
}
