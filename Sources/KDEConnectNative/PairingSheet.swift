import Darwin
import KDEConnectKit
import SwiftUI

/// Guides the user through pairing a new device.
struct PairingSheet: View {
    @Environment(KDEConnectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var addresses = LocalAddress.current()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Open KDE Connect on the other device. When both devices are on the same network, "
                         + "the device shows below.")
                        .foregroundStyle(.secondary)
                    if candidates.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(candidates) { CandidateRow(device: $0) }
                } header: {
                    HStack {
                        Text("Devices nearby")
                        Spacer()
                        Button("Search Again", systemImage: "arrow.clockwise") { store.refreshNetwork() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Search again")
                    }
                }

                Section {
                    HStack {
                        TextField("IP address of the other device", text: $address)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !addresses.isEmpty {
                        LabeledContent("Or add this Mac on the other device") {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(addresses, id: \.address) { item in
                                    Text("\(item.address)  (\(item.label))")
                                        .font(.body.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Device not found?")
                } footer: {
                    Text("Discovery does not cross VPNs such as Tailscale or separate networks. "
                         + "Add the address on one of the devices. On Android: Pair new device → ⋮ → Add devices by IP.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 520)
        .task {
            store.refreshNetwork()
            addresses = LocalAddress.current()
        }
    }

    /// Devices that are not paired yet and that can be reached now.
    private var candidates: [Device] {
        store.pairingRequests + store.availableDevices
    }

    private func add() {
        store.addCustomDevice(address)
        address = ""
        store.refreshNetwork()
    }
}

private struct CandidateRow: View {
    @Environment(KDEConnectStore.self) private var store
    let device: Device

    var body: some View {
        let id = device.id
        HStack {
            Label(device.name, systemImage: device.kind.symbol)
            Spacer()
            if device.isPairRequestedByPeer {
                Button("Reject") { store.perform("Reject pairing") { try await $0.cancelPairing(id) } }
                Button("Accept") { store.perform("Accept pairing") { try await $0.acceptPairing(id) } }
                    .buttonStyle(.borderedProminent)
            } else if device.isPairRequested {
                Text("Confirm on the device…").foregroundStyle(.secondary)
                Button("Cancel") { store.perform("Cancel pairing") { try await $0.cancelPairing(id) } }
            } else {
                Button("Pair") { store.perform("Pair") { try await $0.requestPairing(id) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// IPv4 addresses of this Mac that other devices can use.
struct LocalAddress {
    let address: String
    let label: String

    static func current() -> [LocalAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [LocalAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: entry.ifa_name)
            if ip.hasPrefix("169.254.") { continue }
            result.append(LocalAddress(address: ip, label: label(interface: name, ip: ip)))
        }
        return result
    }

    private static func label(interface: String, ip: String) -> String {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        // Tailscale uses the 100.64.0.0/10 carrier-grade NAT range.
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return "Tailscale" }
        if interface.hasPrefix("utun") { return "VPN" }
        return "local network"
    }
}

/// The alert for an incoming pairing request.
@MainActor
enum PairingPrompt {
    static func show(device: Device, store: KDEConnectStore) {
        let alert = NSAlert()
        alert.messageText = "\(device.name) wants to pair with this Mac"
        alert.informativeText = device.verificationKey.isEmpty
            ? "Accept only if you started the pairing on that device."
            : "Make sure that the device shows the same key:\n\(device.verificationKey)"
        alert.addButton(withTitle: "Accept")
        alert.addButton(withTitle: "Reject")
        NSApp.activate()
        let id = device.id
        if alert.runModal() == .alertFirstButtonReturn {
            store.perform("Accept pairing") { try await $0.acceptPairing(id) }
        } else {
            store.perform("Reject pairing") { try await $0.cancelPairing(id) }
        }
    }
}
