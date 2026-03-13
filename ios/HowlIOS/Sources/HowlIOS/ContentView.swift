import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    var body: some View {
        TabView {
            PlayerView()
                .tabItem {
                    Label("Player", systemImage: "play.circle")
                }

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "folder")
                }

            GeneratorView()
                .tabItem {
                    Label("Generator", systemImage: "waveform.path.ecg")
                }

            ActivitiesView()
                .tabItem {
                    Label("Activities", systemImage: "sparkles")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

private struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLibraryImporter = false
    @State private var searchText = ""
    @State private var showCreatePlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var pendingPlaylistEntry: AppModel.LibraryEntry?

    private var filteredEntries: [AppModel.LibraryEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.libraryEntries }
        return model.libraryEntries.filter {
            $0.relativePath.localizedCaseInsensitiveContains(trimmed)
                || $0.displayRelativePath.localizedCaseInsensitiveContains(trimmed)
                || $0.displayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var favoriteEntries: [AppModel.LibraryEntry] {
        filteredEntries.filter { model.isFavorite($0) }.sorted(by: librarySort)
    }

    private var nonFavoriteEntries: [AppModel.LibraryEntry] {
        filteredEntries.filter { !model.isFavorite($0) }
    }

    private var libraryTree: AppModel.LibraryTree {
        model.libraryTree(for: nonFavoriteEntries)
    }

    private var isSearching: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Library") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.libraryFolderName)
                            .font(.headline)
                        Text(model.libraryStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if model.isRefreshingLibrary {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if let error = model.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Button("Add Zip or Files") {
                        showLibraryImporter = true
                    }
                    .buttonStyle(.borderedProminent)

                    Button("New Playlist") {
                        pendingPlaylistEntry = nil
                        newPlaylistName = ""
                        showCreatePlaylistAlert = true
                    }
                    .buttonStyle(.bordered)

                    if !model.libraryEntries.isEmpty {
                        Button("Refresh Library") {
                            model.refreshLibrary()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isRefreshingLibrary)
                    }
                }

                if filteredEntries.isEmpty {
                    Section("Files") {
                        Text("No stored `.hwl` or `.funscript` files yet. Add a zip, or add files from OneDrive or Files, and Howl will keep local copies here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !favoriteEntries.isEmpty {
                        Section("Favorites (\(favoriteEntries.count))") {
                            ForEach(favoriteEntries) { entry in
                                LibraryEntryRow(entry: entry, currentPlaylistID: nil) {
                                    beginCreatePlaylist(with: $0)
                                }
                            }
                        }
                    }

                    if !isSearching && !model.playlists.isEmpty {
                        Section("Playlists (\(model.playlists.count))") {
                            ForEach(model.playlists) { playlist in
                                PlaylistDisclosureRow(playlist: playlist) {
                                    beginCreatePlaylist(with: $0)
                                }
                            }
                        }
                    }

                    if isSearching {
                        Section("Search Results (\(nonFavoriteEntries.count))") {
                            ForEach(nonFavoriteEntries.sorted(by: librarySort)) { entry in
                                LibraryEntryRow(entry: entry, currentPlaylistID: nil) {
                                    beginCreatePlaylist(with: $0)
                                }
                            }
                        }
                    } else {
                        if !libraryTree.rootFiles.isEmpty {
                            Section("Root Files (\(libraryTree.rootFiles.count))") {
                                ForEach(libraryTree.rootFiles) { entry in
                                    LibraryEntryRow(entry: entry, currentPlaylistID: nil) {
                                        beginCreatePlaylist(with: $0)
                                    }
                                }
                            }
                        }

                        ForEach(libraryTree.folders) { folder in
                            Section {
                                LibraryFolderDisclosureRow(folder: folder) {
                                    beginCreatePlaylist(with: $0)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search files")
            .alert("New Playlist", isPresented: $showCreatePlaylistAlert) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {
                    pendingPlaylistEntry = nil
                }
                Button("Create") {
                    guard let playlist = model.createPlaylist(named: newPlaylistName) else { return }
                    model.setPlaylistExpanded(true, for: playlist.id)
                    if let entry = pendingPlaylistEntry {
                        model.addEntry(entry, toPlaylistID: playlist.id)
                    }
                    pendingPlaylistEntry = nil
                    newPlaylistName = ""
                }
            } message: {
                Text("Playlists are saved collections inside Howl.")
            }
            .sheet(isPresented: $showLibraryImporter) {
                ScriptPickerSheet(
                    allowsMultipleSelection: true,
                    contentTypes: [.howlZipArchive, .howlHWL, .howlFunscript, .json, .data]
                ) { result in
                    switch result {
                    case .success(let urls):
                        model.importFilesToLibrary(from: urls)
                    case .failure(let error):
                        if error.localizedDescription.isEmpty == false {
                            model.lastError = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private func beginCreatePlaylist(with entry: AppModel.LibraryEntry?) {
        pendingPlaylistEntry = entry
        newPlaylistName = ""
        showCreatePlaylistAlert = true
    }

    private func librarySort(lhs: AppModel.LibraryEntry, rhs: AppModel.LibraryEntry) -> Bool {
        lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
    }
}

private struct PlaylistDisclosureRow: View {
    @EnvironmentObject private var model: AppModel
    let playlist: AppModel.Playlist
    let onCreatePlaylist: (AppModel.LibraryEntry) -> Void

    private var entries: [AppModel.LibraryEntry] {
        model.entries(for: playlist)
    }

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { model.isPlaylistExpanded(playlist.id) },
                set: { model.setPlaylistExpanded($0, for: playlist.id) }
            )
        ) {
            if entries.isEmpty {
                Text("No imported files in this playlist yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    LibraryEntryRow(entry: entry, currentPlaylistID: playlist.id, onCreatePlaylist: onCreatePlaylist)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .foregroundStyle(.secondary)
                Text(playlist.name)
                Spacer()
                Text("\(entries.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Delete Playlist", role: .destructive) {
                model.deletePlaylist(playlist)
            }
        }
    }
}

private struct LibraryFolderDisclosureRow: View {
    @EnvironmentObject private var model: AppModel
    let folder: AppModel.LibraryFolderNode
    let onCreatePlaylist: (AppModel.LibraryEntry) -> Void

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { model.isLibraryFolderExpanded(folder.relativePath) },
                set: { model.setLibraryFolderExpanded($0, for: folder.relativePath) }
            )
        ) {
            ForEach(folder.files) { entry in
                LibraryEntryRow(entry: entry, currentPlaylistID: nil, onCreatePlaylist: onCreatePlaylist)
            }

            ForEach(folder.folders) { childFolder in
                LibraryFolderDisclosureRow(folder: childFolder, onCreatePlaylist: onCreatePlaylist)
                    .padding(.leading, 8)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(folder.name)
                Spacer()
                Text("\(folder.totalFileCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ScriptPickerSheet: UIViewControllerRepresentable {
    let allowsMultipleSelection: Bool
    let contentTypes: [UTType]
    let onComplete: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onComplete: (Result<[URL], Error>) -> Void

        init(onComplete: @escaping (Result<[URL], Error>) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completeSelection(urls)
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
            completeSelection([url])
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // No-op. Cancelling the picker should not look like an app error.
        }

        private func completeSelection(_ urls: [URL]) {
            guard urls.isEmpty == false else { return }
            onComplete(.success(urls))
        }
    }
}

private struct LibraryEntryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: AppModel.LibraryEntry
    let currentPlaylistID: UUID?
    let onCreatePlaylist: (AppModel.LibraryEntry) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScriptWaveformThumbnail(preview: model.waveformPreview(for: entry))
                .frame(width: 96, height: 52)
                .task(id: entry.relativePath) {
                    model.ensureWaveformPreview(for: entry)
                    model.ensureAnalysisSummary(for: entry)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .foregroundStyle(.primary)
                Text(entry.displayRelativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let modifiedAt = entry.modifiedAt {
                    Text(modifiedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    if let summary = model.analysisSummary(for: entry) {
                        ForEach(Array(summary.tags.prefix(2)), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tagColor(tag).opacity(0.14), in: Capsule())
                                .foregroundStyle(tagColor(tag))
                        }
                    } else if let preview = model.waveformPreview(for: entry), preview.channelsDiffer {
                        Text("A/B Split")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                            .foregroundStyle(.orange)
                    }

                    if model.isLoadedLibraryEntry(entry) {
                        Text("Loaded")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Spacer()

            if model.isLoadedLibraryEntry(entry) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }

            Button {
                model.toggleFavorite(for: entry)
            } label: {
                Image(systemName: model.isFavorite(entry) ? "star.fill" : "star")
                    .foregroundStyle(model.isFavorite(entry) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    onCreatePlaylist(entry)
                } label: {
                    Label("New Playlist", systemImage: "plus.rectangle.on.folder")
                }

                if let summary = model.analysisSummary(for: entry), summary.supportsDerivedCopies {
                    Menu {
                        ForEach(HWLDerivedProfile.allCases) { profile in
                            Button(profile.rawValue) {
                                model.createDerivedCopy(from: entry, profile: profile)
                            }
                        }
                    } label: {
                        Label("Create Derived Copy", systemImage: "wand.and.stars")
                    }
                }

                ForEach(model.playlists) { playlist in
                    if model.playlistContains(entry, in: playlist) {
                        Button {
                            model.removeEntry(entry, fromPlaylistID: playlist.id)
                        } label: {
                            Label("Remove from \(playlist.name)", systemImage: "minus.circle")
                        }
                    } else {
                        Button {
                            model.addEntry(entry, toPlaylistID: playlist.id)
                            model.setPlaylistExpanded(true, for: playlist.id)
                        } label: {
                            Label("Add to \(playlist.name)", systemImage: "text.badge.plus")
                        }
                    }
                }

                if let currentPlaylistID {
                    Button(role: .destructive) {
                        model.removeEntry(entry, fromPlaylistID: currentPlaylistID)
                    } label: {
                        Label("Remove from This Playlist", systemImage: "trash")
                    }
                }

                Button(role: .destructive) {
                    model.deleteLibraryEntry(entry)
                } label: {
                    Label("Delete File", systemImage: "trash.fill")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .listRowBackground(model.isLoadedLibraryEntry(entry) ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                model.deleteLibraryEntry(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onTapGesture {
            model.loadLibraryEntry(entry, playlistID: currentPlaylistID)
        }
    }

    private func tagColor(_ tag: String) -> Color {
        switch tag {
        case "A/B Split":
            return .orange
        case "Spiky":
            return .red
        case "Dense":
            return .blue
        case "Sparse", "Gentle":
            return .green
        default:
            return .secondary
        }
    }
}

private struct ScriptWaveformThumbnail: View {
    let preview: AppModel.LibraryWaveformPreview?

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.secondary.opacity(0.08))
            .overlay {
                if let preview {
                    VStack(spacing: 4) {
                        WaveformChannelStrip(
                            label: "A",
                            amplitude: preview.amplitudeA,
                            frequency: preview.frequencyA,
                            tint: .orange
                        )
                        WaveformChannelStrip(
                            label: "B",
                            amplitude: preview.amplitudeB,
                            frequency: preview.frequencyB,
                            tint: .blue
                        )
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                } else {
                    VStack(spacing: 6) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 8)
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: 8)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct WaveformChannelStrip: View {
    let label: String
    let amplitude: [Float]
    let frequency: [Float]
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 8)

            GeometryReader { geometry in
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                    }
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)

                    waveformPath(for: amplitude, in: geometry.size)
                        .stroke(tint.opacity(0.95), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                    waveformPath(for: frequency, in: geometry.size)
                        .stroke(tint.opacity(0.35), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func waveformPath(for samples: [Float], in size: CGSize) -> Path {
        var path = Path()
        guard let first = samples.first else { return path }
        let maxX = max(size.width, 1)
        let maxY = max(size.height, 1)

        for (index, sample) in samples.enumerated() {
            let progress = samples.count == 1 ? 0 : CGFloat(index) / CGFloat(samples.count - 1)
            let x = progress * maxX
            let y = (1 - CGFloat(max(0, min(sample, 1)))) * maxY
            if index == 0 {
                let startY = (1 - CGFloat(max(0, min(first, 1)))) * maxY
                path.move(to: CGPoint(x: x, y: startY))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
    }
}

private struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var bleManager: CoyoteBluetoothManager
    @EnvironmentObject private var audioEngine: AudioOutputEngine

    private var favoriteEntries: [AppModel.LibraryEntry] {
        model.favoriteLibraryEntries
    }

    private var coyoteButtonTitle: String {
        switch bleManager.state {
        case .ready, .connecting, .discovering, .scanning, .subscribing, .syncing:
            return "Disconnect Coyote"
        case .disconnected, .unavailable:
            return "Pair with Coyote"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.sourceName)
                            .font(.title2.weight(.semibold))
                        Text(model.statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Output: \(model.outputMode.rawValue)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                        Text("Coyote: \(bleManager.state.rawValue)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(bleManager.isReady ? .green : .secondary)
                        if let playlistName = model.currentPlaylistName {
                            Text("Playlist: \(playlistName)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        if model.outputMode == .audio {
                            Text("Audio: \(audioEngine.statusSummary)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text("Route: \(audioEngine.routeSummary)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button(coyoteButtonTitle) {
                            if bleManager.state == .disconnected || bleManager.state == .unavailable {
                                bleManager.connectOrScan()
                            } else {
                                bleManager.disconnect()
                            }
                        }
                        .buttonStyle(.bordered)

                        if let batteryLevel = bleManager.batteryLevel {
                            Text("Battery \(batteryLevel)%")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let playlistName = model.currentPlaylistName {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Playlist")
                                        .font(.headline)
                                    Text(playlistName)
                                        .font(.subheadline.weight(.semibold))
                                    if let currentIndex = model.currentPlaylistIndex {
                                        Text("Track \(currentIndex + 1) of \(model.currentPlaylistEntries.count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    Button {
                                        model.loadPreviousPlaylistEntry()
                                    } label: {
                                        Image(systemName: "backward.fill")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!model.canLoadPreviousPlaylistEntry)

                                    Button {
                                        model.loadNextPlaylistEntry()
                                    } label: {
                                        Image(systemName: "forward.fill")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!model.canLoadNextPlaylistEntry)
                                }
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(model.currentPlaylistEntries) { entry in
                                        Button {
                                            model.loadPlaylistEntry(entry)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(entry.displayName)
                                                    .font(.caption.weight(.semibold))
                                                    .lineLimit(1)
                                                if let preview = model.waveformPreview(for: entry) {
                                                    Text(preview.channelsDiffer ? "A/B Split" : "A/B Matched")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                } else {
                                                    Text("Preview loading")
                                                        .font(.caption2)
                                                        .foregroundStyle(.tertiary)
                                                }
                                            }
                                            .frame(width: 132, alignment: .leading)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .fill(model.isLoadedLibraryEntry(entry) ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .stroke(model.isLoadedLibraryEntry(entry) ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .task(id: entry.relativePath) {
                                            model.ensureWaveformPreview(for: entry)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if let duration = model.duration {
                        VStack(alignment: .leading, spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { model.position },
                                    set: { model.seek(to: $0) }
                                ),
                                in: 0...max(duration, 0.01)
                            )
                            HStack {
                                Text(timeString(model.position))
                                Spacer()
                                Text(timeString(duration))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button(model.isPlaying ? "Stop" : "Play") {
                            model.togglePlayback()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Use Generator") {
                            model.loadGenerator(playImmediately: true)
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Live Pulse")
                            .font(.headline)
                        PulseMetricsView(pulse: model.currentPulse)
                        PulseHistoryView(pulses: model.recentPulses)
                            .frame(height: 120)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Power")
                            .font(.headline)
                        PowerControlRow(
                            title: "Channel A",
                            value: Binding(
                                get: { model.powerA },
                                set: { model.powerA = $0 }
                            ),
                            range: model.powerSliderRange,
                            onDecrement: { model.adjustPowerA(by: -1) },
                            onIncrement: { model.adjustPowerA(by: 1) }
                        )
                        PowerControlRow(
                            title: "Channel B",
                            value: Binding(
                                get: { model.powerB },
                                set: { model.powerB = $0 }
                            ),
                            range: model.powerSliderRange,
                            onDecrement: { model.adjustPowerB(by: -1) },
                            onIncrement: { model.adjustPowerB(by: 1) }
                        )
                        Text("Power slider ceiling: \(model.powerSliderCeiling)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !favoriteEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Starred Files")
                                    .font(.headline)
                                Spacer()
                                Text("\(favoriteEntries.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(favoriteEntries) { entry in
                                        Button {
                                            model.loadFavoriteEntry(entry)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                ScriptWaveformThumbnail(preview: model.waveformPreview(for: entry))
                                                    .frame(width: 148, height: 64)
                                                Text(entry.displayName)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text(entry.displayRelativePath)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            .frame(width: 156, alignment: .leading)
                                            .padding(12)
                                            .background(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .fill(model.isLoadedLibraryEntry(entry) ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .stroke(model.isLoadedLibraryEntry(entry) ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .task(id: entry.relativePath) {
                                            model.ensureWaveformPreview(for: entry)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if let error = model.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Howl")
        }
    }
}

private struct GeneratorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Global") {
                    LabeledSlider(
                        title: "Speed",
                        value: Binding(
                            get: { model.generatorConfig.speed },
                            set: { model.updateGeneratorSpeed($0) }
                        ),
                        range: 0.1...2.0,
                        format: "%.2f"
                    )

                    Button("Load Generator") {
                        model.loadGenerator(playImmediately: false)
                    }

                    Button("Play Generator") {
                        model.loadGenerator(playImmediately: true)
                    }
                }

                ForEach(GeneratorChannelID.allCases) { channelID in
                    Section(channelID.label) {
                        Picker("Amplitude Shape", selection: stringBinding(channelID, \.amplitudeShape)) {
                            ForEach(model.shapeNames, id: \.self) { shapeName in
                                Text(shapeName).tag(shapeName)
                            }
                        }

                        Picker("Frequency Shape", selection: stringBinding(channelID, \.frequencyShape)) {
                            ForEach(model.shapeNames, id: \.self) { shapeName in
                                Text(shapeName).tag(shapeName)
                            }
                        }

                        LabeledSlider(
                            title: "Min Power",
                            value: doubleBinding(channelID, \.minAmplitude),
                            range: 0...1,
                            format: "%.2f"
                        )
                        LabeledSlider(
                            title: "Max Power",
                            value: doubleBinding(channelID, \.maxAmplitude),
                            range: 0...1,
                            format: "%.2f"
                        )
                        LabeledSlider(
                            title: "Min Frequency",
                            value: doubleBinding(channelID, \.minFrequencyNormalized),
                            range: 0...1,
                            format: "%.2f"
                        )
                        LabeledSlider(
                            title: "Max Frequency",
                            value: doubleBinding(channelID, \.maxFrequencyNormalized),
                            range: 0...1,
                            format: "%.2f"
                        )
                    }
                }
            }
            .navigationTitle("Generator")
        }
    }

    private func stringBinding(
        _ channelID: GeneratorChannelID,
        _ keyPath: WritableKeyPath<GeneratorChannelConfig, String>
    ) -> Binding<String> {
        Binding(
            get: { channelConfig(for: channelID)[keyPath: keyPath] },
            set: { newValue in
                model.updateGeneratorChannel(channelID) { channel in
                    channel[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func doubleBinding(
        _ channelID: GeneratorChannelID,
        _ keyPath: WritableKeyPath<GeneratorChannelConfig, Double>
    ) -> Binding<Double> {
        Binding(
            get: { channelConfig(for: channelID)[keyPath: keyPath] },
            set: { newValue in
                model.updateGeneratorChannel(channelID) { channel in
                    channel[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func channelConfig(for channelID: GeneratorChannelID) -> GeneratorChannelConfig {
        switch channelID {
        case .a: return model.generatorConfig.channelA
        case .b: return model.generatorConfig.channelB
        }
    }
}

private struct ActivitiesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Hardware Tests") {
                    ForEach(DemoActivity.hardwareTests) { activity in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(activity.rawValue)
                                .font(.headline)
                            Text(hardwareTestDescription(for: activity))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Load and Play") {
                                model.loadActivity(activity, playImmediately: true)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Prototype Presets") {
                    ForEach(DemoActivity.prototypePresets) { activity in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(activity.rawValue)
                                .font(.headline)
                            Button("Load and Play") {
                                model.loadActivity(activity, playImmediately: true)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Why this is scoped down") {
                    Text("Use the hardware tests before judging channel behavior. The prototype presets are intentionally asymmetrical and can make one side dominate before the other.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Activities")
        }
    }

    private func hardwareTestDescription(for activity: DemoActivity) -> String {
        switch activity {
        case .hardwareTestA:
            return "Constant output on Channel A only."
        case .hardwareTestB:
            return "Constant output on Channel B only."
        case .hardwareTestDual:
            return "Constant matched output on both channels."
        case .tease, .orbit, .ladder:
            return ""
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var bleManager: CoyoteBluetoothManager
    @EnvironmentObject private var audioEngine: AudioOutputEngine

    var body: some View {
        NavigationStack {
            Form {
                Section("Output") {
                    Picker("Mode", selection: $model.outputMode) {
                        ForEach(OutputMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }

                Section("Power Controls") {
                    LabeledSlider(
                        title: "Slider Ceiling",
                        value: Binding(
                            get: { Double(model.powerSliderCeiling) },
                            set: { model.powerSliderCeiling = Int($0.rounded()) }
                        ),
                        range: 10...200,
                        format: "%.0f"
                    )

                    Text("Howl caps both power sliders at this value so the range you actually use is easier to control.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Audio") {
                    LabeledContent("Status", value: audioEngine.statusSummary)
                    LabeledContent("Keepalive", value: audioEngine.keepaliveSummary)
                    LabeledContent("Route", value: audioEngine.routeSummary)
                    Toggle("Keep Live BLE Alive in Background", isOn: $model.enableLiveBackgroundKeepalive)
                    Text("Use Audio Output to test real background playback. BLE live control is still a separate path and may suspend when the app leaves the foreground.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("When enabled, Live Coyote 3 keeps a silent background audio session running so iPhone is less likely to suspend the app the moment you switch away.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let error = audioEngine.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("HWL Playback") {
                    Picker("Profile", selection: $model.hwlPlaybackProfile) {
                        ForEach(HWLPlaybackProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile)
                        }
                    }

                    Text(model.hwlPlaybackProfile.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("BLE") {
                    LabeledContent("State", value: bleManager.state.rawValue)
                    LabeledContent("Last Seen", value: bleManager.lastSeenDeviceName)
                    LabeledContent("Seen Devices", value: bleManager.seenDeviceSummary)
                    LabeledContent("Battery", value: bleManager.batteryLevel.map { "\($0)%" } ?? "Unknown")
                    LabeledContent(
                        "Device Echo",
                        value: bleManager.devicePowerA.flatMap { powerA in
                            bleManager.devicePowerB.map { powerB in "A \(powerA) / B \(powerB)" }
                        } ?? "No echo yet"
                    )

                    if bleManager.state == .disconnected || bleManager.state == .unavailable {
                        Button("Scan for Coyote 3") {
                            bleManager.connectOrScan()
                        }
                    } else {
                        Button("Disconnect") {
                            bleManager.disconnect()
                        }
                    }

                    if !bleManager.stagedPacketHex.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current Packet Preview")
                                .font(.caption.weight(.semibold))
                            Text(bleManager.stagedPacketHex)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if !bleManager.lastWriteHex.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last Sent Packet")
                                .font(.caption.weight(.semibold))
                            Text(bleManager.lastWriteHex)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if !bleManager.lastNotifyHex.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last Notify Frame")
                                .font(.caption.weight(.semibold))
                            Text(bleManager.lastNotifyHex)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if let error = bleManager.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Diagnostics") {
                    LabeledContent("Last Write", value: bleManager.lastWriteSummary)
                    LabeledContent("Last Notify", value: bleManager.lastNotifySummary)
                    LabeledContent("Pulse Batches", value: "\(bleManager.sentPulsePacketCount)")
                    LabeledContent("Backpressure Hits", value: "\(bleManager.queuedPulsePacketCount)")
                    LabeledContent("Notify Frames", value: "\(bleManager.notifyFrameCount)")
                    LabeledContent("Requested Power", value: bleManager.requestedPowerSummary)
                    LabeledContent("Pulse Packet Power", value: bleManager.pulsePowerSummary)
                    LabeledContent("Parameter Sync Power", value: bleManager.parameterPowerSummary)
                    LabeledContent("Echo Power", value: bleManager.echoPowerSummary)
                }

                Section("Frequency Range") {
                    Picker("Preset", selection: $model.frequencyRangePreset) {
                        ForEach(FrequencyRangePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }

                    Text(model.frequencyRangePreset.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    LabeledSlider(
                        title: "Minimum",
                        value: $model.minFrequency,
                        range: 1...180,
                        format: "%.0f Hz"
                    )
                    LabeledSlider(
                        title: "Maximum",
                        value: $model.maxFrequency,
                        range: 10...200,
                        format: "%.0f Hz"
                    )
                }

                Section("Notes") {
                    Text("This build now matches the Android Coyote 3 packet shape, sends 4-pulse batches, and exposes transport diagnostics for first-pass hardware testing. Coyote 2, recorder mode, and real device validation still need a separate pass.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct PulseMetricsView: View {
    let pulse: Pulse

    var body: some View {
        HStack(spacing: 12) {
            MetricChip(title: "A Amp", value: pulse.ampA)
            MetricChip(title: "B Amp", value: pulse.ampB)
            MetricChip(title: "A Freq", value: pulse.freqA)
            MetricChip(title: "B Freq", value: pulse.freqB)
        }
    }
}

private struct PulseHistoryView: View {
    let pulses: [Pulse]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(pulses.enumerated()), id: \.offset) { _, pulse in
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(.orange)
                            .frame(height: max(4, geometry.size.height * CGFloat(pulse.ampA) * 0.5))
                        Capsule()
                            .fill(.mint)
                            .frame(height: max(4, geometry.size.height * CGFloat(pulse.ampB) * 0.5))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct MetricChip: View {
    let title: String
    let value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.2f", value))
                .font(.body.monospacedDigit())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .foregroundStyle(.secondary)
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct PowerControlRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Double>
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)")
                    .foregroundStyle(.secondary)
                    .font(.caption.monospacedDigit())
            }

            HStack(spacing: 10) {
                Button(action: onDecrement) {
                    Image(systemName: "minus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)

                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { value = Int($0.rounded()) }
                    ),
                    in: range
                )

                Button(action: onIncrement) {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private func timeString(_ time: TimeInterval) -> String {
    let minutes = Int(time / 60)
    let seconds = time.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%04.1f", minutes, seconds)
}
