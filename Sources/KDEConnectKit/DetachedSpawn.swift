import Darwin
import Foundation

/// Starts helper processes that are independent of this app.
///
/// macOS charges privacy (TCC) checks to the "responsible" process. This app
/// stays responsible for kdeconnectd, so its Info.plist declares Bluetooth
/// use. A disclaimed kdeconnectd is responsible for itself, but it is a bare
/// executable without a bound Info.plist, so TCC stops it when it must ask
/// for Bluetooth access.
enum DetachedSpawn {
    /// Spawns `executable` in a new session. Its stdout goes to `stdout`
    /// (or the log), and its stderr goes to `stderr`. The child is reaped on
    /// a background thread so that it does not stay as a zombie.
    static func spawn(_ executable: URL, arguments: [String], environment: [String: String],
                      stdout: Int32, stderr: Int32) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        let argv = [executable.path] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { argvPointers in
            withCStrings(envp) { envPointers in
                posix_spawn(&pid, executable.path, &actions, &attr, argvPointers, envPointers)
            }
        }
        guard result == 0 else {
            throw DaemonError.spawnFailed("\(executable.lastPathComponent): \(String(cString: strerror(result)))")
        }
        let child = pid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        }
        return pid
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
