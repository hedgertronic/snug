import ApplicationServices
import Foundation

/// Typed reads of the values another app's accessibility answers with. Each checks that the answer is an `AXValue` of the expected
/// type before unpacking it, and that its numbers are finite, so a wrong or malformed answer reads as nil instead of being unpacked as
/// something else.
public enum AXValues {
    public static func point(_ raw: CFTypeRef?) -> CGPoint? {
        var point = CGPoint.zero
        guard let value = value(raw, .cgPoint), AXValueGetValue(value, .cgPoint, &point), point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    public static func size(_ raw: CFTypeRef?) -> CGSize? {
        var size = CGSize.zero
        guard let value = value(raw, .cgSize), AXValueGetValue(value, .cgSize, &size), size.width.isFinite, size.height.isFinite else { return nil }
        return size
    }

    public static func rect(_ raw: CFTypeRef?) -> CGRect? {
        var rect = CGRect.zero
        guard let value = value(raw, .cgRect), AXValueGetValue(value, .cgRect, &rect),
              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        return rect
    }

    public static func range(_ raw: CFTypeRef?) -> CFRange? {
        var range = CFRange()
        guard let value = value(raw, .cfRange), AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    /// `range` as an `NSRange` when it lies inside a string of `length` UTF-16 units: no negative location or length, and an end at or
    /// before `length`, checked by subtraction so a huge location or length cannot overflow.
    public static func range(_ range: CFRange, within length: Int) -> NSRange? {
        guard range.location >= 0, range.length >= 0, range.location <= length, range.length <= length - range.location else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// A nonnegative whole number answer, as `AXLineForIndex` gives.
    public static func index(_ raw: CFTypeRef?) -> Int? {
        guard let raw, CFGetTypeID(raw) == CFNumberGetTypeID(), let number = (raw as? NSNumber)?.intValue, number >= 0 else { return nil }
        return number
    }

    /// An element answer, as a parent or a label element is.
    public static func element(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        // The type ID check makes the cast certain.
        return (raw as! AXUIElement)
    }

    private static func value(_ raw: CFTypeRef?, _ type: AXValueType) -> AXValue? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        // The type ID check makes the cast certain.
        let value = raw as! AXValue
        return AXValueGetType(value) == type ? value : nil
    }
}
