import SwiftUI

/// Full-screen lyrics are an explicit action from the player's long-press menu.
/// The header remains a drag-to-dismiss surface while the words scroll freely.
struct LyricsSheet: View {
    var music: any MusicService
    var lyrics: LyricsState
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .contentShape(Rectangle())
                .gesture(dismissGesture)
            if let state = music.nowPlaying {
                content(state).frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 12) {
                    Scrubber(state: state, onSeek: music.seek)
                    TransportControls(state: state, music: music)
                }
                .padding(.horizontal, 26).padding(.top, 12).padding(.bottom, 16)
            } else {
                Text("Nothing playing").font(look.font(17)).foregroundStyle(look.palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .offset(y: dragOffset)
        .background { AmbientBackground().ignoresSafeArea() }
        .presentationBackground(look.palette.background)
        .onChange(of: music.nowPlaying, initial: true) { _, state in lyrics.loadCurrent(state) }
        .accessibilityAction(.escape) { dismiss() }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Capsule().fill(look.palette.muted.opacity(0.4))
                .frame(width: 36, height: 4).padding(.top, 8).padding(.bottom, 4)
                .accessibilityHidden(true)
            ZStack {
                Text("Lyrics").font(look.font(17, .semibold)).foregroundStyle(look.palette.text)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(look.font(17, .semibold))
                            .foregroundStyle(look.palette.text)
                            .frame(width: 44, height: 44)
                            .surface(look, in: Circle())
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Close lyrics")
                    .accessibilityIdentifier("lyrics.close")
                }
            }
            .padding(.horizontal, 16).frame(height: 52)
            if let state = music.nowPlaying {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.title).font(look.font(19, .semibold)).foregroundStyle(look.palette.text)
                    Text(state.artist).font(look.font(14)).foregroundStyle(look.palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26).padding(.vertical, 16)
            }
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard value.translation.height > abs(value.translation.width) else { return }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if dragOffset > 90 || (dragOffset > 20 && value.predictedEndTranslation.height > 220) {
                    dismiss()
                } else {
                    withAnimation(reduceMotion ? nil : look.animation) { dragOffset = 0 }
                }
            }
    }

    @ViewBuilder
    private func content(_ state: NowPlaying) -> some View {
        if state.isEpisode {
            message("Lyrics aren’t available", detail: "Lyrics are available for songs, not podcast episodes.")
        } else if lyrics.isLoading || lyrics.trackURI != state.trackURI {
            BarsLoader().accessibilityLabel("Loading lyrics")
        } else if let error = lyrics.error {
            message("Couldn’t load lyrics", detail: error, retry: true)
        } else if let document = lyrics.document, document.instrumental {
            message("Instrumental", detail: "There are no sung lyrics for this track.")
        } else if let document = lyrics.document, !document.lines.isEmpty {
            SyncedLyrics(document: document, state: state, seek: music.seek)
                .id(state.trackURI)
        } else if let document = lyrics.document, let plain = document.plainText {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Live timing isn’t available for this song.")
                        .font(look.font(13)).foregroundStyle(look.palette.muted)
                    Text(plain).font(look.font(24, .semibold)).foregroundStyle(look.palette.text)
                        .lineSpacing(10).textSelection(.enabled)
                    if let url = document.sourceURL { LyricsCredit(url: url) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(26)
            }
        } else {
            message("No lyrics found", detail: "Lyrics aren’t available for this version of the song yet.", retry: true)
        }
    }

    private func message(_ title: String, detail: String, retry: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "text.quote").font(look.font(30)).foregroundStyle(look.palette.muted)
            Text(title).font(look.display(24)).foregroundStyle(look.palette.text)
            Text(detail).font(look.font(15)).foregroundStyle(look.palette.muted).multilineTextAlignment(.center)
            if retry {
                Button("Try again") { lyrics.loadCurrent(music.nowPlaying, retry: true) }
                    .font(look.font(15, .semibold)).padding(.top, 6)
            }
        }
        .padding(26)
    }
}

private struct SyncedLyrics: View {
    var document: LyricsDocument
    var state: NowPlaying
    var seek: (Int) -> Void
    @Environment(\.look) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var following = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let active = document.activeLine(at: Double(state.position(at: timeline.date)) / 1000)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(document.lines) { line in
                            Button {
                                following = true
                                seek(Int(line.time * 1000))
                            } label: {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(look.display(28))
                                    .foregroundStyle(line.id == active ? look.palette.accent : look.palette.muted)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .animation(reduceMotion ? nil : look.lyricAnimation, value: active)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(line.text.isEmpty ? "Instrumental break" : line.text)
                            .accessibilityHint("Play from \(TrackRow.duration(Int(line.time * 1000)))")
                            .id(line.id)
                        }
                        if let url = document.sourceURL { LyricsCredit(url: url).padding(.top, 12) }
                    }
                    .padding(.horizontal, 26).padding(.vertical, 32)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { following = false }
                }
                .onChange(of: active, initial: true) { _, current in
                    guard following, let current else { return }
                    withAnimation(reduceMotion ? nil : look.lyricAnimation) { proxy.scrollTo(current, anchor: .center) }
                }
                .overlay(alignment: .bottom) {
                    if !following {
                        Button("Follow song", systemImage: "arrow.down.to.line") {
                            following = true
                            if let active {
                                withAnimation(reduceMotion ? nil : look.lyricAnimation) { proxy.scrollTo(active, anchor: .center) }
                            }
                        }
                        .font(look.font(14, .semibold))
                        .foregroundStyle(look.palette.text)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .surface(look, in: Capsule(), raised: true)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
    }
}

private struct LyricsCredit: View {
    var url: URL
    @Environment(\.look) private var look
    var body: some View {
        Link("Lyrics from LRCLIB ↗", destination: url)
            .font(look.font(12)).foregroundStyle(look.palette.muted)
    }
}
