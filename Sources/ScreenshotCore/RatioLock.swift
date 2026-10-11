import CoreGraphics
import Foundation

/// The preset aspect ratios of P's menu, in menu order.
public enum RatioLock: CaseIterable, Sendable {
    case square, fourThree, threeTwo, sixteenTen, sixteenNine, twentyOneNine

    private var sides: (Int, Int) {
        switch self {
        case .square: (1, 1)
        case .fourThree: (4, 3)
        case .threeTwo: (3, 2)
        case .sixteenTen: (16, 10)
        case .sixteenNine: (16, 9)
        case .twentyOneNine: (21, 9)
        }
    }

    /// "16:9" when landscape, "9:16" when portrait.
    public func label(portrait: Bool) -> String {
        portrait ? "\(sides.1):\(sides.0)" : "\(sides.0):\(sides.1)"
    }

    /// Width over height: the label's order when landscape, reversed when portrait.
    public func ratio(portrait: Bool) -> CGFloat {
        let landscape = CGFloat(sides.0) / CGFloat(sides.1)
        return portrait ? 1 / landscape : landscape
    }

    /// A rectangle's aspect ratio as the size badge shows it: the standard ratio when `size` (rounded to whole pixels) is exactly one,
    /// e.g. "16:9"; the live ratio and the nearest standard within 3%, e.g. "1.62 ≈ 16:10"; else the live ratio alone, e.g. "2.00".
    /// The standards are 1:1, 5:4, 4:3, 3:2, 16:10, 16:9 and 21:9, and their portrait forms.
    public static func readout(for size: CGSize) -> String {
        let (width, height) = (Int(size.width.rounded()), Int(size.height.rounded()))
        guard width > 0, height > 0 else { return "" }
        let landscape = [(1, 1), (5, 4), (4, 3), (3, 2), (16, 10), (16, 9), (21, 9)]
        let standards = landscape + landscape.dropFirst().map { ($0.1, $0.0) }
        let live = Double(width) / Double(height)
        let nearest = standards.min { abs(log(live * Double($0.1) / Double($0.0))) < abs(log(live * Double($1.1) / Double($1.0))) }!
        if width * nearest.1 == height * nearest.0 { return "\(nearest.0):\(nearest.1)" }
        let formatted = String(format: "%.2f", live)
        return abs(log(live * Double(nearest.1) / Double(nearest.0))) <= 0.03 ? "\(formatted) ≈ \(nearest.0):\(nearest.1)" : formatted
    }
}
