import SwiftUI
import UniformTypeIdentifiers

struct ImportedPlaylistRoute: Hashable, Identifiable { let id: String }

struct ImportedPlaylistHomeEntry: View {
    let playlist: ImportedPlaylist
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look

    var body: some View {
        NavigationLink(value: ImportedPlaylistRoute(id: playlist.id)) {
            HStack(spacing: 16) {
                ArtworkView(artwork: model.localLibrary.artwork(for: playlist.id))
                    .frame(width: 88, height: 88).artClip(look, size: 88)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name).font(look.font(18, .semibold)).foregroundStyle(look.palette.text)
                    Text("\(model.localLibrary.songs(in: playlist.id).count) songs")
                        .font(look.font(14)).foregroundStyle(look.palette.muted)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .importedPlaylistActions(playlist)
        .accessibilityIdentifier("home.imported.\(playlist.id)")
    }
}

struct ImportedPlaylistView: View {
    let playlistID: String
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var showsImporter = false
    @State private var showsFilters = false
    @State private var filtersDate = false
    @State private var fromDate = Calendar.current.startOfDay(for: Date())
    @State private var throughDate = Date()
    @State private var editing: LocalSong?
    @State private var importError: String?
    @State private var editsCover = false

    private var playlist: ImportedPlaylist? { model.localLibrary.playlist(id: playlistID) }
    private var title: String { playlist?.name ?? "Imported playlist" }

    private var songs: [LocalSong] {
        let all = model.localLibrary.songs(in: playlistID)
        guard filtersDate else { return all }
        let start = Calendar.current.startOfDay(for: fromDate)
        let end = Calendar.current.date(byAdding: .day, value: 1,
            to: Calendar.current.startOfDay(for: throughDate)) ?? throughDate
        return all.filter { song in
            guard let date = song.createdAt else { return false }
            return date >= start && date < end
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HeaderCover(artwork: model.localLibrary.artwork(for: playlistID))
                    .contextMenu {
                        Button("Change cover", systemImage: "photo") { editsCover = true }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 14)
                    .accessibilityIdentifier("suno.cover")
                HStack {
                    PlayPill(title: "Play", systemName: "play.fill") {
                        model.music?.play(.tracks(songs.map(\.uri)))
                    }
                    .disabled(songs.isEmpty)
                    Button { model.music?.shuffle(.tracks(songs.map(\.uri))) } label: {
                        Image(systemName: "shuffle").font(look.font(20)).frame(width: 44, height: 44)
                    }
                    .disabled(songs.isEmpty)
                    Spacer()
                    Button { showsFilters = true } label: {
                        Image(systemName: "calendar")
                            .font(look.font(20)).frame(width: 44, height: 44)
                            .foregroundStyle(filtersDate ? look.palette.accent : look.palette.muted)
                    }
                    .accessibilityLabel("Filter by date")
                    .accessibilityValue(filtersDate ? "Active" : "All dates")
                    .accessibilityIdentifier("suno.dateFilter")
                }
                if model.localLibrary.isImporting {
                    HStack { ProgressView(); Text("Importing songs…").font(look.font(15)) }
                }
                if let error = model.localLibrary.error {
                    Text(error).font(look.font(15)).foregroundStyle(look.palette.muted)
                    Button("Try again") { model.localLibrary.reload() }
                }
                if songs.isEmpty && !model.localLibrary.isImporting {
                    ContentUnavailableView(filtersDate ? "No songs in this date range" : "No songs yet",
                        systemImage: "music.note",
                        description: Text(filtersDate ? "Choose another range or clear the filter." : "Import downloaded songs to listen offline."))
                    if filtersDate { Button("Clear filter") { filtersDate = false } }
                    else {
                        Button("Import songs", systemImage: "plus") { showsImporter = true }
                            .font(look.font(16, .medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                ForEach(songs) { song in
                    HStack(spacing: 4) {
                        TrackRow(track: song.track, showsAddMenu: false) {
                            let start = songs.firstIndex(where: { $0.id == song.id }) ?? 0
                            model.music?.play(.tracks(Array(songs[start...]).map(\.uri)))
                        }
                        Button { editing = song } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Edit details for \(song.title)")
                    }
                }
            }
            .padding(look.margin)
        }
        .pageBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import songs", systemImage: "plus") { showsImporter = true }
                    .disabled(model.localLibrary.isImporting)
                    .accessibilityIdentifier("suno.import")
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task {
                    let result = await model.localLibrary.importAudio(urls, into: playlistID)
                    model.show("Imported \(result.added) songs")
                    if !result.failures.isEmpty { importError = result.failures.joined(separator: "\n") }
                }
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsFilters) {
            NavigationStack {
                Form {
                    Toggle("Filter by creation date", isOn: $filtersDate)
                    if filtersDate {
                        DatePicker("From", selection: $fromDate, in: ...throughDate, displayedComponents: .date)
                        DatePicker("Through", selection: $throughDate, in: fromDate..., displayedComponents: .date)
                        Text("Songs with an unknown creation date are excluded.").font(.footnote)
                    }
                    Button("Clear filter") { filtersDate = false }
                }
                .navigationTitle("Date filter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { CloseToolbarItem { showsFilters = false } }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $editing) { song in
            ImportedSongEditor(song: song).environment(\.look, look)
        }
        .sheet(isPresented: $editsCover) {
            CoverEditor(title: title, artwork: model.localLibrary.artwork(for: playlistID)) { jpeg in
                try model.localLibrary.saveCover(jpeg, playlistID: playlistID)
            }
            .environment(\.look, look)
        }
        .alert("Import incomplete", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }
}

private struct ImportedSongEditor: View {
    @State var song: LocalSong
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var source = ""
    @State private var lyrics = ""
    @State private var hasDate = false
    @State private var date = Date()
    @State private var showsLyricsImporter = false
    @State private var error: String?
    @State private var editsCover = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Song") {
                    Button("Change artwork", systemImage: "photo") { editsCover = true }
                    TextField("Title", text: $song.title)
                    TextField("Artist", text: $song.artist)
                    TextField("Source link", text: $source).keyboardType(.URL).textInputAutocapitalization(.never)
                    Toggle("Creation date known", isOn: $hasDate)
                    if hasDate { DatePicker("Created", selection: $date, displayedComponents: .date) }
                }
                Section("Lyrics") {
                    Button("Import timed lyrics", systemImage: "doc") { showsLyricsImporter = true }
                    TextEditor(text: $lyrics).frame(minHeight: 180)
                    Text("Paste lyrics or import an LRC file for synchronized lines.").font(.footnote)
                }
                if let error { Text(error).foregroundStyle(look.palette.muted) }
            }
            .navigationTitle("Song details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                source = song.sourceURL?.absoluteString ?? ""
                lyrics = song.lyrics ?? ""
                hasDate = song.createdAt != nil
                date = song.createdAt ?? Date()
            }
            .sheet(isPresented: $editsCover, onDismiss: {
                song.artworkFile = model.localLibrary.song(uri: song.uri)?.artworkFile
            }) {
                CoverEditor(title: song.title, artwork: Artwork(url: song.artworkURL, seed: nil)) { jpeg in
                    try model.localLibrary.saveCover(jpeg, for: song)
                    (model.music as? CombinedMusic)?.local.refresh(songs: model.localLibrary.songs)
                }
                .environment(\.look, look)
            }
            .fileImporter(isPresented: $showsLyricsImporter, allowedContentTypes: [.data]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let text = try String(contentsOf: url, encoding: .utf8)
                    guard !LRCParser.parse(text).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    lyrics = text
                } catch { self.error = "Couldn't read timed lyrics. Choose an LRC text file." }
            }
        }
    }

    private func save() {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let url = URL(string: trimmed), url.scheme == "https",
                  url.host != nil else {
                error = "Enter a valid link beginning with https://."
                return
            }
            song.sourceURL = url
        } else { song.sourceURL = nil }
        song.createdAt = hasDate ? date : nil
        song.lyrics = lyrics.isEmpty ? nil : lyrics
        do {
            try model.localLibrary.update(song)
            (model.music as? CombinedMusic)?.local.refresh(songs: model.localLibrary.songs)
            model.lyrics.loadCurrent(model.music?.nowPlaying, retry: true)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
