import Foundation
import SwiftUI
import ZIPFoundation

private func normalizedLibraryDisplayPathComponents(from components: [String]) -> [String] {
    guard components.isEmpty == false else { return [] }

    var normalized = components

    if let first = normalized.first {
        let lowered = first.lowercased()
        if lowered == "private", normalized.count > 1 {
            normalized.removeFirst()
        } else if lowered.hasPrefix("private"), first.count > "private".count {
            let suffix = String(first.dropFirst("private".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
            if suffix.isEmpty == false {
                normalized[0] = suffix
            }
        }
    }

    return normalized
}

enum OutputMode: String, CaseIterable, Identifiable {
    case preview = "Preview Only"
    case audio = "Audio Output"
    case coyote3PacketPreview = "Stage Coyote 3 Packet"
    case coyote3Live = "Live Coyote 3"

    var id: String { rawValue }
}

enum FrequencyRangePreset: String, CaseIterable, Identifiable {
    case faithful = "Faithful"
    case comfort = "Comfort"
    case custom = "Custom"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .faithful:
            return "Wider range that keeps more of the file's original frequency motion."
        case .comfort:
            return "Narrower range that softens the highs and reduces contrast."
        case .custom:
            return "Your manual min/max range."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private struct ImportedFile {
        let data: Data
        let displayName: String
        let ext: String
    }

    struct LibraryEntry: Identifiable, Equatable, Sendable {
        let url: URL
        let displayName: String
        let relativePath: String
        let modifiedAt: Date?

        var id: String { url.absoluteString }

        var pathComponents: [String] {
            relativePath
                .split(separator: "/")
                .map(String.init)
        }

        var displayPathComponents: [String] {
            normalizedLibraryDisplayPathComponents(from: pathComponents)
        }

        var folderPathComponents: [String] {
            Array(pathComponents.dropLast())
        }

        var folderRelativePath: String {
            folderPathComponents.joined(separator: "/")
        }

        var topLevelGroupName: String {
            pathComponents.dropLast().first ?? "Root Files"
        }

        var displayRelativePath: String {
            displayPathComponents.joined(separator: "/")
        }

        var displayFolderPathComponents: [String] {
            Array(displayPathComponents.dropLast())
        }
    }

    struct LibraryFolderNode: Identifiable, Equatable, Sendable {
        let name: String
        let relativePath: String
        let folders: [LibraryFolderNode]
        let files: [LibraryEntry]

        var id: String { relativePath }

        var totalFileCount: Int {
            files.count + folders.reduce(0) { partial, folder in
                partial + folder.totalFileCount
            }
        }
    }

    struct LibraryTree: Equatable, Sendable {
        let rootFiles: [LibraryEntry]
        let folders: [LibraryFolderNode]
    }

    struct Playlist: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        var name: String
        var entryRelativePaths: [String]
    }

    private enum LibraryDefaults {
        static let supportedExtensions = Set(["hwl", "funscript", "json"])
        static let supportedImportExtensions = Set(["hwl", "funscript", "json", "zip"])
        static let favoritesKey = "Howl.LibraryFavorites.Local"
        static let playlistsKey = "Howl.LibraryPlaylists.Local"
        static let expandedFolderPathsKey = "Howl.LibraryExpandedFolders.Local"
        static let expandedPlaylistIDsKey = "Howl.LibraryExpandedPlaylists.Local"
        static let localFolderName = "Imported Scripts"
    }

    @Published var sourceName = "No source loaded"
    @Published var duration: TimeInterval?
    @Published var position: TimeInterval = 0
    @Published var isPlaying = false
    @Published var currentPulse: Pulse = .silence
    @Published var recentPulses: [Pulse] = []
    @Published var powerA = 20 {
        didSet {
            syncBleLimits()
        }
    }
    @Published var powerB = 20 {
        didSet {
            syncBleLimits()
        }
    }
    @Published var minFrequency = 10.0 {
        didSet {
            guard isAdjustingFrequencyRange == false else { return }
            if minFrequency > maxFrequency {
                maxFrequency = minFrequency
            }
            syncFrequencyRangePreset()
            syncAudioTransport()
        }
    }
    @Published var maxFrequency = 100.0 {
        didSet {
            guard isAdjustingFrequencyRange == false else { return }
            if maxFrequency < minFrequency {
                minFrequency = maxFrequency
            }
            syncFrequencyRangePreset()
            syncAudioTransport()
        }
    }
    @Published var frequencyRangePreset: FrequencyRangePreset = .faithful {
        didSet {
            applyFrequencyRangePresetIfNeeded()
        }
    }
    @Published var outputMode: OutputMode = .preview {
        didSet {
            handleOutputModeChanged(from: oldValue)
        }
    }
    @Published var generatorConfig: GeneratorConfig = .default
    @Published var selectedActivity: DemoActivity = .tease
    @Published var hwlPlaybackProfile: HWLPlaybackProfile = .smooth {
        didSet {
            reloadCurrentHWLIfNeeded()
        }
    }
    @Published var enableLiveBackgroundKeepalive = true {
        didSet {
            syncBackgroundKeepalive()
        }
    }
    @Published var libraryFolderName = LibraryDefaults.localFolderName
    @Published var libraryStatusMessage = "Stored inside Howl on this iPhone."
    @Published var libraryEntries: [LibraryEntry] = []
    @Published var isRefreshingLibrary = false
    @Published private(set) var favoriteLibraryRelativePaths: Set<String> = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var expandedLibraryFolderPaths: Set<String> = []
    @Published private(set) var expandedPlaylistIDs: Set<UUID> = []
    @Published private(set) var loadedLibraryRelativePath: String?
    @Published private(set) var currentPlaylistID: UUID?
    @Published var statusMessage = "Load a file or use the generator."
    @Published var lastError: String?

    let bleManager = CoyoteBluetoothManager()
    let audioEngine = AudioOutputEngine()

    private var loadedSource: (any PulseSource)?
    private var loadedImportedFile: ImportedFile?
    private var playbackTask: Task<Void, Never>?
    private let pulseInterval = 1.0 / 40.0
    private let outputBatchSize = Coyote3Protocol.pulseBatchSize
    private let maxHistoryPoints = 36
    private var playbackTickIndex = 0
    private var libraryRefreshTask: Task<Void, Never>?
    private var activeLibraryRefreshID: UUID?
    private var isAdjustingFrequencyRange = false

    init() {
        syncBleLimits()
        prepareLocalLibrary()
        refreshLibrary()
    }

    var shapeNames: [String] {
        WaveShape.generatorLibrary.map(\.name)
    }

    @discardableResult
    func importFile(from url: URL) -> Bool {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            lastError = nil
            let importedFile = try Self.readImportedFile(from: url)
            let data = importedFile.data
            let ext = importedFile.ext
            switch ext {
            case "hwl":
                let source = try HWLPulseSource(
                    data: data,
                    displayName: importedFile.displayName,
                    settings: HWLSettings(profile: hwlPlaybackProfile)
                )
                loadedImportedFile = importedFile
                load(source: source)
                return true
            case "funscript", "json":
                let source = try FunscriptPulseSource(data: data, displayName: importedFile.displayName)
                loadedImportedFile = importedFile
                load(source: source)
                return true
            default:
                throw HowlCoreError.unsupportedFileType(ext)
            }
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not load \(url.lastPathComponent)."
            return false
        }
    }

    func importFilesToLibrary(from urls: [URL]) {
        guard !urls.isEmpty else { return }

        libraryRefreshTask?.cancel()
        isRefreshingLibrary = true
        lastError = nil
        let refreshID = UUID()
        activeLibraryRefreshID = refreshID
        libraryStatusMessage = "Importing \(urls.count) file(s)..."

        libraryRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeLibraryRefreshID == refreshID {
                    self.isRefreshingLibrary = false
                }
            }

            do {
                let copyTask = Task.detached(priority: .userInitiated) {
                    try Self.copyFilesToLocalLibrary(from: urls)
                }
                let importedCount = try await withTaskCancellationHandler {
                    try await copyTask.value
                } onCancel: {
                    copyTask.cancel()
                }

                let scanTask = Task.detached(priority: .userInitiated) {
                    let folderURL = try Self.localLibraryRootURLStatic()
                    return try Self.loadLibraryEntries(from: folderURL)
                }
                let entries = try await withTaskCancellationHandler {
                    try await scanTask.value
                } onCancel: {
                    scanTask.cancel()
                }

                guard !Task.isCancelled else { return }
                guard self.activeLibraryRefreshID == refreshID else { return }

                self.libraryEntries = entries.sorted {
                    $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
                }
                self.libraryFolderName = LibraryDefaults.localFolderName
                self.libraryStatusMessage = importedCount == 0
                    ? "No supported `.hwl` or `.funscript` files were found in that import."
                    : "Imported \(importedCount) file(s) into Howl."
            } catch is CancellationError {
                return
            } catch {
                guard self.activeLibraryRefreshID == refreshID else { return }
                self.lastError = error.localizedDescription
                self.libraryStatusMessage = "Could not import those files."
            }
        }
    }

    func refreshLibrary() {
        libraryRefreshTask?.cancel()
        isRefreshingLibrary = true
        lastError = nil
        let folderName = LibraryDefaults.localFolderName
        let refreshID = UUID()
        activeLibraryRefreshID = refreshID
        libraryStatusMessage = "Indexing \(folderName)..."

        libraryRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeLibraryRefreshID == refreshID {
                    self.isRefreshingLibrary = false
                }
            }

            do {
                let folderURL = try Self.localLibraryRootURLStatic()
                let scanTask = Task.detached(priority: .userInitiated) {
                    try Self.loadLibraryEntries(from: folderURL)
                }

                let entries = try await withTaskCancellationHandler {
                    try await scanTask.value
                } onCancel: {
                    scanTask.cancel()
                }

                guard !Task.isCancelled else { return }
                guard self.activeLibraryRefreshID == refreshID else { return }

                self.libraryEntries = entries.sorted {
                    $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
                }
                self.libraryFolderName = folderName
                self.libraryStatusMessage = entries.isEmpty
                    ? "No supported files found in \(folderName)."
                    : "Indexed \(entries.count) supported files."
            } catch is CancellationError {
                return
            } catch {
                guard self.activeLibraryRefreshID == refreshID else { return }
                self.lastError = error.localizedDescription
                self.libraryEntries = []
                self.libraryStatusMessage = "Could not read \(folderName)."
            }
        }
    }

    func loadLibraryEntry(_ entry: LibraryEntry, playlistID: UUID? = nil) {
        guard importFile(from: entry.url) else { return }
        loadedLibraryRelativePath = entry.relativePath
        currentPlaylistID = playlistID
    }

    func deleteLibraryEntry(_ entry: LibraryEntry) {
        do {
            try FileManager.default.removeItem(at: entry.url)
            libraryEntries.removeAll { $0.relativePath == entry.relativePath }
            favoriteLibraryRelativePaths.remove(entry.relativePath)
            playlists = playlists.map { playlist in
                var updated = playlist
                updated.entryRelativePaths.removeAll { $0 == entry.relativePath }
                return updated
            }

            if loadedLibraryRelativePath == entry.relativePath {
                loadedLibraryRelativePath = nil
                currentPlaylistID = nil
            }

            persistFavoritesForCurrentLibrary()
            persistPlaylists()
            libraryStatusMessage = libraryEntries.isEmpty
                ? "No supported files found in \(libraryFolderName)."
                : "Indexed \(libraryEntries.count) supported files."
            statusMessage = "Deleted \(entry.displayName) from the library."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not delete \(entry.displayName)."
        }
    }

    func toggleFavorite(for entry: LibraryEntry) {
        if favoriteLibraryRelativePaths.contains(entry.relativePath) {
            favoriteLibraryRelativePaths.remove(entry.relativePath)
        } else {
            favoriteLibraryRelativePaths.insert(entry.relativePath)
        }
        persistFavoritesForCurrentLibrary()
    }

    func isFavorite(_ entry: LibraryEntry) -> Bool {
        favoriteLibraryRelativePaths.contains(entry.relativePath)
    }

    func isLoadedLibraryEntry(_ entry: LibraryEntry) -> Bool {
        loadedLibraryRelativePath == entry.relativePath
    }

    func libraryTree(for entries: [LibraryEntry]) -> LibraryTree {
        Self.buildLibraryTree(from: entries)
    }

    func isLibraryFolderExpanded(_ relativePath: String) -> Bool {
        expandedLibraryFolderPaths.contains(relativePath)
    }

    func setLibraryFolderExpanded(_ isExpanded: Bool, for relativePath: String) {
        if isExpanded {
            expandedLibraryFolderPaths.insert(relativePath)
        } else {
            expandedLibraryFolderPaths.remove(relativePath)
        }
        persistExpandedFolderPaths()
    }

    func isPlaylistExpanded(_ playlistID: UUID) -> Bool {
        expandedPlaylistIDs.contains(playlistID)
    }

    func setPlaylistExpanded(_ isExpanded: Bool, for playlistID: UUID) {
        if isExpanded {
            expandedPlaylistIDs.insert(playlistID)
        } else {
            expandedPlaylistIDs.remove(playlistID)
        }
        persistExpandedPlaylistIDs()
    }

    @discardableResult
    func createPlaylist(named name: String) -> Playlist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let playlist = Playlist(
            id: UUID(),
            name: uniquePlaylistName(from: trimmed),
            entryRelativePaths: []
        )
        playlists.append(playlist)
        persistPlaylists()
        return playlist
    }

    func deletePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        expandedPlaylistIDs.remove(playlist.id)
        persistPlaylists()
        persistExpandedPlaylistIDs()
    }

    func playlistContains(_ entry: LibraryEntry, in playlist: Playlist) -> Bool {
        playlist.entryRelativePaths.contains(entry.relativePath)
    }

    func addEntry(_ entry: LibraryEntry, toPlaylistID playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        guard playlists[index].entryRelativePaths.contains(entry.relativePath) == false else { return }
        playlists[index].entryRelativePaths.append(entry.relativePath)
        persistPlaylists()
    }

    func removeEntry(_ entry: LibraryEntry, fromPlaylistID playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].entryRelativePaths.removeAll { $0 == entry.relativePath }
        persistPlaylists()
    }

    func entries(for playlist: Playlist) -> [LibraryEntry] {
        let entriesByPath = Dictionary(uniqueKeysWithValues: libraryEntries.map { ($0.relativePath, $0) })
        return playlist.entryRelativePaths.compactMap { entriesByPath[$0] }
    }

    var currentPlaylistName: String? {
        guard let currentPlaylistID else { return nil }
        return playlists.first(where: { $0.id == currentPlaylistID })?.name
    }

    func loadGenerator(playImmediately: Bool = false) {
        loadedImportedFile = nil
        loadedLibraryRelativePath = nil
        currentPlaylistID = nil
        let source = GeneratorPulseSource(config: generatorConfig, displayName: "Generator")
        load(source: source)
        if playImmediately {
            play()
        }
    }

    func loadActivity(_ activity: DemoActivity, playImmediately: Bool = true) {
        selectedActivity = activity
        generatorConfig = activity.generatorConfig
        loadedImportedFile = nil
        loadedLibraryRelativePath = nil
        currentPlaylistID = nil
        let source = GeneratorPulseSource(config: activity.generatorConfig, displayName: activity.rawValue)
        load(source: source)
        if playImmediately {
            play()
        }
    }

    func updateGeneratorSpeed(_ newValue: Double) {
        generatorConfig.speed = newValue
    }

    func updateGeneratorChannel(
        _ channelID: GeneratorChannelID,
        mutate: (inout GeneratorChannelConfig) -> Void
    ) {
        switch channelID {
        case .a:
            var channel = generatorConfig.channelA
            mutate(&channel)
            generatorConfig.channelA = channel
        case .b:
            var channel = generatorConfig.channelB
            mutate(&channel)
            generatorConfig.channelB = channel
        }
    }

    func togglePlayback() {
        isPlaying ? stop() : play()
    }

    func play() {
        guard loadedSource != nil else {
            loadGenerator(playImmediately: true)
            return
        }

        guard !isPlaying else { return }
        isPlaying = true
        playbackTickIndex = 0
        statusMessage = outputMode == .coyote3Live && !bleManager.isReady
            ? "Playing \(sourceName) while waiting for a ready Coyote 3."
            : "Playing \(sourceName)."
        syncAudioTransport()
        syncBackgroundKeepalive()
        startPlaybackLoop()
    }

    func stop() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        audioEngine.stop()
        sendSilenceIfNeeded()
        currentPulse = .silence
        statusMessage = "Stopped."
    }

    func seek(to newPosition: TimeInterval) {
        position = newPosition
        playbackTickIndex = 0
        audioEngine.seek(to: newPosition)
        renderCurrentFrame()
    }

    func clearError() {
        lastError = nil
    }

    private func load(source: any PulseSource) {
        stop()
        loadedSource = source
        sourceName = source.displayName
        duration = source.duration
        position = 0
        recentPulses = []
        playbackTickIndex = 0
        statusMessage = "Loaded \(source.displayName)."
        renderCurrentFrame()
        syncAudioTransport()
    }

    private func prepareLocalLibrary() {
        do {
            let folderURL = try Self.localLibraryRootURLStatic()
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            libraryFolderName = LibraryDefaults.localFolderName
            libraryStatusMessage = "Stored inside Howl on this iPhone."
            loadFavoritesForCurrentLibrary()
            loadPlaylists()
            loadExpandedFolderPaths()
            loadExpandedPlaylistIDs()
        } catch {
            lastError = error.localizedDescription
            libraryStatusMessage = "Could not prepare local library storage."
            favoriteLibraryRelativePaths = []
            playlists = []
            expandedLibraryFolderPaths = []
            expandedPlaylistIDs = []
        }
    }

    nonisolated private static func loadLibraryEntries(from folderURL: URL) throws -> [LibraryEntry] {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatedEntries: [LibraryEntry] = []
        var coordinationError: NSError?
        var scanError: Error?

        coordinator.coordinate(readingItemAt: folderURL, options: [], error: &coordinationError) { coordinatedURL in
            do {
                coordinatedEntries = try scanLibraryDirectory(at: coordinatedURL, baseURL: coordinatedURL)
            } catch {
                scanError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }

        if let scanError {
            throw scanError
        }

        return coordinatedEntries
    }

    nonisolated private static func scanLibraryDirectory(at directoryURL: URL, baseURL: URL) throws -> [LibraryEntry] {
        try Task.checkCancellation()

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .contentModificationDateKey
        ]

        let childURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var entries: [LibraryEntry] = []

        for childURL in childURLs {
            try Task.checkCancellation()
            let values = try childURL.resourceValues(forKeys: resourceKeys)

            if values.isDirectory == true {
                entries.append(contentsOf: try scanLibraryDirectory(at: childURL, baseURL: baseURL))
                continue
            }

            guard values.isRegularFile == true else { continue }

            let ext = childURL.pathExtension.lowercased()
            guard LibraryDefaults.supportedExtensions.contains(ext) else { continue }

            let relativePath = childURL.path.replacingOccurrences(
                of: baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/",
                with: ""
            )

            entries.append(
                LibraryEntry(
                    url: childURL,
                    displayName: childURL.lastPathComponent,
                    relativePath: relativePath,
                    modifiedAt: values.contentModificationDate
                )
            )
        }

        return entries
    }

    nonisolated private static func readImportedFile(from url: URL) throws -> ImportedFile {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readError: Error?
        var fileData = Data()
        var displayName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                displayName = coordinatedURL.lastPathComponent
                fileData = try Data(contentsOf: coordinatedURL)
            } catch {
                readError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }

        if let readError {
            throw readError
        }

        return ImportedFile(data: fileData, displayName: displayName, ext: ext)
    }

    nonisolated private static func copyFilesToLocalLibrary(from urls: [URL]) throws -> Int {
        let fileManager = FileManager.default
        let libraryRootURL = try localLibraryRootURLStatic()
        try fileManager.createDirectory(at: libraryRootURL, withIntermediateDirectories: true)

        var importedCount = 0

        for url in urls {
            try Task.checkCancellation()
            let ext = url.pathExtension.lowercased()
            guard LibraryDefaults.supportedImportExtensions.contains(ext) else { continue }

            switch ext {
            case "zip":
                importedCount += try importArchiveToLocalLibrary(from: url, libraryRootURL: libraryRootURL)
            default:
                importedCount += try importRegularFileToLocalLibrary(from: url, libraryRootURL: libraryRootURL)
            }
        }

        return importedCount
    }

    nonisolated private static func importRegularFileToLocalLibrary(from url: URL, libraryRootURL: URL) throws -> Int {
        let fileManager = FileManager.default
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let importedFile = try readImportedFile(from: url)
        let destinationGroupURL = libraryRootURL.appendingPathComponent(
            groupingFolderName(for: url),
            isDirectory: true
        )
        try fileManager.createDirectory(at: destinationGroupURL, withIntermediateDirectories: true)

        let destinationURL = uniqueDestinationURL(
            directory: destinationGroupURL,
            preferredName: importedFile.displayName
        )
        try importedFile.data.write(to: destinationURL, options: [.atomic])
        return 1
    }

    nonisolated private static func importArchiveToLocalLibrary(from url: URL, libraryRootURL: URL) throws -> Int {
        let fileManager = FileManager.default
        let temporaryRootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryRootURL)
        }

        let temporaryArchiveURL = temporaryRootURL.appendingPathComponent(url.lastPathComponent)
        try copyCoordinatedItem(from: url, to: temporaryArchiveURL)

        guard let archive = Archive(url: temporaryArchiveURL, accessMode: .read) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let fileEntries = archive.filter { entry in
            entry.type == .file && LibraryDefaults.supportedExtensions.contains(URL(fileURLWithPath: entry.path).pathExtension.lowercased())
        }
        let strippedRoot = commonArchiveRoot(for: fileEntries.map(\.path))

        var importedCount = 0

        for entry in fileEntries {
            try Task.checkCancellation()

            let normalizedPath = normalizedArchiveRelativePath(for: entry.path, stripping: strippedRoot)
            let pathParts = normalizedPath
                .split(separator: "/")
                .map(String.init)

            guard let fileName = pathParts.last else { continue }
            let directoryParts = Array(pathParts.dropLast())

            let destinationDirectory = directoryParts.reduce(libraryRootURL) { partial, next in
                partial.appendingPathComponent(next, isDirectory: true)
            }
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

            let destinationURL = uniqueDestinationURL(directory: destinationDirectory, preferredName: fileName)
            _ = try archive.extract(entry, to: destinationURL)
            importedCount += 1
        }

        return importedCount
    }

    nonisolated private static func copyCoordinatedItem(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { coordinatedURL in
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: coordinatedURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }

        if let copyError {
            throw copyError
        }
    }

    nonisolated private static func localLibraryRootURLStatic() throws -> URL {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return baseURL.appendingPathComponent("HowlLibrary", isDirectory: true)
    }

    nonisolated private static func groupingFolderName(for sourceURL: URL) -> String {
        let folderName = sourceURL.deletingLastPathComponent().lastPathComponent
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == "/" {
            return "Imported"
        }
        return sanitizePathComponent(trimmed)
    }

    nonisolated private static func commonArchiveRoot(for entryPaths: [String]) -> String? {
        let componentLists = entryPaths
            .map(archivePathComponents(for:))
            .filter { $0.isEmpty == false }

        guard let firstComponents = componentLists.first, let candidate = firstComponents.first else {
            return nil
        }

        guard firstComponents.count > 1 else { return nil }
        guard componentLists.allSatisfy({ $0.first == candidate && $0.count > 1 }) else { return nil }
        return candidate
    }

    nonisolated private static func normalizedArchiveRelativePath(for entryPath: String, stripping strippedRoot: String?) -> String {
        var components = archivePathComponents(for: entryPath)
        if let strippedRoot, components.first == strippedRoot {
            components.removeFirst()
        }

        let sanitizedComponents = components.map(sanitizePathComponent).filter { $0.isEmpty == false }
        if sanitizedComponents.isEmpty {
            return sanitizeFilename(URL(fileURLWithPath: entryPath).lastPathComponent)
        }

        if sanitizedComponents.count == 1 {
            return sanitizeFilename(sanitizedComponents[0])
        }

        let fileName = sanitizeFilename(sanitizedComponents.last ?? "Imported")
        let directories = Array(sanitizedComponents.dropLast())
        return (directories + [fileName]).joined(separator: "/")
    }

    nonisolated private static func archivePathComponents(for entryPath: String) -> [String] {
        let normalizedPath = entryPath.replacingOccurrences(of: "\\", with: "/")
        let rawComponents = normalizedPath.split(separator: "/")
        var components: [String] = []
        components.reserveCapacity(rawComponents.count)

        for rawComponent in rawComponents {
            let component = String(rawComponent)
            guard component.isEmpty == false, component != ".", component != ".." else { continue }
            components.append(component)
        }

        if let first = components.first, first.hasSuffix(":") {
            components.removeFirst()
        }

        if components.count > 2, components.first?.localizedCaseInsensitiveCompare("private") == .orderedSame {
            components.removeFirst()
        }

        return components
    }

    nonisolated private static func uniqueDestinationURL(directory: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let sanitizedName = sanitizeFilename(preferredName)
        let initialURL = directory.appendingPathComponent(sanitizedName)
        guard fileManager.fileExists(atPath: initialURL.path) == false else {
            let ext = initialURL.pathExtension
            let stem = initialURL.deletingPathExtension().lastPathComponent

            for index in 2...10_000 {
                let nextName: String
                if ext.isEmpty {
                    nextName = "\(stem) \(index)"
                } else {
                    nextName = "\(stem) \(index).\(ext)"
                }

                let nextURL = directory.appendingPathComponent(nextName)
                if fileManager.fileExists(atPath: nextURL.path) == false {
                    return nextURL
                }
            }

            return directory.appendingPathComponent(UUID().uuidString + "-" + sanitizedName)
        }
        return initialURL
    }

    nonisolated private static func sanitizeFilename(_ value: String) -> String {
        let url = URL(fileURLWithPath: value)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let cleanStem = sanitizePathComponent(stem.isEmpty ? "Imported" : stem)
        if ext.isEmpty {
            return cleanStem
        }
        return "\(cleanStem).\(sanitizePathComponent(ext))"
    }

    nonisolated private static func sanitizePathComponent(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let pieces = value.components(separatedBy: invalidCharacters)
        let joined = pieces.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "Imported" : joined
    }

    private func loadFavoritesForCurrentLibrary() {
        let stored = UserDefaults.standard.array(forKey: LibraryDefaults.favoritesKey) as? [String] ?? []
        favoriteLibraryRelativePaths = Set(stored)
    }

    private func persistFavoritesForCurrentLibrary() {
        let sortedFavorites = favoriteLibraryRelativePaths.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        UserDefaults.standard.set(sortedFavorites, forKey: LibraryDefaults.favoritesKey)
    }

    private func loadPlaylists() {
        guard let data = UserDefaults.standard.data(forKey: LibraryDefaults.playlistsKey) else {
            playlists = []
            return
        }

        do {
            playlists = try JSONDecoder().decode([Playlist].self, from: data)
        } catch {
            playlists = []
        }
    }

    private func persistPlaylists() {
        do {
            let data = try JSONEncoder().encode(playlists)
            UserDefaults.standard.set(data, forKey: LibraryDefaults.playlistsKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadExpandedFolderPaths() {
        let stored = UserDefaults.standard.array(forKey: LibraryDefaults.expandedFolderPathsKey) as? [String] ?? []
        expandedLibraryFolderPaths = Set(stored)
    }

    private func persistExpandedFolderPaths() {
        let sortedPaths = expandedLibraryFolderPaths.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        UserDefaults.standard.set(sortedPaths, forKey: LibraryDefaults.expandedFolderPathsKey)
    }

    private func loadExpandedPlaylistIDs() {
        let stored = UserDefaults.standard.array(forKey: LibraryDefaults.expandedPlaylistIDsKey) as? [String] ?? []
        expandedPlaylistIDs = Set(stored.compactMap(UUID.init(uuidString:)))
    }

    private func persistExpandedPlaylistIDs() {
        let values = expandedPlaylistIDs.map(\.uuidString).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        UserDefaults.standard.set(values, forKey: LibraryDefaults.expandedPlaylistIDsKey)
    }

    private func uniquePlaylistName(from baseName: String) -> String {
        guard playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(baseName) == .orderedSame }) else {
            return baseName
        }

        for index in 2...10_000 {
            let candidate = "\(baseName) \(index)"
            if playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) == false {
                return candidate
            }
        }

        return "\(baseName) \(UUID().uuidString.prefix(4))"
    }

    private func applyFrequencyRangePresetIfNeeded() {
        guard isAdjustingFrequencyRange == false else { return }
        guard frequencyRangePreset != .custom else { return }

        let range = Self.rangeValues(for: frequencyRangePreset)
        isAdjustingFrequencyRange = true
        minFrequency = range.min
        maxFrequency = range.max
        isAdjustingFrequencyRange = false
    }

    private func syncFrequencyRangePreset() {
        let faithful = Self.rangeValues(for: .faithful)
        let comfort = Self.rangeValues(for: .comfort)

        let nextPreset: FrequencyRangePreset
        if minFrequency == faithful.min && maxFrequency == faithful.max {
            nextPreset = .faithful
        } else if minFrequency == comfort.min && maxFrequency == comfort.max {
            nextPreset = .comfort
        } else {
            nextPreset = .custom
        }

        if frequencyRangePreset != nextPreset {
            frequencyRangePreset = nextPreset
        }
    }

    private static func rangeValues(for preset: FrequencyRangePreset) -> (min: Double, max: Double) {
        switch preset {
        case .faithful:
            return (min: 10, max: 100)
        case .comfort:
            return (min: 18, max: 72)
        case .custom:
            return (min: 10, max: 100)
        }
    }

    nonisolated private static func buildLibraryTree(from entries: [LibraryEntry]) -> LibraryTree {
        final class MutableFolderNode {
            let name: String
            let relativePath: String
            var folders: [String: MutableFolderNode] = [:]
            var files: [LibraryEntry] = []

            init(name: String, relativePath: String) {
                self.name = name
                self.relativePath = relativePath
            }

            func frozen() -> LibraryFolderNode {
                LibraryFolderNode(
                    name: name,
                    relativePath: relativePath,
                    folders: folders.values
                        .map { $0.frozen() }
                        .sorted { lhs, rhs in
                            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                        },
                    files: files.sorted { lhs, rhs in
                        lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
                    }
                )
            }
        }

        let root = MutableFolderNode(name: "", relativePath: "")
        var rootFiles: [LibraryEntry] = []

        for entry in entries {
            if entry.displayFolderPathComponents.isEmpty {
                rootFiles.append(entry)
                continue
            }

            var currentNode = root
            var currentPathComponents: [String] = []

            for component in entry.displayFolderPathComponents {
                currentPathComponents.append(component)
                let node = currentNode.folders[component] ?? {
                    let created = MutableFolderNode(
                        name: component,
                        relativePath: currentPathComponents.joined(separator: "/")
                    )
                    currentNode.folders[component] = created
                    return created
                }()
                currentNode = node
            }

            currentNode.files.append(entry)
        }

        return LibraryTree(
            rootFiles: rootFiles.sorted { lhs, rhs in
                lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            },
            folders: root.folders.values
                .map { $0.frozen() }
                .sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        )
    }

    private func startPlaybackLoop() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.tick()
                try? await Task.sleep(for: .seconds(self.pulseInterval))
            }
        }
    }

    private func tick() {
        guard let source = loadedSource else {
            stop()
            return
        }

        let pulse = source.pulse(at: position)
        currentPulse = pulse
        appendToHistory(pulse)
        applyOutput(for: pulse, source: source, at: position, transmit: true)

        let nextPosition = position + pulseInterval
        playbackTickIndex += 1
        if let duration = source.duration, nextPosition > duration {
            if source.shouldLoop {
                position = 0
                playbackTickIndex = 0
            } else {
                stop()
            }
        } else {
            position = nextPosition
        }
    }

    private func renderCurrentFrame() {
        guard let source = loadedSource else {
            currentPulse = .silence
            bleManager.clearStagedPacket()
            return
        }

        currentPulse = source.pulse(at: position)
        if recentPulses.isEmpty {
            recentPulses = [currentPulse]
        }
        applyOutput(for: currentPulse, source: source, at: position, transmit: false)
    }

    private func appendToHistory(_ pulse: Pulse) {
        recentPulses.append(pulse)
        if recentPulses.count > maxHistoryPoints {
            recentPulses.removeFirst(recentPulses.count - maxHistoryPoints)
        }
    }

    private func handleOutputModeChanged(from oldValue: OutputMode) {
        if oldValue == .coyote3Live && outputMode != .coyote3Live {
            sendSilence()
        }

        if oldValue == .audio && outputMode != .audio {
            audioEngine.stop()
        }

        if outputMode == .preview {
            bleManager.clearStagedPacket()
            syncBackgroundKeepalive()
            return
        }

        syncBleLimits()
        syncAudioTransport()
        syncBackgroundKeepalive()
        renderCurrentFrame()
    }

    private func syncBleLimits() {
        bleManager.recordRequestedPower(limitA: powerA, limitB: powerB)
        let shouldTransmitParameters = outputMode == .coyote3Live
        let shouldSendLivePowerUpdate =
            shouldTransmitParameters
            && isPlaying
            && loadedSource != nil

        bleManager.updateDesiredLimits(
            limitA: powerA,
            limitB: powerB,
            shouldTransmit: shouldTransmitParameters
        )

        if shouldSendLivePowerUpdate {
            sendImmediateLivePowerUpdate()
        }

        syncAudioTransport()
    }

    private func reloadCurrentHWLIfNeeded() {
        guard let importedFile = loadedImportedFile, importedFile.ext == "hwl" else { return }

        let wasPlaying = isPlaying
        let preservedPosition = position

        do {
            let source = try HWLPulseSource(
                data: importedFile.data,
                displayName: importedFile.displayName,
                settings: HWLSettings(profile: hwlPlaybackProfile)
            )
            load(source: source)
            let targetPosition = min(preservedPosition, source.duration ?? preservedPosition)
            seek(to: targetPosition)
            statusMessage = "Loaded \(source.displayName) with \(hwlPlaybackProfile.rawValue.lowercased()) HWL playback."
            if wasPlaying {
                play()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func applyOutput(for _: Pulse, source: any PulseSource, at time: TimeInterval, transmit: Bool) {
        switch outputMode {
        case .preview, .audio:
            bleManager.clearStagedPacket()
        case .coyote3PacketPreview, .coyote3Live:
            guard let pulses = buildCoyoteBatch(source: source, at: time) else { return }
            let packet: Data
            do {
                packet = try Coyote3Protocol.pulsePacket(
                    pulses: pulses,
                    powerA: powerA,
                    powerB: powerB,
                    minFrequency: minFrequency,
                    maxFrequency: maxFrequency,
                    previousPowerA: bleManager.devicePowerA,
                    previousPowerB: bleManager.devicePowerB
                )
            } catch {
                lastError = error.localizedDescription
                return
            }
            bleManager.stage(packet)

            guard transmit else { return }
            guard playbackTickIndex.isMultiple(of: outputBatchSize) else { return }

            if outputMode == .coyote3Live {
                bleManager.sendLivePacket(packet)
            }
        }
    }

    private func sendImmediateLivePowerUpdate() {
        guard outputMode == .coyote3Live else { return }
        guard isPlaying, let source = loadedSource else { return }
        guard let pulses = buildCoyoteBatch(source: source, at: position) else { return }

        do {
            let packet = try Coyote3Protocol.pulsePacket(
                pulses: pulses,
                powerA: powerA,
                powerB: powerB,
                minFrequency: minFrequency,
                maxFrequency: maxFrequency,
                previousPowerA: bleManager.devicePowerA,
                previousPowerB: bleManager.devicePowerB
            )
            bleManager.stage(packet)
            bleManager.sendLivePacket(packet)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func syncAudioTransport() {
        guard outputMode == .audio else {
            if shouldKeepLiveBackgroundAlive == false {
                audioEngine.stop()
            }
            return
        }

        guard let source = loadedSource, isPlaying else {
            if shouldKeepLiveBackgroundAlive == false {
                audioEngine.stop()
            }
            return
        }

        audioEngine.start(
            source: source,
            position: position,
            minFrequency: minFrequency,
            maxFrequency: maxFrequency,
            powerA: powerA,
            powerB: powerB
        )
    }

    private var shouldKeepLiveBackgroundAlive: Bool {
        enableLiveBackgroundKeepalive
            && outputMode == .coyote3Live
            && isPlaying
            && loadedSource != nil
    }

    private func syncBackgroundKeepalive() {
        guard outputMode != .audio else { return }

        if shouldKeepLiveBackgroundAlive {
            audioEngine.startKeepalive()
        } else {
            audioEngine.stop()
        }
    }

    private func buildCoyoteBatch(source: any PulseSource, at time: TimeInterval) -> [Pulse]? {
        let pulses = (0..<outputBatchSize).map { index in
            source.pulse(at: time + pulseInterval * Double(index))
        }
        guard pulses.count == outputBatchSize else { return nil }
        return pulses
    }

    private func sendSilenceIfNeeded() {
        guard outputMode == .coyote3Live else { return }
        sendSilence()
    }

    private func sendSilence() {
        do {
            let packet = try Coyote3Protocol.pulsePacket(
                pulses: Array(repeating: .silence, count: outputBatchSize),
                powerA: powerA,
                powerB: powerB,
                minFrequency: minFrequency,
                maxFrequency: maxFrequency,
                previousPowerA: bleManager.devicePowerA,
                previousPowerB: bleManager.devicePowerB
            )
            bleManager.sendLivePacket(packet)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
