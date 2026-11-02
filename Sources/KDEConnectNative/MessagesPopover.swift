import AppKit
import KDEConnectKit
import SwiftUI

/// The Messages pop-up of a phone: the conversations, and one page at a
/// time that slides in over them, as in Messages on iPhone.
struct MessagesPopover: View {
    @Environment(KDEConnectStore.self) private var store
    let deviceId: String

    static let size = CGSize(width: 380, height: 560)
    /// The push and pop between the list and a page. No bounce: the list's
    /// mask must follow the page's edge exactly.
    static let push = Animation.spring(duration: 0.3, bounce: 0)

    var body: some View {
        let inbox = store.inbox(for: deviceId)
        let contacts = store.contacts(for: deviceId)
        let page = inbox.page
        let isList = page == .list
        ZStack {
            ConversationList(inbox: inbox, contacts: contacts)
                // The list moves a little to the left and dims, as the page
                // comes in over it.
                .opacity(isList ? 1 : 0.5)
                .offset(x: isList ? 0 : -Self.size.width * 0.3)
                // The pop-up is see-through, so the list shows only to the
                // left of the page's edge; the two never overlap.
                .mask(alignment: .leading) {
                    Rectangle().frame(width: isList ? Self.size.width : 0)
                }
                .allowsHitTesting(isList)
                .accessibilityHidden(!isList)
            if !isList {
                // One view for every page, so that a new message turns into
                // its conversation in place instead of sliding again.
                MessagesPage(inbox: inbox, contacts: contacts, page: page)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .animation(Self.push, value: page)
        .task {
            inbox.refresh()
            await contacts.load()
        }
    }
}

private struct MessagesPage: View {
    let inbox: MessageInbox
    let contacts: ContactBook
    let page: MessageInbox.Page

    var body: some View {
        if page == .newMessage {
            NewMessageView(inbox: inbox, contacts: contacts)
        } else {
            ConversationView(inbox: inbox, contacts: contacts, page: page)
        }
    }
}

// MARK: List

private struct ConversationList: View {
    let inbox: MessageInbox
    let contacts: ContactBook
    @State private var search = ""
    /// Off until the list first has rows, so that the first fill does not
    /// animate as a reorder.
    @State private var animatesOrder = false

    var body: some View {
        let rows = filtered
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.threadID) { message in
                    ConversationRow(message: message, contacts: contacts) {
                        Task { await inbox.show(message.threadID) }
                    }
                    // Start to load when the pointer comes near, so that a
                    // click opens the conversation at once.
                    .onHover { inside in
                        if inside { inbox.open(message.threadID) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .overlay {
            if rows.isEmpty { emptyState }
        }
        .safeAreaBar(edge: .top) { header }
        // A conversation with a new message moves to the top.
        .animation(animatesOrder ? .snappy(duration: 0.25) : nil, value: rows.map(\.threadID))
        .onAppear { animatesOrder = !inbox.conversations.isEmpty }
        .onChange(of: inbox.conversations.isEmpty) { _, empty in animatesOrder = !empty }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Messages")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button {
                    inbox.page = .newMessage
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .focusEffectDisabled()
                .keyboardShortcut("n")
                .help("New Message")
            }
            SearchField(text: $search)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        if inbox.isLoadingConversations {
            ProgressView().controlSize(.small)
        } else {
            Text(search.isEmpty ? "No Messages" : "No Results")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var filtered: [SMSMessage] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return inbox.conversations }
        return inbox.conversations.filter { message in
            ConversationTitle.text(for: message.addresses, contacts: contacts).localizedStandardContains(query)
                || message.addresses.contains { $0.localizedStandardContains(query) }
                || message.body.localizedStandardContains(query)
        }
    }
}

private struct ConversationRow: View {
    let message: SMSMessage
    let contacts: ContactBook
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ContactAvatar(addresses: message.addresses, contacts: contacts, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ConversationTitle.text(for: message.addresses, contacts: contacts))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(MessageDate.listLabel(message.date))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(MessagePreview.text(message))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// A rounded highlight under the pointer, and a darker one while pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowHighlight(configuration: configuration)
    }

    private struct RowHighlight: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
                }
                .onHover { inside in withAnimation(.snappy(duration: 0.12)) { hovering = inside } }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .transition(.scale(0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .animation(.snappy(duration: 0.18), value: text.isEmpty)
    }
}

// MARK: New message

/// Picks the recipient of a new message: a contact, or a typed number. A
/// recipient with a conversation opens that conversation.
private struct NewMessageView: View {
    let inbox: MessageInbox
    let contacts: ContactBook
    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Suggestion: Identifiable {
        let name: String?
        let number: String
        var id: String { (name ?? "") + "|" + number }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("To:").foregroundStyle(.secondary)
                TextField("Name or number", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16)
            .frame(height: 38)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        Button { choose(suggestion.number) } label: { row(suggestion) }
                            .buttonStyle(RowButtonStyle())
                    }
                }
                .padding(8)
            }
        }
        .safeAreaBar(edge: .top) {
            PageHeader(back: { inbox.page = .list }) {
                Text("New Message").font(.system(size: 13, weight: .semibold))
            }
        }
        .onAppear { focused = true }
        .onExitCommand { inbox.page = .list }
    }

    private func row(_ suggestion: Suggestion) -> some View {
        HStack(spacing: 10) {
            ContactAvatar(addresses: [suggestion.number], contacts: contacts, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.name ?? suggestion.number)
                    .font(.system(size: 13, weight: .medium))
                if suggestion.name != nil {
                    Text(suggestion.number).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    /// People from recent conversations, then contacts that match the text.
    private var suggestions: [Suggestion] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let digits = query.filter(\.isNumber)
        var seen: Set<String> = []
        var result: [Suggestion] = []
        func add(_ name: String?, _ number: String) {
            guard seen.insert(PhoneNumber.canonical(number)).inserted else { return }
            result.append(Suggestion(name: name, number: number))
        }
        for message in inbox.conversations where message.addresses.count == 1 {
            let number = message.addresses[0]
            let name = contacts.contact(for: number)?.name
            if query.isEmpty || name?.localizedStandardContains(query) == true
                || (digits.count >= 2 && number.filter(\.isNumber).contains(digits)) {
                add(name, number)
            }
        }
        if !query.isEmpty {
            for contact in contacts.contacts {
                let byName = contact.name.localizedStandardContains(query)
                for number in contact.numbers
                where byName || (digits.count >= 2 && number.filter(\.isNumber).contains(digits)) {
                    add(contact.name, number)
                }
            }
        }
        return Array(result.prefix(30))
    }

    private func submit() {
        let typed = query.trimmingCharacters(in: .whitespaces)
        if typed.filter(\.isNumber).count >= 3, !typed.contains(where: \.isLetter) {
            choose(typed)
        } else if let first = suggestions.first {
            choose(first.number)
        }
    }

    private func choose(_ number: String) {
        if let existing = inbox.conversations.first(where: {
            $0.addresses.count == 1 && PhoneNumber.matches($0.addresses[0], number)
        }) {
            Task { await inbox.show(existing.threadID) }
        } else {
            inbox.page = .newConversation(address: number)
        }
    }
}

/// The bar at the top of a page: a back button, and a title in the middle.
struct PageHeader<Title: View>: View {
    let back: () -> Void
    @ViewBuilder let title: Title

    var body: some View {
        ZStack {
            title
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 44)
            HStack {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.left")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .focusEffectDisabled()
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

// MARK: Contacts

/// A contact's photo, or initials on grey, as in Messages. A group shows
/// two of its people.
struct ContactAvatar: View {
    let addresses: [String]
    let contacts: ContactBook
    var size: CGFloat = 40

    var body: some View {
        Group {
            if addresses.count > 1 {
                ZStack {
                    single(addresses[1], size: size * 0.66)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    single(addresses[0], size: size * 0.66)
                        .overlay(Circle().stroke(.background, lineWidth: 1.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            } else {
                single(addresses.first ?? "", size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func single(_ address: String, size: CGFloat) -> some View {
        let contact = contacts.contact(for: address)
        return ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 0.66, green: 0.68, blue: 0.73),
                                                  Color(red: 0.53, green: 0.55, blue: 0.60)],
                                         startPoint: .top, endPoint: .bottom))
            if let contact, let data = contact.photo,
               let photo = ImageCache.avatars.image(for: "\(contacts.deviceId)|\(contact.id)", data: data) {
                Image(nsImage: photo).resizable().scaledToFill()
            } else if let contact, let initials = Self.initials(contact.name) {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.white)
                    .offset(y: size * 0.04)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    static func initials(_ name: String) -> String? {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return letters.isEmpty ? nil : String(letters).uppercased()
    }
}

enum ConversationTitle {
    /// "Alex", "Alex & Sam", "Alex, Sam & Jordan" or "Alex, Sam & 2 more".
    /// A group uses first names, as Messages does.
    @MainActor
    static func text(for addresses: [String], contacts: ContactBook) -> String {
        guard addresses.count > 1 else { return addresses.first.map { contacts.name(for: $0) } ?? "Unknown" }
        let names = addresses.map { address in
            contacts.contact(for: address).map { firstName($0.name) } ?? address
        }
        return join(names)
    }

    static func join(_ names: [String]) -> String {
        switch names.count {
        case 0: "Unknown"
        case 1: names[0]
        case 2: "\(names[0]) & \(names[1])"
        case 3: "\(names[0]), \(names[1]) & \(names[2])"
        default: "\(names[0]), \(names[1]) & \(names.count - 2) more"
        }
    }

    static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

enum MessagePreview {
    /// The text, or the kind of attachment of a message without text.
    static func text(_ message: SMSMessage) -> String {
        if !message.body.isEmpty { return message.body.replacingOccurrences(of: "\n", with: " ") }
        return message.attachments.first.map { kind($0.mimeType) } ?? ""
    }

    static func kind(_ mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "Image" }
        if mimeType.hasPrefix("video/") { return "Video" }
        if mimeType.hasPrefix("audio/") { return "Audio" }
        if mimeType.contains("vcard") { return "Contact Card" }
        return "Attachment"
    }
}

enum MessageDate {
    /// The time today, "Yesterday", a weekday in the last week, or the date.
    static func listLabel(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        switch daysAgo(date, now: now, calendar: calendar) {
        case 0: date.formatted(date: .omitted, time: .shortened)
        case 1: "Yesterday"
        case 2..<7: date.formatted(.dateTime.weekday(.wide))
        default: date.formatted(date: .numeric, time: .omitted)
        }
    }

    /// The day and the time above a group of messages: "Today" and "9:41 AM".
    static func header(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> (day: String, time: String) {
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        switch daysAgo(date, now: now, calendar: calendar) {
        case 0: day = "Today"
        case 1: day = "Yesterday"
        case 2..<7: day = date.formatted(.dateTime.weekday(.wide))
        default:
            day = calendar.isDate(date, equalTo: now, toGranularity: .year)
                ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                : date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return (day, time)
    }

    /// Calendar days from `date` to `now`; negative for a date in the future.
    static func daysAgo(_ date: Date, now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }
}
