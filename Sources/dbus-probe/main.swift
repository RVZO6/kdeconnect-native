import DBusKit
import Foundation
import KDEConnectKit

// Development tool: prints the D-Bus API of the running kdeconnectd.
//   dbus-probe introspect [path]
//   dbus-probe call <path> <interface> <member> [string args...]

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
                                          args.dropFirst(4).map { .string($0) })
    for value in reply { print(value) }
default:
    let path = args.dropFirst().first ?? "/modules/kdeconnect"
    let reply = try await connection.call(destination: service, path: path,
                                          interface: "org.freedesktop.DBus.Introspectable", member: "Introspect")
    print(reply.first?.stringValue ?? "")
}
connection.close()
