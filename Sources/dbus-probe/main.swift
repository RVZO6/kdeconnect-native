import DBusKit
import Foundation
import KDEConnectKit

// Development tool: prints the D-Bus API of the running kdeconnectd.
//   dbus-probe introspect [path]
//   dbus-probe call <path> <interface> <member> [args...]
//   dbus-probe watch <seconds> <path> <interface> <member> [args...]
// "watch" makes the call, then prints the daemon's signals for some seconds.
// An argument is a string, or typed with a prefix: i:5, x:5, t:5, b:true,
// and "av:" for an empty array of variants. A typed argument with a value
// that does not fit its type stops the tool, so that no call goes out with
// a wrong value.

func argument(_ text: String) -> DBusValue {
    // Keep the empty value of "av:".
    let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 else { return .string(text) }
    let value: DBusValue?
    switch parts[0] {
    case "i": value = Int32(parts[1]).map { .int32($0) }
    case "x": value = Int64(parts[1]).map { .int64($0) }
    case "t": value = UInt64(parts[1]).map { .uint64($0) }
    case "b": value = ["true": true, "false": false][parts[1]].map { .bool($0) }
    case "av": value = parts[1].isEmpty ? .array(element: "v", []) : nil
    default: return .string(text)
    }
    guard let value else {
        FileHandle.standardError.write("Invalid \(parts[0]) argument: \(parts[1])\n".data(using: .utf8)!)
        exit(2)
    }
    return value
}

let args = Array(CommandLine.arguments.dropFirst())
let address = DaemonLocator().currentBusAddress() ?? {
    FileHandle.standardError.write("No private bus address found\n".data(using: .utf8)!)
    exit(1)
}()
let connection = try await DBusConnection.connect(address: address)
let service = "org.kde.kdeconnect"

switch args.first {
case "call" where args.count >= 4:
    let reply = try await connection.call(destination: service, path: args[1], interface: args[2], member: args[3],
                                          args.dropFirst(4).map(argument))
    for value in reply { print(value) }
case "watch" where args.count >= 5:
    connection.setSignalHandler { message in
        print("signal \(message.interface ?? "") \(message.member ?? "") \(message.path ?? "")")
        for value in message.body { print("  \(value)") }
    }
    try await connection.addMatch("type='signal',sender='\(service)'")
    let reply = try await connection.call(destination: service, path: args[2], interface: args[3], member: args[4],
                                          args.dropFirst(5).map(argument))
    for value in reply { print(value) }
    try await Task.sleep(for: .seconds(Double(args[1]) ?? 5))
default:
    let path = args.dropFirst().first ?? "/modules/kdeconnect"
    let reply = try await connection.call(destination: service, path: path,
                                          interface: "org.freedesktop.DBus.Introspectable", member: "Introspect")
    print(reply.first?.stringValue ?? "")
}
connection.close()
