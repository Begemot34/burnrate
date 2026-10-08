// Desktop widget: reads the snapshot the app writes to
// ~/Library/Application Support/burnrate/widget.json, never talks to the network.
// It follows the app's look: Boring or Cyberpunk.
import BurnrateCore
import SwiftUI
import WidgetKit

@main
struct BurnrateWidgets: WidgetBundle {
    init() { Fonts.register() }

    var body: some Widget { LimitsWidget() }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "limits", provider: SnapshotProvider()) { entry in
            LimitsView(entry: entry)
        }
        .configurationDisplayName("Burnrate")
        .description("AI limits and balances from the Burnrate app.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    /// The app rewrites the file at least every 5 minutes while it runs.
    var ageMs: Int64 {
        guard let s = snapshot else { return 0 }
        return max(0, Int64(date.timeIntervalSince1970 * 1000) - s.savedAt)
    }

    var stale: Bool { snapshot == nil || ageMs > 1_800_000 }

    /// Countdown to a reset as of this entry.
    func left(_ resetAt: Int64?) -> Int64? {
        resetAt.map { $0 - Int64(date.timeIntervalSince1970 * 1000) }
    }
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    /// One entry a minute so the countdowns tick; the app wakes us on changes,
    /// otherwise the file is re-read after 30 minutes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snap = WidgetSnapshot.load()
        let entries = (0..<30).map { SnapshotEntry(date: now.addingTimeInterval(Double($0) * 60), snapshot: snap) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct LimitsView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.snapshot?.look == "boring" {
            Group {
                if family == .systemSmall { BoringSmall(entry: entry) } else { BoringMedium(entry: entry) }
            }
            .containerBackground(.background, for: .widget)
        } else {
            Group {
                if family == .systemSmall { CyberSmall(entry: entry) } else { CyberMedium(entry: entry) }
            }
            .containerBackground(Cyber.bg, for: .widget)
            .environment(\.colorScheme, .dark)
        }
    }
}

/// What both looks split the snapshot into: limit sections on the left, balances on the right.
extension WidgetSnapshot {
    var limitRows: [Row] {
        rows.compactMap { r in
            let items = r.items.filter { !$0.isBalance }
            return items.isEmpty ? nil : Row(name: r.name, title: r.title, stale: r.stale, items: items)
        }
    }

    var balances: [(row: Row, item: Item)] {
        rows.flatMap { r in r.items.filter(\.isBalance).map { (r, $0) } }
    }
}
