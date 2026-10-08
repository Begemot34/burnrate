// Providers against canned responses.
import Foundation
import Testing
@testable import BurnrateCore

private let fixedNow = Date(timeIntervalSince1970: 1_791_288_000)  // 2026-10-06 12:00 UTC

/// Answers by URL path; nil body means the status alone.
private func deps(
    exec: Deps.Exec? = nil,
    _ route: @escaping @Sendable (URLRequest) -> (Int, String?, [String: String])
) -> Deps {
    Deps(
        transport: { req in
            let (code, body, headers) = route(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
            return (Data((body ?? "").utf8), resp)
        }, exec: exec ?? { _, name, _ in throw Shell.NotFound(name: name) }, now: { fixedNow })
}

private func ok(_ body: String) -> (Int, String?, [String: String]) { (200, body, [:]) }

private func tempDir() -> String {
    let d = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func facts(_ s: Snapshot) -> [String: String] {
    Dictionary(s.facts.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
}

@Suite struct ProviderTests {
    @Test func claude() async throws {
        func creds(_ exp: Date) -> Deps.Exec {
            { _, _, _ in
                try JSONSerialization.data(withJSONObject: [
                    "claudeAiOauth": [
                        "accessToken": "tok", "expiresAt": ms(exp), "subscriptionType": "max",
                        "rateLimitTier": "default_claude_max_20x",
                    ]
                ])
            }
        }
        let route: @Sendable (URLRequest) -> (Int, String?, [String: String]) = { r in
            guard r.value(forHTTPHeaderField: "Authorization") == "Bearer tok",
                r.value(forHTTPHeaderField: "anthropic-beta") != nil
            else { return (401, nil, [:]) }
            return ok(
                #"""
                {"five_hour":{"utilization":19.0,"resets_at":"2026-10-06T13:50:00Z"},
                 "seven_day":{"utilization":5,"resets_at":"2026-10-10T11:00:00+00:00"},"seven_day_opus":null,
                 "extra_usage":{"is_enabled":false}}
                """#)
        }
        var c = Claude(deps: deps(exec: creds(fixedNow.addingTimeInterval(3600)), route))
        let s = try await c.fetch()
        #expect(s.gauges.count == 2 && s.gauges[0].value == 19 && s.gauges[0].resetAt == ms(fixedNow.addingTimeInterval(110 * 60)))
        #expect(s.facts[1].value == "MAX 20X" && s.plan == "claude_max_20x")
        c.deps = deps(exec: creds(fixedNow.addingTimeInterval(-60)), route)
        await #expect(throws: ProviderError.auth("TOKEN EXPIRED — START CLAUDE ONCE TO RENEW")) { try await c.fetch() }
    }

    @Test func claudeLimitsList() throws {
        let u = try JSONDecoder().decode(
            Claude.Usage.self,
            from: Data(
                #"""
                {"five_hour":{"utilization":21},"seven_day_opus":null,
                 "limits":[{"kind":"session","percent":21,"severity":"normal","resets_at":"2026-10-06T13:50:00Z","scope":null},
                 {"kind":"weekly_all","percent":6,"severity":"normal","resets_at":"2026-10-10T08:59:59Z","scope":null},
                 {"kind":"weekly_scoped","percent":93,"severity":"critical","resets_at":"2026-10-10T08:59:59Z","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}],
                 "seven_day_breakdown":{"rows":[{"key":"claude_code","display_name":"Claude Code","percent":100},{"key":"chat","display_name":"Chats","percent":0}]},
                 "spend":{"used":{"amount_minor":1250,"currency":"USD","exponent":2},"limit":{"amount_minor":5000,"currency":"USD","exponent":2},"enabled":true},
                 "extra_usage":{"is_enabled":false}}
                """#.utf8))
        let s = Claude.snapshot(u)
        #expect(s.gauges.count == 3 && s.gauges[2].label == "7D FABLE" && s.gauges[2].value == 93)
        #expect(s.gauges[2].severity == "crit" && s.series == 21)
        #expect(s.gauges.map(\.window) == [ms(hour5), ms(week), ms(week)])
        #expect(Claude.extraFacts(u).map(\.value) == ["CLAUDE CODE 100%", "$12.50 / $50.00"])
        #expect(Claude.plan("max", "default_claude_max_20x") == "claude_max_20x" && Claude.plan("pro", "") == "claude_pro")
    }

    @Test func codexHTTPAndSessionFallback() async throws {
        let home = tempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try #"{"tokens":{"access_token":"a.b.c","account_id":"acc"}}"#.write(toFile: home + "/auth.json", atomically: true, encoding: .utf8)
        let fail = Locked(false)
        var c = Codex(
            deps: deps { r in
                if fail.withLock({ $0 }) { return (429, nil, ["Retry-After": "60"]) }
                guard r.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acc" else { return (400, nil, [:]) }
                return ok(
                    #"""
                    {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":8,"limit_window_seconds":18000,"reset_at":1791200000},
                     "secondary_window":{"used_percent":30,"limit_window_seconds":604800,"reset_after_seconds":3600}}}
                    """#)
            }, home: home, unofficial: true)
        c.baseURL = "https://chatgpt.test"
        c.appServer = ["false"]
        var s = try await c.fetch()
        #expect(s.gauges[0].value == 8 && s.gauges[0].resetAt == 1_791_200_000_000 && s.gauges[1].label == "7D WINDOW")
        #expect(s.gauges[1].resetAt == ms(fixedNow.addingTimeInterval(3600)))
        #expect(s.gauges[0].window == ms(hour5) && s.gauges[1].window == ms(week))

        // HTTP rate-limited, no session log → retryAfter
        fail.withLock { $0 = true }
        await #expect(throws: ProviderError.retryAfter(60)) { try await c.fetch() }

        // session log: one null-window event, then a good one
        let dir = home + "/sessions/2026/10/06"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = """
            {"timestamp":"2026-10-06T11:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}
            {"timestamp":"2026-10-06T11:30:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40,"window_minutes":300,"resets_at":1791200000},"secondary":{"used_percent":12,"window_minutes":10080},"plan_type":"plus"}}}
            {"timestamp":"2026-10-06T11:40:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":null,"secondary":null}}}

            """
        try log.write(toFile: dir + "/rollout-x.jsonl", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: dir + "/rollout-x.jsonl")
        s = try await c.fetch()
        #expect(s.gauges[0].value == 40 && s.hint.contains("30M0S OLD"))
        #expect(s.gauges[0].window == ms(hour5) && s.gauges[1].window == ms(week))
    }

    @Test func codexAppServer() async throws {
        // a fake app-server: answers initialize, skips a notification, then the limits
        let script = #"""
            read l; echo '{"id":1,"result":{"userAgent":"x"}}'
            read l; read l
            echo '{"method":"remoteControl/status/changed","params":{}}'
            echo '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1791421347},
             "secondary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":1791981612},"credits":{"hasCredits":true,"unlimited":false,"balance":"4.5"},
             "planType":"plus","rateLimitReachedType":null},
             "rateLimitsByLimitId":{"codex":{"limitId":"codex"},"astra":{"limitId":"astra","limitName":"gpt-6-astra","primary":{"usedPercent":50,"windowDurationMins":300}}},
             "rateLimitResetCredits":{"availableCount":1}}}' | tr -d '\n'; echo
            """#
        let home = tempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        var c = Codex(deps: deps { _ in (500, nil, [:]) }, home: home)
        c.appServer = ["sh", "-c", script]
        let s = try await c.fetch()
        #expect(s.gauges.count == 3 && s.gauges[0].value == 7 && s.gauges[0].resetAt == 1_791_421_347_000)
        #expect(s.gauges[1].label == "7D WINDOW" && s.gauges[2].label == "5H GPT-6-ASTRA" && s.gauges[2].value == 50)
        #expect(s.gauges[1].window == ms(week) && s.gauges[2].window == ms(hour5))
        let f = facts(s)
        #expect(f["LIMIT RESETS"] == "1" && f["CREDITS"] == "$4.50" && s.plan == "chatgpt_plus" && s.hint.isEmpty)

        // login error from the app-server → auth hint; no session log to fall back on
        c.appServer = ["sh", "-c", #"read l; echo '{"id":1,"result":{}}'; read l; read l; echo '{"id":2,"error":{"code":-32600,"message":"not logged in"}}'"#]
        await #expect(throws: ProviderError.auth("CODEX NOT LOGGED IN WITH CHATGPT — RUN CODEX LOGIN")) { try await c.fetch() }

        c.appServer = ["no-such-codex-binary"]
        await #expect(throws: ProviderError.auth("INSTALL THE CODEX CLI")) { try await c.fetch() }
    }

    @Test func codexModelUsageAndWindows() throws {
        let c = Codex(deps: deps { _ in (500, nil, [:]) }, home: "/nonexistent")
        var l = try JSONDecoder().decode(
            Codex.Limits.self,
            from: Data(
                #"""
                {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":8,"limit_window_seconds":18000}},
                 "model_usage":{"gpt-6-astra":{"available":false,"available_at":1791200000}},
                 "additional_rate_limits":[{"limit_name":"astra","rate_limit":{"primary_window":{"used_percent":50,"limit_window_seconds":18000}}}],
                 "rate_limit_reset_credits":{"available_count":2}}
                """#.utf8))
        var s = c.snapshot(l, hint: "")
        #expect(s.gauges.count == 2 && s.gauges[1].label == "5H ASTRA" && s.gauges[1].value == 50)
        let f = facts(s)
        #expect(f["GPT-6-ASTRA"]?.hasPrefix("LOCKED UNTIL") == true && f["LIMIT RESETS"] == "2" && s.plan == "chatgpt_plus")

        l = try JSONDecoder().decode(
            Codex.Limits.self,
            from: Data(
                #"""
                {"rate_limit":{"primary_window":{"used_percent":8,"limit_window_seconds":3600},
                 "secondary_window":{"used_percent":30,"window_minutes":1440}},
                 "additional_rate_limits":[{"limit_name":"astra","rate_limit":{"secondary_window":{"used_percent":5}}}]}
                """#.utf8))
        s = c.snapshot(l, hint: "")
        #expect(s.gauges.map(\.window) == [3_600_000, 86_400_000, ms(week)])
        #expect(Codex.durationString(minutesRounded: 1800) == "30m0s" && Codex.durationString(minutesRounded: 3900) == "1h5m0s")
    }

    @Test func openRouterCreditsForbidden() async throws {
        let o = OpenRouter(
            deps: deps { r in
                r.url!.path == "/api/v1/key"
                    ? ok(#"{"data":{"usage":65.07,"usage_daily":18.86,"usage_monthly":65.07,"limit":null,"limit_remaining":null}}"#)
                    : (403, nil, [:])
            }, key: "k")
        let s = try await o.fetch()
        #expect(!s.hint.isEmpty && s.gauges.count == 2 && s.gauges[0].value == 18.86)
    }

    @Test func balancesHaveThresholdsNoBar() async throws {
        let d = deps { r in
            switch r.url!.path {
            case "/api/v1/key": ok(#"{"data":{"usage":65,"usage_daily":1,"usage_monthly":42.5}}"#)
            case "/api/v1/credits": ok(#"{"data":{"total_credits":219,"total_usage":212}}"#)
            case "/api/account": ok(#"{"type":"user","username":"me","account_options":[]}"#)
            case "/api/users/me/invoices":
                ok(#"{"invoices":[{"type":"monthly-usage","ended_before":null,"total_cost_before_adjustments":"15.79"}]}"#)
            case "/api/users/me/unused-credit": ok(#"{"unused_credit":"3.2"}"#)
            default: (404, nil, [:])
            }
        }
        let o = try await OpenRouter(deps: d, key: "k").fetch()
        let g = o.gauges[0]
        #expect(g.max == nil && g.value == 7 && g.warnBelow == 10 && g.critBelow == 5 && o.monthUSD == 42.5)
        let r = try await Replicate(deps: d, sessionID: "s").fetch()
        #expect(r.gauges[0].label == "CREDITS LEFT" && r.gauges[0].value == 3.2 && r.balance && r.series == 3.2)
        #expect(r.gauges[1].key == "month" && r.monthUSD == 15.79 && facts(r)["USER"] == "ME")
    }

    @Test func replicateInvoiceAndCookie() async throws {
        #expect(
            Replicate.currentInvoice(
                Data(
                    #"""
                    [{"type":"monthly-usage","ended_before":"2026-09-01","total_cost_before_adjustments":"99"},
                     {"type":"monthly-usage","ended_before":null,"total_cost_before_adjustments":"12.80"}]
                    """#.utf8)) == 12.8)
        #expect(
            Replicate.currentInvoice(
                Data(
                    #"""
                    {"invoices":[{"type":"credit-purchase","ended_before":"2026-10-03","total_cost_before_adjustments":"0"},
                     {"type":"monthly-usage","status":"DRAFT","ended_before":null,"total_cost_before_adjustments":"15.7935"}],"invoice_urls":{}}
                    """#.utf8)) == 15.7935)
        #expect(Replicate.currentInvoice(Data(#"{"results":[{"type":"monthly-usage","total_cost_before_adjustments":3.5}]}"#.utf8)) == 3.5)

        let r = Replicate(
            deps: deps { r in
                r.url!.path == "/api/account" ? ok(#"{"type":"user","username":"me"}"#) : (403, nil, [:])
            }, sessionID: "old")
        await #expect(throws: ProviderError.auth("SESSIONID COOKIE EXPIRED — PASTE A NEW ONE IN SETTINGS")) { try await r.fetch() }
        let none = Replicate(deps: deps { _ in (500, nil, [:]) }, sessionID: "")
        await #expect(throws: ProviderError.self) { try await none.fetch() }
    }

    @Test func higgsfield() async throws {
        let h = Higgsfield(
            deps: deps(exec: { env, name, _ in
                guard name == "higgsfield", env["HIGGSFIELD_NO_UPDATE_CHECK"] == "1" else { throw ProviderError.failed("bad call") }
                return Data(#"{"credits": 410.5, "email": "x", "subscription_plan_type": "pro"}"#.utf8)
            }) { _ in (500, nil, [:]) })
        let s = try await h.fetch()
        #expect(s.gauges[0].value == 410.5 && s.balance && facts(s)["≈ USD"] == "$19.70")
    }

    @Test func scrubLeaksNothing() {
        let out = Scrub.text("Bearer sk-ant-oat01-SECRETSECRET r8_ABCDsecretsecret eyJhbGciOiJIUzI1NiJ9.payload.sig")
        for leak in ["SECRETSECRET", "secretsecret", "payload"] { #expect(!out.contains(leak), "\(out)") }
    }

    @Test func scrubCutsCookiesAndSecretPairs() {
        let cases = [
            "Cookie: sessionid=abc123SECRET; csrftoken=zzTOKENzz",
            "set-cookie: sessionid=abc123SECRET; Path=/",
            "failed with sessionid=abc123SECRET&x=1",
            #"{"access_token":"abc123SECRET","expires_in":3600}"#,
            "refresh_token=abc123SECRET id_token: abc123SECRET",
            "OPENROUTER_API_KEY=abc123SECRET HF_TOKEN='abc123SECRET'",
            #"{"token": "abc123SECRET", "api_key":"abc123SECRET"}"#,
            "password=abc123SECRET secret: abc123SECRET apikey=abc123SECRET",
            "Authorization: Basic abc123SECRET",
            #"{"authorization":"Token abc123SECRET"}"#,
        ]
        for c in cases {
            let out = Scrub.text(c)
            for leak in ["abc123SECRET", "csrftoken=zz"] { #expect(!out.contains(leak), "\(c) -> \(out)") }
        }
        #expect(Scrub.text("status=200 plan=pro") == "status=200 plan=pro")
        #expect(Scrub.text("sessionid=abc&x=1") == "sessionid=…&x=1")
    }

    @Test func shellRunsAndReportsStderr() async throws {
        let out = try await Shell.run("sh", ["-c", "echo $GT_X"], env: ["GT_X": "hi"])
        #expect(String(decoding: out, as: UTF8.self) == "hi\n")
        await #expect(throws: ProviderError.failed("sh: boom")) {
            try await Shell.run("sh", ["-c", "echo first >&2; echo boom >&2; exit 3"])
        }
        await #expect(throws: ProviderError.failed("sh: timed out")) {
            try await Shell.run("sh", ["-c", "sleep 5"], timeout: .milliseconds(200))
        }
    }
}

@Suite struct APICostTests {
    static let pricesJSON = #"""
        {"data":[
         {"id":"anthropic/claude-opus-5.5","pricing":{"prompt":"0.000004","completion":"0.00002","input_cache_read":"0.0000002","input_cache_write":"0.000005","input_cache_write_1h":"0.000008"}},
         {"id":"anthropic/claude-opus-5.5:batch","pricing":{"prompt":"1"}},
         {"id":"openai/gpt-5.5","pricing":{"prompt":"0.000005","completion":"0.00003","input_cache_read":"0.0000005","overrides":[{"min_prompt_tokens":272000,"prompt":"0.00001"}]}},
         {"id":"google/gemini-x","pricing":{"prompt":"1"}}]}
        """#

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func write(_ path: String, _ lines: [String]) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func near(_ a: Double?, _ b: Double) -> Bool { abs((a ?? .nan) - b) < 0.005 }

    @Test func normalize() {
        let cases = [
            "claude-opus-5-5": "claude-opus-5.5", "claude-haiku-4-5-20251001": "claude-haiku-4.5",
            "claude-sonnet-5": "claude-sonnet-5", "gpt-5.5": "gpt-5.5",
        ]
        for (i, want) in cases { #expect(APICostTracker.normalize(i) == want) }
    }

    @Test func scan() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prices = try APICostTracker.parsePrices(Data(Self.pricesJSON.utf8))
        #expect(prices.count == 2)
        let now = Date(timeIntervalSince1970: 1_791_374_400)  // 2026-10-07 12:00 UTC: the window starts 2026-09-08
        let msg = #"{"timestamp":"2026-10-05T10:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1000,"output_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":10000,"cache_creation":{"ephemeral_1h_input_tokens":1000}}}}"#
        try write(
            dir + "/claude/proj/s.jsonl",
            [
                msg,
                msg,  // the same message logged again: counted once
                #"{"timestamp":"2026-09-07T23:00:00Z","requestId":"r0","message":{"id":"m0","model":"claude-opus-5-5","usage":{"input_tokens":999999}}}"#,
                #"{"timestamp":"2026-10-05T10:00:01Z","message":{"id":"m2","model":"<synthetic>","usage":{"input_tokens":5}}}"#,
                #"{"timestamp":"2026-10-05T10:00:02Z","requestId":"r3","message":{"id":"m3","model":"claude-mystery-9","usage":{"input_tokens":5}}}"#,
            ])
        let codex = dir + "/codex/2026/10/05/r.jsonl"
        try write(
            codex,
            [
                #"{"timestamp":"2026-10-05T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
                #"{"timestamp":"2026-10-05T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":8000,"output_tokens":100}}}}"#,
                #"{"timestamp":"2026-10-05T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":8000,"output_tokens":100}}}}"#,
                #"{"timestamp":"2026-10-05T10:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30000,"cached_input_tokens":26000,"output_tokens":300}}}}"#,
            ])
        let tr = APICostTracker(
            claudeDir: dir + "/claude", codexDir: dir + "/codex", cacheFile: nil, network: false,
            calendar: utc, now: { now })
        tr.prices = prices
        tr.pricesAt = now
        // opus: 1000×4e-6 + 1000×20e-6 + 10000×0.2e-6 + 1000×5e-6 + 1000×8e-6 = 0.039
        // gpt:  4000×5e-6 + 26000×0.5e-6 + 300×30e-6 = 0.042
        var r = await tr.scan()
        #expect(r?.items.count == 2 && near(r?.items[0].usd, 0.04) && near(r?.items[1].usd, 0.04))
        #expect(r?.unpriced == ["claude-mystery-9"])

        // appended lines are picked up from the saved offset, old ones are not recounted
        let h = FileHandle(forWritingAtPath: codex)!
        try h.seekToEnd()
        try h.write(contentsOf: Data((#"{"timestamp":"2026-10-05T10:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30000,"cached_input_tokens":26000,"output_tokens":100300}}}}"# + "\n").utf8))
        try h.close()
        r = await tr.scan()
        #expect(near(r?.items[1].usd, 3.04))
    }

    @Test func windowSlides() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(
            dir + "/p/s.jsonl",
            [
                #"{"timestamp":"2026-10-05T10:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"output_tokens":1000000}}}"#
            ])
        // keep the file inside the window whatever today is
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_791_374_400)],
            ofItemAtPath: dir + "/p/s.jsonl")
        let clock = Locked(Date(timeIntervalSince1970: 1_791_374_400))  // 2026-10-07 12:00 UTC
        let tr = APICostTracker(
            claudeDir: dir, codexDir: "", cacheFile: nil, network: false, calendar: utc,
            now: { clock.withLock { $0 } })
        tr.prices = try APICostTracker.parsePrices(Data(Self.pricesJSON.utf8))
        tr.pricesAt = clock.withLock { $0 }
        var r = await tr.scan()
        #expect(r?.days == 30 && near(r?.usd, 20))
        clock.withLock { $0 += 27 * 86400 }  // 2026-11-03: the window starts Oct 5, still inside
        r = await tr.scan()
        #expect(near(r?.usd, 20))
        clock.withLock { $0 += 86400 }  // 2026-11-04: the window starts Oct 6
        r = await tr.scan()
        #expect(r?.usd == 0)
    }

    @Test func readsGoPriceCache() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try #"{"at":"2026-10-07T09:12:13.123456+03:00","prices":{"gpt-5.5":{"In":5e-06,"Out":3e-05,"CacheRead":5e-07,"CacheWrite":0,"CacheWrite1h":0}}}"#
            .write(toFile: dir + "/api-prices.json", atomically: true, encoding: .utf8)
        let tr = APICostTracker(
            claudeDir: "", codexDir: "", cacheFile: dir + "/api-prices.json", network: false,
            now: { Date(timeIntervalSince1970: 1_791_374_400) })
        _ = await tr.scan()
        #expect(tr.prices["gpt-5.5"]?.Out == 3e-05 && tr.pricesAt != nil)
        #expect(tr.price("gpt-5.5-codex")?.In == 5e-06, "trailing name parts are dropped")
    }
}
