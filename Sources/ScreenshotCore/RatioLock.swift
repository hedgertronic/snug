import CoreGraphics

/// A fixed aspect ratio for new drags and handle drags, cycled with P. Free is `nil`.
public enum RatioLock: CaseIterable, Sendable {
    case square, fourThree, threeTwo, sixteenNine

    /// "1:1", "4:3", "3:2", "16:9".
    public var label: String {
        switch self {
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        }
    }

    /// Width over height: the label's order when landscape, reversed when portrait.
    public func ratio(portrait: Bool) -> CGFloat {
        let landscape: CGFloat = switch self {
        case .square: 1
        case .fourThree: 4.0 / 3
        case .threeTwo: 3.0 / 2
        case .sixteenNine: 16.0 / 9
        }
        return portrait ? 1 / landscape : landscape
    }

    /// The lock after `current` when P is pressed: Free, 1:1, 4:3, 3:2, 16:9, then Free.
    public static func next(after current: RatioLock?) -> RatioLock? {
        guard let current else { return allCases[0] }
        let index = allCases.firstIndex(of: current)! + 1
        return index < allCases.count ? allCases[index] : nil
    }
}
