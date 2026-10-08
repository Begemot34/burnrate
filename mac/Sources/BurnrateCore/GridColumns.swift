// Card grid arithmetic shared by the window's layout and its first-launch size.
import Foundation

public enum GridColumns {
    /// As many columns as fit, with rows kept even: 5 cards where 4 fit go
    /// 3 + 2, not 4 + 1 with a lone card under an empty row.
    public static func balanced(fit: Int, count: Int) -> Int {
        guard count > 0 else { return max(1, fit) }
        let cols = max(1, min(fit, count))
        let rows = (count + cols - 1) / cols
        return (count + rows - 1) / rows
    }
}
