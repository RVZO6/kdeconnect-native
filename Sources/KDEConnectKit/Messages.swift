import AppKit
import DBusKit
import Foundation
import Observation

/// One SMS or MMS message, as the daemon's conversations interface reports it.
public struct SMSMessage: Identifiable, Equatable, Sendable {
    /// Android's message box (the TYPE column).
    public enum Box: Int32, Sendable {
        case all = 0, inbox, sent, draft, outbox, failed, queued
    }

    public var uID: Int32
    public var threadID: Int64
    public var body: String
    /// The other people in the conversation. For an incoming message in a
    /// group, the first address is the sender.
    public var addresses: [String]
    public var date: Date
    public var box: Box
    public var attachments: [SMSAttachment]
    /// Set when this message is the phone's copy of one sent from this Mac,
    /// so that the view keeps the bubble that it already shows.
    public internal(set) var localID: UUID?

    /// The daemon keeps one message for each ID in a conversation.
    public var id: Int32 { uID }
    public var isIncoming: Bool { box == .inbox }

    public init(uID: Int32, threadID: Int64, body: String, addresses: [String], date: Date, box: Box,
                attachments: [SMSAttachment] = []) {
        self.uID = uID
        self.threadID = threadID
        self.body = body
        self.addresses = addresses
        self.date = date
        self.box = box
        self.attachments = attachments
    }

    /// Reads the daemon's `(isa(s)xiixxxa(xsss))` structure, in a variant or not:
    /// event, body, addresses, date, type, read, thread, ID, SIM, attachments.
    init?(_ value: DBusValue) {
        guard case .structure(let f) = value.unwrapped, f.count >= 10, let body = f[1].stringValue,
              let addresses = f[2].arrayValue, let date = f[3].intValue, let type = f[4].intValue,
              let thread = f[6].intValue, let uID = f[7].intValue, let id = Int32(exactly: uID) else { return nil }
        self.init(uID: id, threadID: Int64(thread), body: body,
                  addresses: addresses.compactMap { address in
                      guard case .structure(let fields) = address.unwrapped else { return nil }
                      return fields.first?.stringValue
                  },
                  date: Date(timeIntervalSince1970: Double(date) / 1000),
                  box: Int32(exactly: type).flatMap(Box.init) ?? .all,
                  attachments: (f[9].arrayValue ?? []).compactMap(SMSAttachment.init))
    }
}

public struct SMSAttachment: Identifiable, Equatable, Sendable {
    public var partID: Int64
    public var mimeType: String
    /// A small preview that the phone sends along, for pictures and videos.
    public var thumbnail: Data?
    /// The file's name in the daemon's attachment cache.
    public var uniqueIdentifier: String

    public var id: String { "\(partID)-\(uniqueIdentifier)" }

    public init(partID: Int64, mimeType: String, thumbnail: Data?, uniqueIdentifier: String) {
        self.partID = partID
        self.mimeType = mimeType
        self.thumbnail = thumbnail
        self.uniqueIdentifier = uniqueIdentifier
    }

    /// Reads `(xsss)`: part ID, MIME type, base64 preview, file name.
    init?(_ value: DBusValue) {
        guard case .structure(let f) = value.unwrapped, f.count >= 4, let part = f[0].intValue,
              let type = f[1].stringValue, let name = f[3].stringValue else { return nil }
        self.init(partID: Int64(part), mimeType: type,
                  thumbnail: f[2].stringValue.flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) },
                  uniqueIdentifier: name)
    }
}

/// Phone numbers compared as KDE Connect compares them: only the digits, and
/// a number matches a longer form of itself with a country code.
public enum PhoneNumber {
    /// Digits without leading zeros. An address with letters, such as a
    /// sender name, stays as it is, in lowercase.
    public static func canonical(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isLetter) else { return trimmed.lowercased() }
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        let significant = digits.drop { $0 == "0" }
        return significant.isEmpty ? String(digits) : String(significant)
    }

    /// Short codes and names match only exactly.
    public static func matches(_ a: String, _ b: String) -> Bool {
        let x = canonical(a), y = canonical(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let (long, short) = x.count >= y.count ? (x, y) : (y, x)
        guard short.count >= 7, short.allSatisfy(\.isNumber), long.allSatisfy(\.isNumber) else { return false }
        return long.hasSuffix(short)
    }
}

/// The SMS conversations of one phone. The daemon answers most requests
/// with signals, so the calls here only ask; `handle` takes the answers.
@MainActor
@Observable
public final class MessageInbox {
    /// Where the Messages pop-up is. It stays when the pop-up closes, so that
    /// the pop-up opens again where it was, as Messages on iPhone does.
    public enum Page: Hashable, Sendable {
        case list
        case newMessage
        case conversation(Int64)
        /// A conversation that starts with this message, until the phone
        /// reports the thread that it made.
        case newConversation(address: String)
    }

    /// The loaded part of one conversation.
    public struct Transcript: Equatable, Sendable {
        /// Oldest first.
        public var messages: [SMSMessage] = []
        public var isLoading = false
        /// True while a request for older messages runs.
        public var isLoadingOlder = false
        /// A request brought nothing new, and the phone did not answer. Do
        /// not ask for older messages again by itself until new messages
        /// come; a scroll to the top still tries again.
        public var olderPaused = false
        /// True after the phone answered a request for older messages and
        /// had none. A short page is no proof: the daemon often answers with
        /// part of a page while the phone sends the rest.
        public var reachedStart = false
    }

    /// A message sent from this Mac that the phone did not report back yet.
    public struct PendingMessage: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var threadID: Int64?
        /// The recipient of a new conversation.
        public var address: String?
        public var body: String
        public var date: Date
        public var failed = false
        /// The daemon took the message, but the phone did not report it
        /// back in time. It may or may not have gone out.
        public var unconfirmed = false

        /// The phone's copy has the same text, in the same conversation.
        /// The phone's clock can differ from this Mac's, so allow some time.
        /// Any sent box counts: the daemon keeps the first report of a
        /// message, which can be from the outbox, and never updates it.
        func matches(_ message: SMSMessage) -> Bool {
            guard !message.isIncoming, message.body == body, message.date.timeIntervalSince(date) > -120 else {
                return false
            }
            if let threadID { return threadID == message.threadID }
            guard let address, message.addresses.count == 1 else { return false }
            return PhoneNumber.matches(address, message.addresses[0])
        }
    }

    public let deviceId: String
    public var page: Page = .list
    /// The newest message of each conversation, newest first.
    public private(set) var conversations: [SMSMessage] = []
    /// True while the list is empty and the phone may still answer.
    public private(set) var isLoadingConversations = false
    /// The conversations that were opened, by thread ID.
    public private(set) var transcripts: [Int64: Transcript] = [:]
    public private(set) var pending: [PendingMessage] = []
    /// Attachments on their way from the phone, by file name.
    public private(set) var downloading: Set<String> = []
    /// Text that is not sent yet, by page.
    public var drafts: [Page: String] = [:]

    nonisolated static let pageSize = 50

    @ObservationIgnored private let client: () -> KDEConnectClient?
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var incoming: [SMSMessage] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    /// Changes when the daemon's cache starts again. Requests from before
    /// then end without changing any state.
    @ObservationIgnored private var generation = 0
    /// Messages that came in for each thread since its last request.
    @ObservationIgnored private var arrivals: [Int64: (count: Int, new: Int, last: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var loadedSignals: Set<Int64> = []
    /// Threads whose newest page was requested. Later messages come as
    /// signals, so one request per connection is enough.
    @ObservationIgnored private var requested: Set<Int64> = []
    /// The messages that the current daemon reported for each open
    /// transcript. The daemon counts request offsets in its own cache, from
    /// the newest message, so the offset counts only messages that a
    /// transcript keeps: not those from before a restart, and not those
    /// that came before the conversation opened.
    @ObservationIgnored private var reportedByDaemon: [Int64: Set<Int32>] = [:]
    /// Sent messages that the daemon reported. Only the first report of a
    /// message can confirm a pending one; the same message comes again,
    /// for example in a list refresh.
    @ObservationIgnored private var reportedSent: Set<MessageKey> = []
    /// One token per attachment request, so that an old request's timeout
    /// does not end a newer request for the same file.
    @ObservationIgnored private var downloadTokens: [String: UUID] = [:]
    /// The thread that `show` waits for.
    @ObservationIgnored private var showing: Int64?
    @ObservationIgnored private var demoTranscripts: [Int64: [SMSMessage]] = [:]

    private struct MessageKey: Hashable {
        let threadID: Int64
        let uID: Int32
    }

    init(deviceId: String, isDemo: Bool, client: @escaping () -> KDEConnectClient?) {
        self.deviceId = deviceId
        self.isDemo = isDemo
        self.client = client
    }

    /// The daemon's message cache starts again empty: the daemon restarted
    /// or moved to a new bus, or the phone's plugins loaded again, for
    /// example after a reconnect. Requests start again from the newest
    /// message. With `reload`, for an open pop-up, the list and the shown
    /// conversation load at once.
    func reconnected(reload: Bool = false) {
        // Messages that wait for a batch came from the old cache. Keep them
        // for the list, then forget what they tell about paging.
        flushTask = nil
        let waiting = incoming
        incoming = []
        apply(waiting)
        generation += 1
        listTask = nil
        isLoadingConversations = false
        requested.removeAll()
        reportedByDaemon.removeAll()
        arrivals.removeAll()
        loadedSignals.removeAll()
        for thread in transcripts.keys {
            transcripts[thread]?.isLoading = false
            transcripts[thread]?.isLoadingOlder = false
            transcripts[thread]?.reachedStart = false
            transcripts[thread]?.olderPaused = false
        }
        guard reload else { return }
        refresh()
        if case .conversation(let thread) = page { open(thread) }
    }

    // MARK: Requests

    /// Reads the daemon's list, then asks the phone for the newest message
    /// of every conversation.
    public func refresh() {
        guard !isDemo, listTask == nil, let client = client() else { return }
        isLoadingConversations = conversations.isEmpty
        let id = deviceId, generation = generation
        listTask = Task {
            if let cached = try? await client.activeConversations(id), generation == self.generation { apply(cached) }
            try? await client.requestAllConversationThreads(id)
            // The phone answers with signals, if at all.
            if conversations.isEmpty { try? await Task.sleep(for: .seconds(10)) }
            guard generation == self.generation else { return }
            isLoadingConversations = false
            listTask = nil
        }
    }

    /// Loads the newest messages of a conversation. Call it early, for
    /// example when the pointer is over the conversation, so that the
    /// messages are there when it opens.
    public func open(_ threadID: Int64) {
        if transcripts[threadID] == nil {
            var transcript = Transcript()
            // If the messages are late, show at least the newest one.
            if let newest = conversations.first(where: { $0.threadID == threadID }) { transcript.messages = [newest] }
            transcripts[threadID] = transcript
        }
        guard !requested.contains(threadID), transcripts[threadID]?.isLoading == false else { return }
        requested.insert(threadID)
        request(threadID, from: 0)
    }

    /// Shows a conversation after its messages are loaded. It waits only a
    /// short time, so that the page slides in full instead of filling up
    /// after it arrives.
    public func show(_ threadID: Int64) async {
        showing = threadID
        open(threadID)
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .milliseconds(350), transcripts[threadID]?.isLoading == true {
            // The cache answers in one burst; stop when it is over.
            if let arrived = arrivals[threadID], ContinuousClock.now - arrived.last > .milliseconds(60) { break }
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard showing == threadID else { return }
        showing = nil
        page = .conversation(threadID)
    }

    /// Loads the page of messages before the oldest one that the daemon
    /// reported.
    public func loadOlder(_ threadID: Int64) {
        guard let transcript = transcripts[threadID], !transcript.reachedStart else { return }
        request(threadID, from: olderOffset(threadID))
    }

    /// The daemon offset of the next older message.
    func olderOffset(_ threadID: Int64) -> Int {
        reportedByDaemon[threadID]?.count ?? 0
    }

    private func request(_ threadID: Int64, from start: Int) {
        guard transcripts[threadID]?.isLoading == false else { return }
        transcripts[threadID]?.isLoading = true
        transcripts[threadID]?.isLoadingOlder = start > 0
        transcripts[threadID]?.olderPaused = false
        if isDemo {
            // As the daemon does, answer from the cache a moment later.
            Task {
                try? await Task.sleep(for: .milliseconds(40))
                apply(demoTranscripts[threadID] ?? [])
                transcripts[threadID]?.isLoading = false
                transcripts[threadID]?.isLoadingOlder = false
                transcripts[threadID]?.reachedStart = true
            }
            return
        }
        guard let client = client() else {
            transcripts[threadID]?.isLoading = false
            transcripts[threadID]?.isLoadingOlder = false
            if start == 0 { requested.remove(threadID) }
            return
        }
        arrivals[threadID] = nil
        loadedSignals.remove(threadID)
        let id = deviceId, size = Self.pageSize, generation = generation
        Task {
            try? await client.requestConversation(id, threadID: threadID, range: start..<(start + size))
            // The messages come as signals, from the cache at once and from
            // the phone later. There is no signal at the end of the cache.
            // conversationLoaded means that the phone answered; the messages
            // from its answer follow that signal.
            let started = ContinuousClock.now
            var answeredAt: ContinuousClock.Instant?
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                let now = ContinuousClock.now
                let arrived = arrivals[threadID]
                if (arrived?.count ?? 0) >= size { break }
                if let arrived, now - arrived.last > .milliseconds(500) { break }
                if loadedSignals.contains(threadID) { answeredAt = answeredAt ?? now }
                if let answeredAt, now - answeredAt > .milliseconds(500) { break }
                if now - started > .seconds(8) { break }
            }
            // A request to a cache that started again tells nothing.
            guard generation == self.generation else { return }
            transcripts[threadID]?.isLoading = false
            transcripts[threadID]?.isLoadingOlder = false
            // Nothing came. Load the first page again the next time the
            // conversation opens.
            if start == 0, arrivals[threadID] == nil { requested.remove(threadID) }
            guard (arrivals[threadID]?.new ?? 0) == 0 else { return }
            if start > 0, loadedSignals.contains(threadID) {
                // The phone answered, and has nothing older. Silence alone
                // is no proof: the phone can be slow.
                transcripts[threadID]?.reachedStart = true
            } else {
                // Also after the first page: a new daemon starts at offset
                // zero, and the top row must not ask it again and again.
                transcripts[threadID]?.olderPaused = true
            }
        }
    }

    /// Sends text to the conversation of `page`, or starts a conversation.
    public func send(_ text: String, on page: Page) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        var message = PendingMessage(id: UUID(), body: body, date: .now)
        switch page {
        case .conversation(let thread): message.threadID = thread
        case .newConversation(let address): message.address = address
        case .list, .newMessage: return
        }
        pending.append(message)
        deliver(message)
    }

    public func retry(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].failed = false
        pending[index].unconfirmed = false
        pending[index].date = .now
        deliver(pending[index])
    }

    public func discard(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    private func deliver(_ message: PendingMessage) {
        if isDemo {
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                demoEcho(message)
            }
            return
        }
        guard let client = client() else {
            fail(message.id)
            return
        }
        let id = deviceId
        Task {
            do {
                if let thread = message.threadID {
                    try await client.replyToConversation(id, threadID: thread, message: message.body)
                } else if let address = message.address {
                    try await client.sendMessage(id, to: [address], message: message.body)
                }
            } catch {
                fail(message.id)
                return
            }
            // The daemon does not report a lost packet. Without the phone's
            // copy after some time, say so; do not send again by itself.
            try? await Task.sleep(for: Self.confirmationTimeout)
            // A retry changes the date, and has its own timeout.
            guard let index = pending.firstIndex(where: { $0.id == message.id }),
                  pending[index].date == message.date, !pending[index].failed else { return }
            pending[index].unconfirmed = true
        }
    }

    nonisolated static let confirmationTimeout: Duration = .seconds(30)

    private func fail(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].failed = true
    }

    /// Asks the phone for an attachment, and opens it when it is here.
    public func openAttachment(_ attachment: SMSAttachment) {
        let name = attachment.uniqueIdentifier
        guard !isDemo, !downloading.contains(name), let client = client() else { return }
        let token = UUID()
        downloadTokens[name] = token
        downloading.insert(name)
        let id = deviceId
        Task {
            do {
                try await client.requestAttachment(id, partID: attachment.partID, uniqueIdentifier: name)
            } catch {
                endDownload(name, token: token)
                return
            }
            // The phone may never send it. Do not show the spinner forever.
            try? await Task.sleep(for: .seconds(45))
            endDownload(name, token: token)
        }
    }

    private func endDownload(_ name: String, token: UUID) {
        guard downloadTokens[name] == token else { return }
        downloadTokens[name] = nil
        downloading.remove(name)
    }

    // MARK: Signals

    /// Takes a signal from the daemon's conversations interface.
    func handle(_ signal: DBusMessage) {
        switch signal.member {
        case "conversationCreated", "conversationUpdated":
            guard let value = signal.body.first, let message = SMSMessage(value) else { return }
            enqueue(message)
        case "conversationRemoved":
            guard let thread = signal.body.first?.intValue else { return }
            conversations.removeAll { $0.threadID == Int64(thread) }
            transcripts[Int64(thread)] = nil
        case "conversationLoaded":
            guard let thread = signal.body.first?.intValue else { return }
            loadedSignals.insert(Int64(thread))
        case "attachmentReceived":
            guard signal.body.count >= 2, let path = signal.body[0].stringValue,
                  let name = signal.body[1].stringValue, downloadTokens.removeValue(forKey: name) != nil else { return }
            downloading.remove(name)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        default:
            break
        }
    }

    /// A request brings one signal per message. Apply them in batches, not
    /// one view update per message.
    private func enqueue(_ message: SMSMessage) {
        incoming.append(message)
        guard flushTask == nil else { return }
        let generation = generation
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(30))
            // A reset applied this batch already, and a newer batch may wait.
            guard generation == self.generation else { return }
            flushTask = nil
            let batch = incoming
            incoming = []
            apply(batch)
        }
    }

    /// Adds messages to the list and to the open transcripts. A message that
    /// the phone reports back takes the place of its pending copy.
    func apply(_ batch: [SMSMessage]) {
        guard !batch.isEmpty else { return }
        var list = conversations
        var byThread: [Int64: [SMSMessage]] = [:]
        var newByThread: [Int64: Int] = [:]
        for var message in batch {
            let firstReport = !message.isIncoming
                && reportedSent.insert(MessageKey(threadID: message.threadID, uID: message.uID)).inserted
            if firstReport, let index = pending.firstIndex(where: { $0.matches(message) }) {
                let sent = pending.remove(at: index)
                message.localID = sent.id
                if transcripts[message.threadID] == nil { transcripts[message.threadID] = Transcript() }
                if let address = sent.address { resolve(address, to: message.threadID) }
            }
            if let index = list.firstIndex(where: { $0.threadID == message.threadID }) {
                if message.date >= list[index].date { list[index] = message }
            } else {
                list.append(message)
            }
            if transcripts[message.threadID] != nil {
                byThread[message.threadID, default: []].append(message)
                if reportedByDaemon[message.threadID, default: []].insert(message.uID).inserted {
                    newByThread[message.threadID, default: 0] += 1
                }
            }
        }
        list.sort { $0.date > $1.date }
        if list != conversations { conversations = list }
        let now = ContinuousClock.now
        for (thread, new) in byThread {
            guard var transcript = transcripts[thread] else { continue }
            var byID = Dictionary(transcript.messages.map { ($0.uID, $0) }, uniquingKeysWith: { first, _ in first })
            // Keep the copy that replaced a pending message.
            for message in new where byID[message.uID]?.localID == nil { byID[message.uID] = message }
            transcript.messages = byID.values.sorted { ($0.date, $0.uID) < ($1.date, $1.uID) }
            // New messages: older ones may follow, so loading may go on.
            if newByThread[thread] != nil { transcript.olderPaused = false }
            if transcript != transcripts[thread] { transcripts[thread] = transcript }
            arrivals[thread] = ((arrivals[thread]?.count ?? 0) + new.count,
                                (arrivals[thread]?.new ?? 0) + (newByThread[thread] ?? 0), now)
        }
    }

    /// A new conversation now has its thread. Its other pending messages
    /// belong to that thread, and its page becomes the thread's page.
    private func resolve(_ address: String, to threadID: Int64) {
        for index in pending.indices
        where pending[index].threadID == nil && pending[index].address.map({ PhoneNumber.matches($0, address) }) == true {
            pending[index].threadID = threadID
        }
        if case .newConversation(let shown) = page, PhoneNumber.matches(shown, address) {
            drafts[.conversation(threadID)] = drafts.removeValue(forKey: page)
            page = .conversation(threadID)
        }
    }

    // MARK: Demo

    func showDemo(_ messages: [SMSMessage]) {
        demoTranscripts = Dictionary(grouping: messages, by: \.threadID)
        apply(demoTranscripts.values.compactMap { $0.max { $0.date < $1.date } })
    }

    /// Debug aid, demo mode only: a message arrives from the phone.
    public func addDemoMessage(threadID: Int64, body: String) {
        guard isDemo, let newest = conversations.first(where: { $0.threadID == threadID }) else { return }
        let message = SMSMessage(uID: nextDemoID(), threadID: threadID, body: body, addresses: newest.addresses,
                                 date: .now, box: .inbox)
        demoTranscripts[threadID, default: []].append(message)
        apply([message])
    }

    private func demoEcho(_ sent: PendingMessage) {
        let thread = sent.threadID ?? (conversations.map(\.threadID).max() ?? 0) + 1
        let addresses = sent.address.map { [$0] } ?? conversations.first { $0.threadID == thread }?.addresses ?? []
        let message = SMSMessage(uID: nextDemoID(), threadID: thread, body: sent.body, addresses: addresses,
                                 date: .now, box: .sent)
        demoTranscripts[thread, default: []].append(message)
        apply([message])
    }

    private func nextDemoID() -> Int32 {
        (demoTranscripts.values.joined().map(\.uID).max() ?? 0) + 1
    }
}
