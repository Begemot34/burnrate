// burnratectl: the Burnrate engine from the terminal.
//
//	burnratectl check        fetch every source once and print a table
//	burnratectl dump [-demo] one poll and one log scan, the full state as JSON
//	burnratectl init         write ~/.config/burnrate/config.json
//	burnratectl secret set NAME   store a key in the Keychain, value on stdin
//	burnratectl secret rm NAME    remove it
//	burnratectl secret ls         list the stored key names
//
// -config DIR picks another config directory.
import Foundation
import BurnrateCore

var args = Array(CommandLine.arguments.dropFirst())
var cfgDir = Config.defaultDir
var demo = false
var command = ""
var rest: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "-config", "--config":
        guard !args.isEmpty else { fail("-config needs a directory") }
        cfgDir = args.removeFirst()
    case "-demo", "--demo":
        demo = true
    case "-h", "-help", "--help":
        usage()
    default:
        if command.isEmpty { command = a } else { rest.append(a) }
    }
}

func usage() -> Never {
    print("usage: burnratectl [-config DIR] check | dump [-demo] | init | secret set|rm NAME | secret ls")
    exit(0)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("burnratectl: \(msg)\n".utf8))
    exit(1)
}

@MainActor func loadConfig() -> Config {
    do { return try Config.load(cfgDir, keychain: Keychain.live) } catch { fail("\(error)") }
}

if command != "secret", let a = rest.first { fail("unexpected \(a)") }

switch command {
case "secret":
    switch (rest.first, rest.count) {
    case ("ls", 1):
        for n in Keychain.names where Keychain.read(n, Keychain.live) != nil { print(n) }
    case ("set", 2):
        guard Keychain.names.contains(rest[1]) else { fail("NAME is one of " + Keychain.names.joined(separator: ", ")) }
        var value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        // a pasted `sessionid=…` or whole Cookie header, as in Settings
        if rest[1] == "REPLICATE_SESSIONID" { value = Keychain.sessionID(from: value) }
        do { try Keychain.write(rest[1], value, Keychain.live) } catch { fail("\(error)") }
        print("stored", rest[1])
    case ("rm", 2):
        do { try Keychain.delete(rest[1], Keychain.live) } catch { fail("\(error)") }
        print("removed", rest[1])
    default:
        usage()
    }

case "init":
    do {
        let made = try Config.initFiles(cfgDir)
        if made.isEmpty { print("already there:", cfgDir) }
        for p in made { print("wrote", p) }
    } catch {
        fail("\(error)")
    }

case "check":
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d HH:mm"
    var rows = [["SOURCE", "RESULT", "DETAILS"]]
    for (it, r) in await Engine.fetchOnce(Engine.items(loadConfig(), demo: demo)) {
        let p = it.provider
        if it.interval == 0 {
            rows.append([p.name, "link", p.link])
            continue
        }
        var parts: [String] = []
        var res = "ok"
        switch r {
        case .success(let s):
            for g in s.gauges {
                var v = String(format: "%.2f", g.value)
                if let m = g.max { v += String(format: "/%.0f", m) }
                if let reset = g.resetAt, reset > 0 {
                    v += " reset " + f.string(from: Date(timeIntervalSince1970: Double(reset) / 1000))
                }
                parts.append(g.label + "=" + v)
            }
            parts += s.facts.map { $0.label + "=" + $0.value }
            if !s.hint.isEmpty { parts.append("hint: " + s.hint) }
        case .failure(let e):
            res = "FAIL"
            parts.append(Scrub.text("\(e)"))
        }
        rows.append([p.name, res, parts.joined(separator: "  ")])
    }
    let w0 = rows.map(\.[0].count).max()!, w1 = rows.map(\.[1].count).max()!
    for r in rows {
        print(
            r[0].padding(toLength: w0 + 2, withPad: " ", startingAt: 0)
                + r[1].padding(toLength: w1 + 2, withPad: " ", startingAt: 0) + r[2])
    }

case "dump":
    let engine = Engine(config: loadConfig(), demo: demo, readOnly: true)
    let st = await engine.dumpOnce()
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try enc.encode(st), as: UTF8.self))

default:
    usage()
}
