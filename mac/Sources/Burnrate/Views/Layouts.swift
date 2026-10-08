import BurnrateCore
import SwiftUI

/// CSS grid `repeat(auto-fit, minmax(330px, 1fr))` with 1 pt gaps, rows kept
/// even: columns share the width, every cell in a row gets the row's height.
struct CardGrid: Layout {
    var spacing: CGFloat = 1
    var minWidth: CGFloat = 330

    private func columns(_ width: CGFloat, count: Int) -> Int {
        GridColumns.balanced(fit: Int((width + spacing) / (minWidth + spacing)), count: count)
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (colW: CGFloat, heights: [CGFloat], cols: Int) {
        let cols = columns(width, count: subviews.count)
        let colW = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        var heights: [CGFloat] = []
        for start in stride(from: 0, to: subviews.count, by: cols) {
            let h =
                subviews[start..<min(start + cols, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height }.max() ?? 0
            heights.append(h)
        }
        return (colW, heights, cols)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minWidth * 3 + spacing * 2)
        let r = rows(width, subviews)
        let h = r.heights.reduce(0, +) + spacing * CGFloat(max(0, r.heights.count - 1))
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(bounds.width, subviews)
        var y = bounds.minY
        for (row, h) in r.heights.enumerated() {
            for col in 0..<r.cols {
                let i = row * r.cols + col
                guard i < subviews.count else { break }
                let x = bounds.minX + CGFloat(col) * (r.colW + spacing)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: r.colW, height: h))
            }
            y += h + spacing
        }
    }
}
