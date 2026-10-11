import SwiftUI

/// One timed line beneath the artist. Its reserved space keeps the transport
/// controls still as short and long lines replace each other.
struct LiveLyrics: View {
    var state: NowPlaying
    var lyrics: LyricsState
    @Environment(\.look) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            Group {
                if lyrics.isLoading || lyrics.trackURI != state.trackURI {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(look.palette.muted)
                            .accessibilityHidden(true)
                        note("Finding lyrics…")
                    }
                    .accessibilityElement(children: .combine)
                } else if lyrics.error != nil {
                    note("Couldn’t load lyrics")
                } else if let document = lyrics.document {
                    if document.instrumental {
                        note("Instrumental")
                    } else if document.lines.isEmpty {
                        note("Live timing isn’t available")
                    } else {
                        let text = document.currentText(at: Double(state.position(at: timeline.date)) / 1000)
                        Text(text ?? "♪")
                            .font(look.font(22, .semibold))
                            .foregroundStyle(look.palette.text)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Keep the Text's identity so the old and new line
                            // crossfade within the same, stable layout.
                            .contentTransition(.opacity)
                            .animation(reduceMotion ? nil : look.lyricAnimation, value: text)
                            .accessibilityLabel(text ?? "Instrumental break")
                    }
                } else {
                    note("No lyrics available")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 80, alignment: .topLeading)
        .accessibilityIdentifier("player.currentLyric")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(look.font(15)).foregroundStyle(look.palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
