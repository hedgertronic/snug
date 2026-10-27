/// Bounds on the cut-out preview's work: each choice holds a crop-sized RGBA image and gray-and-alpha outline (6 bytes a pixel), so
/// the crop's size and the number of choices set its memory.
public enum CutoutLimits {
    /// The largest crop cut out, in pixels.
    public static let maximumPixels = 50_000_000
    /// The most bytes all of one preview's choices hold.
    public static let maximumBytes = 768 * 1024 * 1024
    /// The most instances offered alone, after the choice with all of them.
    public static let maximumInstances = 8
    static let bytesPerPixel = 6

    /// How many choices to make for `instances` foreground instances in a crop of `pixels`: all of them together, then, when there are
    /// several, each alone (at most `maximumInstances`) while they fit `maximumBytes`. Nil for a crop over `maximumPixels`.
    public static func choices(instances: Int, pixels: Int) -> Int? {
        guard pixels > 0, pixels <= maximumPixels else { return nil }
        guard instances > 1 else { return min(instances, 1) }
        let fitting = max(1, maximumBytes / (pixels * bytesPerPixel))
        return min(1 + min(instances, maximumInstances), fitting)
    }
}
