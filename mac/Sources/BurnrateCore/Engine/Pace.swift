// Pace forecast for rolling "percent used" limits (Claude and Codex weekly windows).
//
// Why: a bare "60% used" says little on its own. A day before the reset it
// means there is plenty left to burn; on the first day it means the limit will
// run out mid-week. What matters is the percent at the reset if usage keeps
// its current speed, and that is what this projects.
//
// How: the window opened at resetAt − window. The share of it already gone is
//
//     elapsed = (now − (resetAt − window)) / window      (0..1)
//
// and with the average rate since the window opened held to the end,
//
//     pace = used / elapsed
//
// e.g. 13% used with 38% of the week gone → 13 / 0.38 ≈ 34% at the reset.
// The result is not capped: 140% means the limit hits well before the reset.
//
// The forecast is bucketed into a dot next to the value:
//
//     under  < 80%     blue:  room to burn more
//     on     80..110%  green: on track to use the window about fully
//     over   > 110%    red:   slow down, the limit hits before the reset
//
// This is deliberately separate from the warn/crit level of the value itself:
// warn/crit says "close to the wall now", pace says "where the current speed
// leads". Blue is not bad, only a hint that capacity is being left unused.
//
// Limits of the model, and how they are handled:
//   - It is linear: nights, weekends and bursts are averaged over the window,
//     so it answers "at this week's average speed", not "at the last hour's".
//   - Early in a window elapsed is tiny and the division turns noise into big
//     numbers, so nothing is shown before paceMinElapsed of the window passed.
//   - When the reset is already past (stale data) or the window or reset time
//     is unknown, nothing is shown.
//   - Claude's weekly window starts at the first message after a reset, so
//     its reset time already encodes the start: resetAt − 7d is exact.
//   - Short windows (5h) are skipped by the scheduler: the forecast swings too
//     much there to act on (see paceMinWindow).
//   - The scheduler computes it as of the snapshot's fetch time, so a card
//     that went stale keeps its last pace instead of drifting toward blue.
import Foundation

public enum Pace {
    /// Share of the window that must pass before a forecast is shown.
    public static let minElapsed = 0.10
    /// Windows shorter than a day get no forecast.
    static let minWindow: Int64 = 86_400_000

    /// Projects a "used" percent to the window's reset (all times unix ms).
    /// elapsed is the share of the window gone, 0..1. nil when the window is
    /// unknown, the reset already passed or too little time went by.
    public static func forecast(used: Double, resetAt: Int64, window: Int64, now: Int64)
        -> (pace: Double, elapsed: Double)?
    {
        guard window > 0, resetAt > 0, used.isFinite else { return nil }
        let elapsed = Double(now - (resetAt - window)) / Double(window)
        guard elapsed >= minElapsed, elapsed <= 1 else { return nil }
        let pace = used / elapsed
        return pace.isFinite ? (pace, elapsed) : nil
    }

    /// under (<80), on (80..110), over (>110), bucketing the whole percent the UI
    /// shows, so "→80%" is never blue.
    public static func level(_ p: Double) -> String {
        let p = p.rounded(.toNearestOrAwayFromZero)
        return p < 80 ? "under" : p > 110 ? "over" : "on"
    }

    /// A copy of gs with the reset forecast filled in for day-plus "used" percent windows.
    static func fill(_ gs: [Meter], at now: Date) -> [Meter] {
        gs.map { g in
            var g = g
            guard g.kind == "percent", g.dir == "used", (g.window ?? 0) >= minWindow,
                let f = forecast(used: g.value, resetAt: g.resetAt ?? 0, window: g.window ?? 0, now: ms(now))
            else { return g }
            (g.pace, g.elapsed, g.paceLevel) = (f.pace, f.elapsed * 100, level(f.pace))
            return g
        }
    }
}
