// Child processes: resolve the tool on a PATH that also has Homebrew (an app
// started from Finder gets a bare one), run with a timeout, keep stderr's last line.
import Foundation

public enum Shell {
    /// The usual tool dirs first, then the inherited PATH.
    public static let path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", home + "/.local/bin", home + "/bin"]
        for d in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":")
        where !dirs.contains(String(d)) {
            dirs.append(String(d))
        }
        return dirs.joined(separator: ":")
    }()

    /// The executable for name: a path as is, otherwise the first match on `path`.
    static func resolve(_ name: String) -> URL? {
        let fm = FileManager.default
        if name.contains("/") { return fm.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil }
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    static func environment(_ extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path  // the shebang of higgsfield looks for node here
        env.merge(extra) { _, new in new }
        return env
    }

    struct NotFound: Error, CustomStringConvertible {
        let name: String
        var description: String { "\(name): executable file not found in $PATH" }
    }

    /// Runs name and returns stdout; a non-zero exit throws "name: <last stderr line>".
    public static func run(
        _ name: String, _ args: [String], env: [String: String] = [:],
        timeout: Duration = .seconds(30)
    ) async throws -> Data {
        guard let exe = resolve(name) else { throw NotFound(name: name) }
        let child = Child(exe, args, env: environment(env))
        let (out, err, status) = try await child.run(timeout: timeout)
        if child.timedOut { throw ProviderError.failed("\(name): timed out") }
        guard status == 0 else {
            throw ProviderError.failed("\(name): " + Scrub.text(lastLine(String(decoding: err, as: UTF8.self))))
        }
        return out
    }
}

/// One process with captured stdout and stderr. Process and its pipes are not
/// Sendable; they never leave this class, and the class is only touched by
/// the task that runs it and its own timeout.
final class Child: @unchecked Sendable {
    let process = Process()
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let lock = NSLock()
    private var _timedOut = false
    var timedOut: Bool { lock.withLock { _timedOut } }

    init(_ exe: URL, _ args: [String], env: [String: String]) {
        process.executableURL = exe
        process.arguments = args
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    /// Starts the process; after timeout it is killed and timedOut is set.
    func start(timeout: Duration) throws -> Task<Void, Never> {
        try process.run()
        return Task.detached { [self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, process.isRunning else { return }
            lock.withLock { _timedOut = true }
            kill()
        }
    }

    func kill() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { Darwin.kill(pid, SIGKILL) }
    }

    /// Reads a pipe to EOF off the cooperative pool.
    static func readAll(_ h: FileHandle) async -> Data {
        await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning: (try? h.readToEnd()) ?? Data()) }
        }
    }

    /// Runs to completion with stdin closed; returns stdout, stderr and the exit status.
    func run(timeout: Duration) async throws -> (Data, Data, Int32) {
        let exited = AsyncStream<Int32> { c in
            process.terminationHandler = { p in
                c.yield(p.terminationStatus); c.finish()
            }
        }
        let watchdog = try start(timeout: timeout)
        defer { watchdog.cancel() }
        try? stdin.fileHandleForWriting.close()
        async let out = Self.readAll(stdout.fileHandleForReading)
        async let err = Self.readAll(stderr.fileHandleForReading)
        var status: Int32 = -1
        for await s in exited { status = s }
        return (await out, await err, status)
    }
}
