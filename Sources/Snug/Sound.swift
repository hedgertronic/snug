import AudioToolbox
import AVFoundation

/// Snug's own sounds (sounds/*.caf, which build.py copies into the app's Resources), played as UI sounds: macOS plays them only while
/// System Settings > Sound > "Play user interface sound effects" is on, at the alert volume. Settings > General > Play sounds turns
/// them off; debug runs play none. A binary outside the app bundle has no sounds and plays none.
@MainActor
enum Sound: String {
    /// A capture landed on the pasteboard or disk (an image or Copy for Agent).
    case capture
    /// A recording's stream is about to start, and has stopped.
    case recordStart = "record-start"
    case recordStop = "record-stop"

    /// Set by debug runs.
    static var isMuted = false
    private static var loaded: [Sound: (id: SystemSoundID, length: Duration)] = [:]

    /// Plays the sound and returns how long it lasts; zero when it doesn't play.
    @discardableResult
    func play(defaults: UserDefaults) -> Duration {
        guard !Self.isMuted, defaults.bool(forKey: Pref.playSounds), let url = Bundle.main.url(forResource: rawValue, withExtension: "caf") else { return .zero }
        let sound = Self.loaded[self] ?? {
            var id: SystemSoundID = 0
            let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
            precondition(status == noErr, "\(rawValue).caf did not load: \(status)")
            let file = try! AVAudioFile(forReading: url)
            return (id, .seconds(Double(file.length) / file.processingFormat.sampleRate))
        }()
        Self.loaded[self] = sound
        AudioServicesPlaySystemSound(sound.id)
        return sound.length
    }
}
