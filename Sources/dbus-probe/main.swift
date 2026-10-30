import DBusKit
import Foundation
import KDEConnectKit

// Development tool: prints the D-Bus API of the running kdeconnectd.
//   dbus-probe introspect [path]
//   dbus-probe call <path> <interface> <member> [args...]
//   dbus-probe watch <seconds> <path> <interface> <member> [args...]
// "watch" makes the call, then prints the daemon's signals for some seconds.
// An argument is a string, or typed with a prefix: i:5, x:5, t:5, b:true,
// and "av:" for an empty array of variants.

func argument(_ text: String) -> DBusValue {
    let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return .string(text) }
    switch parts[0] {
    case "i": if let v = Int32(parts[1]) { return .int32(v) }
    case "x": if let v = Int64(parts[1]) { return .int64(v) }
    case "t": if let v = UInt64(parts[1]) { return .uint64(v) }
    case "b": return .bool(parts[1] == "true")
    case "av" where parts[1].isEmpty: return .array(element: "v", [])
    default: break
    }
    return .string(text)
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
