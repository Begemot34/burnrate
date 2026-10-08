// Burnrate's own API keys in the login Keychain, read and written only through
// /usr/bin/security: the item then trusts Apple's tool instead of our ad-hoc
// signature, so neither a rebuild nor burnratectl ever prompts (docs/adr/0006).
import Foundation

public enum Keychain {
    public static let service = "burnrate"
    /// The keys Burnrate keeps; each is one item, the account is the variable name.
    public static let names = ["OPENROUTER_API_KEY", "REPLICATE_SESSIONID"]

    /// Runs /usr/bin/security with args and optional stdin; returns stdout and the exit status.
    public typealias Run = @Sendable (_ args: [String], _ input: String?) throws -> (Data, Int32)

    struct Failed: Error, CustomStringConvertible {
        let description: String
    }

    /// Every stored key; a missing item is just absent.
    public static func readAll(_ run: Run) -> [String: String] {
        var out: [String: String] = [:]
        for n in names {
            if let v = read(n, run), !v.isEmpty { out[n] = v }
        }
        return out
    }

    public static func read(_ name: String, _ run: Run) -> String? {
        guard let (data, status) = try? run(["find-generic-password", "-s", service, "-a", name, "-w"], nil),
            status == 0
        else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds or replaces the item. The value goes in on stdin through `security -i`, never in argv.
    public static func write(_ name: String, _ value: String, _ run: Run) throws {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard names.contains(name) else { throw Failed(description: "unknown key \(name)") }
        // keys and cookies are printable ASCII; anything else, or a line past security -i's
        // ~4 KB buffer, could end the quoted value and start another command
        guard !v.isEmpty, v.utf8.count <= 1024, v.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw Failed(description: "\(name): bad value")
        }
        let (_, status) = try run(["-i"], command(name, v))
        guard status == 0, read(name, run) == v else { throw Failed(description: "\(name): keychain write failed") }
    }

    public static func delete(_ name: String, _ run: Run) throws {
        let (_, status) = try run(["delete-generic-password", "-s", service, "-a", name], nil)
        // 44: no such item, already gone
        guard status == 0 || status == 44 else { throw Failed(description: "\(name): keychain delete failed") }
    }

    /// One line for `security -i`, the value quoted.
    static func command(_ name: String, _ value: String) -> String {
        let q = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "add-generic-password -U -s \(service) -a \(name) -w \"\(q)\"\n"
    }

    public static let live: Run = { args, input in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let out = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        return (out, p.terminationStatus)
    }

    /// "sk-or-v1-…a1b2": enough to recognise a key, not to use it.
    public static func mask(_ v: String) -> String {
        guard v.count > 12 else { return String(repeating: "•", count: 8) }
        return v.prefix(4) + "…" + v.suffix(4)
    }

    /// The sessionid out of whatever was pasted: the bare value, `sessionid=…`, or a whole Cookie header.
    public static func sessionID(from pasted: String) -> String {
        var s = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("cookie:") { s.removeFirst("cookie:".count) }
        guard s.contains("=") else { return s }
        for part in s.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "sessionid" {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
