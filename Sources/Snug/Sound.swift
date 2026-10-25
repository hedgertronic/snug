import AudioToolbox
import AVFoundation

/// The sounds macOS plays for its own screenshots and recordings, loaded from the system at runtime (none ship with Snug) and played as
/// UI sounds: macOS plays them only while System Settings > Sound > "Play user interface sound effects" is on, at the alert volume.
/// Settings > General > Play sounds turns them off; debug runs play none. The folder is not API: a macOS without a file plays nothing.
@MainActor
enum Sound: String {
    /// A capture landed on the pasteboard or disk (an image or Copy for Agent).
    case capture = "Screen Capture.aif"
    /// A recording's stream is about to start, and has stopped.
    case recordStart = "begin_record.caf"
    case recordStop = "end_record.caf"

    /// Set by debug runs.
    static var isMuted = false
    private static let folder = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system")
    private static var loaded: [Sound: (id: SystemSoundID, length: Duration)] = [:]

    /// Plays the sound and returns how long it lasts; zero when it doesn't play.
    @discardableResult
    func play(defaults: UserDefaults) -> Duration {
        let url = Self.folder.appending(path: rawValue)
        guard !Self.isMuted, defaults.bool(forKey: Pref.playSounds), FileManager.default.fileExists(atPath: url.path) else { return .zero }
        let sound = Self.loaded[self] ?? {
            var id: SystemSoundID = 0
            let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
            precondition(status == noErr, "\(rawValue) did not load: \(status)")
            let file = try! AVAudioFile(forReading: url)
            return (id, .seconds(Double(file.length) / file.processingFormat.sampleRate))
        }()
        Self.loaded[self] = sound
        AudioServicesPlaySystemSound(sound.id)
        return sound.length
    }
}
