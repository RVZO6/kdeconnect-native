import Contacts
import Foundation
import Observation

/// Names and photos for the phone numbers of one phone: first the contacts
/// that the phone synced to this Mac (as the stock SMS app reads them), then
/// the Mac's own Contacts, if the user allows access.
@MainActor
@Observable
public final class ContactBook {
    public struct Contact: Identifiable, Equatable, Sendable {
        public let id: String
        public var name: String
        public var numbers: [String]
        /// A small JPEG or PNG.
        public var photo: Data?

        public init(id: String, name: String, numbers: [String], photo: Data? = nil) {
            self.id = id
            self.name = name
            self.numbers = numbers
            self.photo = photo
        }
    }

    public private(set) var contacts: [Contact] = []
    /// Changes each time the contacts change. Every lookup reads it, so that
    /// a view that found no contact also updates when contacts load.
    private var revision = 0
    /// Contact indices by the last digits of each number.
    @ObservationIgnored private var index: [String: [Int]] = [:]
    @ObservationIgnored private var cache: [String: Int?] = [:]
    public let deviceId: String
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var isDemo = false

    public init(deviceId: String) {
        self.deviceId = deviceId
    }

    /// Asks for access to Contacts if the user did not decide yet. Ask
    /// before the Messages pop-up opens: the system prompt closes it.
    public func requestAccess() async {
        guard !isDemo, CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }
        _ = try? await CNContactStore().requestAccess(for: .contacts)
    }

    /// Reads the contacts again, for example each time the Messages pop-up
    /// opens: the phone can sync more, and the user can allow access later.
    /// Views update only when something changed.
    public func load() async {
        guard !isDemo, !isLoading else { return }
        isLoading = true
        let deviceId = deviceId
        let found = await Task.detached {
            Self.phoneContacts(deviceId: deviceId) + Self.macContacts()
        }.value
        set(found)
        isLoading = false
    }

    public func contact(for address: String) -> Contact? {
        _ = revision
        if let hit = cache[address] { return hit.map { contacts[$0] } }
        let canonical = PhoneNumber.canonical(address)
        let match = index[Self.key(canonical)]?.first { i in
            contacts[i].numbers.contains { PhoneNumber.matches($0, address) }
        }
        cache[address] = .some(match)
        return match.map { contacts[$0] }
    }

    /// The contact's name, or the address as the phone sent it.
    public func name(for address: String) -> String {
        contact(for: address)?.name ?? address
    }

    /// Debug aid: sample contacts, and no access to the real ones.
    public func showDemo(_ demo: [Contact]) {
        isDemo = true
        set(demo)
    }

    private func set(_ found: [Contact]) {
        // Phone contacts come first, so they win over the Mac's.
        var seen: Set<String> = []
        let unique = found.filter { seen.insert($0.id).inserted }
        guard unique != contacts else { return }
        contacts = unique
        revision += 1
        index = [:]
        cache = [:]
        for (i, contact) in contacts.enumerated() {
            for key in Set(contact.numbers.map { Self.key(PhoneNumber.canonical($0)) }) {
                index[key, default: []].append(i)
            }
        }
    }

    /// Numbers that match have the same last seven digits; other addresses
    /// match only as a whole.
    private static func key(_ canonical: String) -> String {
        canonical.allSatisfy(\.isNumber) ? String(canonical.suffix(7)) : canonical
    }

    // MARK: Sources

    /// The vCards that the contacts plugin saves for the device.
    nonisolated static func phoneContacts(deviceId: String) -> [Contact] {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return [] }
        let folder = support.appendingPathComponent("kpeoplevcard/kdeconnect-\(deviceId)")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "vcf" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parseVCard(text, id: "phone:" + url.lastPathComponent)
        }
    }

    nonisolated static func macContacts() -> [Contact] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        var result: [Contact] = []
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            guard !contact.phoneNumbers.isEmpty else { return }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            guard !name.isEmpty else { return }
            result.append(Contact(id: contact.identifier, name: name,
                                  numbers: contact.phoneNumbers.map(\.value.stringValue),
                                  photo: contact.thumbnailImageData))
        }
        return result
    }

    /// Reads the name, numbers and photo of a vCard 2.1, 3.0 or 4.0.
    nonisolated static func parseVCard(_ text: String, id: String) -> Contact? {
        // Join folded lines first: a line that starts with a space or a tab
        // continues the line before it.
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else {
                lines.append(line)
            }
        }
        var formatted = "", structured = "", numbers: [String] = [], photo: Data?
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = String(line[line.index(after: colon)...])
            let parameters = line[..<colon].split(separator: ";").map { $0.uppercased() }
            // A property can have a group prefix, such as "item1.TEL".
            let property = parameters.first?.split(separator: ".").last.map(String.init) ?? ""
            switch property {
            case "FN": formatted = unescape(value)
            case "N": structured = value
            case "TEL":
                let number = value.hasPrefix("tel:") ? String(value.dropFirst(4)) : value
                if !number.isEmpty { numbers.append(number) }
            case "PHOTO":
                if let comma = value.range(of: "base64,") {
                    photo = Data(base64Encoded: String(value[comma.upperBound...]))
                } else if parameters.contains(where: { $0 == "ENCODING=B" || $0 == "ENCODING=BASE64" || $0 == "BASE64" }) {
                    photo = Data(base64Encoded: value)
                }
            default: break
            }
        }
        // "Family;Given;Middle;Prefix;Suffix" when there is no FN.
        let parts = structured.split(separator: ";", omittingEmptySubsequences: false).map { unescape(String($0)) }
        let fallback = [parts.count > 1 ? parts[1] : "", parts.first ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let name = formatted.isEmpty ? fallback : formatted
        guard !name.isEmpty, !numbers.isEmpty else { return nil }
        return Contact(id: id, name: name, numbers: numbers, photo: photo)
    }

    private nonisolated static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
