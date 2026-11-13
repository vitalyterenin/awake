import Darwin
import MachO

/// Establish the app's own launch identity before registering UI or requesting access.
package enum LaunchIdentity {
    private static let reexecKey = "AWAKE_IDENTITY_REEXEC"
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Bool) -> Int32

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        // Darwin's RTLD_DEFAULT macro is unavailable to the Swift importer.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    package static var responsiblePID: pid_t? {
        guard let symbol = symbol("responsibility_get_pid_responsible_for_pid") else { return nil }
        let pid = unsafeBitCast(symbol, to: ResponsiblePID.self)(getpid())
        return pid > 0 ? pid : nil
    }

    package static func prepare() throws {
        guard let responsible = responsiblePID else { throw Failure.unavailable }
        if responsible == getpid() {
            unsetenv(reexecKey)
            return
        }
        // Never register a menu item under the launcher, even if re-exec fails.
        guard getenv(reexecKey) == nil else { throw Failure.inherited }
        guard let symbol = symbol("responsibility_spawnattrs_setdisclaim") else { throw Failure.unavailable }
        let disclaim = unsafeBitCast(symbol, to: Disclaim.self)
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC)))
        try check(disclaim(&attributes, true))

        var length: UInt32 = 0
        _NSGetExecutablePath(nil, &length)
        guard length > 0 else { throw Failure.unavailable }
        var path = [CChar](repeating: 0, count: Int(length))
        guard _NSGetExecutablePath(&path, &length) == 0 else { throw Failure.unavailable }
        guard setenv(reexecKey, "1", 1) == 0 else { throw Failure.system(errno) }
        defer { unsetenv(reexecKey) }
        var child: pid_t = 0
        // Replace this process, preserving its PID, arguments, environment, working
        // directory and standard streams. No helper or login item remains running.
        try check(posix_spawn(&child, path, nil, &attributes, CommandLine.unsafeArgv, environ))
        throw Failure.inherited // Successful SETEXEC never returns.
    }

    private static func check(_ result: Int32) throws {
        if result != 0 { throw Failure.system(result) }
    }

    private enum Failure: Error, CustomStringConvertible {
        case unavailable, inherited, system(Int32)
        var description: String {
            switch self {
            case .unavailable: "Launch identity APIs are unavailable."
            case .inherited: "Awake still belongs to its launcher after restarting."
            case .system(let code): "Cannot establish Awake's launch identity: \(String(cString: strerror(code))) (\(code))."
            }
        }
    }
}
