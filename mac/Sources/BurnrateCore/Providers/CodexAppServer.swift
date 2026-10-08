// The app-server speaks JSON-RPC 2.0, one message per line on stdio:
// initialize → initialized → account/rateLimits/read.
// https://learn.chatgpt.com/docs/app-server
import Foundation

extension Codex {
    struct ASWindow: Decodable {
        var usedPercent: LooseNumber?
        var resetsAt: Epoch?
        var windowDurationMins: LooseNumber?

        var window: Window {
            Window(used_percent: usedPercent, resets_at: resetsAt, window_minutes: windowDurationMins)
        }
    }

    struct ASSnapshot: Decodable {
        struct Credits: Decodable {
            var hasCredits: Bool?
            var unlimited: Bool?
            var balance: LooseNumber?
        }
        var limitId: String?
        var limitName: String?
        var primary: ASWindow?
        var secondary: ASWindow?
        var credits: Credits?
        var planType: String?
        var rateLimitReachedType: String?
    }

    struct ASRateLimits: Decodable {
        struct ResetCredits: Decodable { var availableCount: LooseNumber? }
        var rateLimits: ASSnapshot
        var rateLimitsByLimitId: [String: ASSnapshot]?
        var rateLimitResetCredits: ResetCredits?

        /// The shape snapshot() already knows; buckets other than the main
        /// "codex" one become per-model gauges.
        var limits: Limits {
            let main = rateLimits
            var l = Limits()
            l.plan_type = main.planType
            l.primary = main.primary?.window
            l.secondary = main.secondary?.window
            l.reached = main.rateLimitReachedType ?? ""
            if let cr = main.credits {
                l.credits = Credits(has_credits: cr.hasCredits, unlimited: cr.unlimited, balance: cr.balance)
            }
            if let rc = rateLimitResetCredits {
                l.rate_limit_reset_credits = Limits.ResetCredits(available_count: rc.availableCount)
            }
            for (id, b) in (rateLimitsByLimitId ?? [:]).sorted(by: { $0.key < $1.key })
            where id != main.limitId && id != "codex" {
                let name = (b.limitName ?? "").isEmpty ? id : b.limitName!
                l.extra += Codex.named(key: id.lowercased(), name: name, b.primary?.window, b.secondary?.window)
            }
            return l
        }
    }

    func fetchAppServer() async throws -> Limits {
        guard let exe = Shell.resolve(appServer[0]) else { throw ProviderError.auth("INSTALL THE CODEX CLI") }
        let child = Child(exe, Array(appServer.dropFirst()), env: Shell.environment([:]))
        let watchdog: Task<Void, Never>
        do {
            watchdog = try child.start(timeout: .seconds(20))
        } catch {
            throw ProviderError.failed("codex app-server: \(error.localizedDescription)")
        }
        let stderr = Task.detached { await Child.readAll(child.stderr.fileHandleForReading) }
        defer {
            watchdog.cancel()
            try? child.stdin.fileHandleForWriting.close()
            child.kill()
        }
        let input = child.stdin.fileHandleForWriting
        func send(_ m: [String: Any]) {
            var m = m
            m["jsonrpc"] = "2.0"
            guard var b = try? JSONSerialization.data(withJSONObject: m) else { return }
            b.append(10)
            try? input.write(contentsOf: b)
        }
        send([
            "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "burnrate", "title": "burnrate", "version": "1"]],
        ])

        struct Message: Decodable {
            struct RPCError: Decodable { var message: String? }
            var id: Int?
            var error: RPCError?
        }
        struct Reply: Decodable { var result: ASRateLimits }
        let dec = JSONDecoder()
        for try await line in child.stdout.fileHandleForReading.bytes.lines {
            let data = Data(line.utf8)
            guard let msg = try? dec.decode(Message.self, from: data), let id = msg.id else { continue }  // notifications
            if let e = msg.error {
                let m = Scrub.text(e.message ?? "")
                let low = m.lowercased()
                if ["auth", "log in", "logged in", "login"].contains(where: low.contains) {
                    throw ProviderError.auth("CODEX NOT LOGGED IN WITH CHATGPT — RUN CODEX LOGIN")
                }
                throw ProviderError.failed("codex app-server: \(m)")
            }
            switch id {
            case 1:
                send(["method": "initialized"])
                send(["id": 2, "method": "account/rateLimits/read"])
            case 2:
                let r: ASRateLimits
                do {
                    r = try dec.decode(Reply.self, from: data).result
                } catch {
                    throw ProviderError.failed("codex app-server: \(describe(error))")
                }
                if r.rateLimits.primary == nil && r.rateLimits.secondary == nil {
                    throw ProviderError.auth("NO CHATGPT PLAN LIMITS — RUN CODEX LOGIN")
                }
                return r.limits
            default:
                continue
            }
        }
        if child.timedOut { throw ProviderError.failed("codex app-server: timed out") }
        try? input.close()
        let err = await stderr.value  // complete once the process is gone
        throw ProviderError.failed("codex app-server: " + Scrub.text(lastLine(String(decoding: err, as: UTF8.self))))
    }
}
