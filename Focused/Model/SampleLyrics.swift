import Foundation

/// Original sample words for layout and timing checks; never queries a provider.
extension DemoMusic {
    static func sampleLyrics() -> LyricsDocument {
        LyricsDocument(lines: LRCParser.parse("""
        [00:00.00]Morning light across the floor
        [00:05.00]An open window, an open door
        [00:10.00]Leave the hurry far behind
        [00:15.00]Take a little time
        [00:20.00]
        [00:25.00]Every road can bend again
        [00:30.00]Every sky can clear
        [00:35.00]There is room to wander
        [00:40.00]There is music here
        """), instrumental: false, sourceURL: nil)
    }
}

extension LyricsState {
    func loadCurrent(_ state: NowPlaying?, retry: Bool = false) {
        let sample = state?.trackURI.hasPrefix("demo:") == true ? DemoMusic.sampleLyrics() : nil
        load(for: state, sample: sample, retry: retry)
    }
}
