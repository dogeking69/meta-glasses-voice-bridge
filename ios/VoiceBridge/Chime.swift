import AudioToolbox

/// Short audible cues, so you can tell what hands-free mode is doing without
/// looking at the phone. These follow the active audio route, which means they
/// play through the glasses rather than the handset.
enum Chime {
    /// The wake phrase was recognised — start speaking your command now.
    static func wakeDetected() {
        play(1113) // begin record
    }

    /// Your command was captured and is on its way to the Mac.
    static func captured() {
        play(1114) // end record
    }

    /// Hands-free listening started.
    static func sessionStarted() {
        play(1117) // ascending two-tone
    }

    /// Hands-free listening stopped.
    static func sessionStopped() {
        play(1118) // descending two-tone
    }

    private static func play(_ soundID: SystemSoundID) {
        AudioServicesPlaySystemSound(soundID)
    }
}
