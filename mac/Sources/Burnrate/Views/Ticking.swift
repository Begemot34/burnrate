import BurnrateCore
import SwiftUI

/// Re-renders its content once per wall-clock second with the server time in ms.
/// Only text that really ticks sits inside one, the rest updates on data.
struct Ticking<Content: View>: View {
    @Environment(Store.self) private var store
    @ViewBuilder let content: (Int64) -> Content

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), by: 1)) { ctx in
            content(store.nowMs(ctx.date))
        }
    }
}
