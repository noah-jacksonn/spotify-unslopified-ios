import Foundation

/// Original sample words for layout and timing checks; never queries a provider.
extension DemoMusic {
    static func sampleLyrics() -> LyricsDocument {
        LyricsDocument(lines: LRCParser.parse(sampleLyricLRC), instrumental: false, sourceURL: nil)
    }
}

extension LyricsState {
    func loadCurrent(_ state: NowPlaying?, retry: Bool = false) {
        let sample = state?.trackURI.hasPrefix("demo:") == true ? DemoMusic.sampleLyrics() : nil
        load(for: state, sample: sample, retry: retry)
    }
}
