import Foundation
import SwiftUI

enum OutputMode: String, CaseIterable, Identifiable {
    case preview = "Preview Only"
    case coyote3PacketPreview = "Stage Coyote 3 Packet"
    case coyote3Live = "Live Coyote 3"

    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    private struct ImportedFile {
        let data: Data
        let displayName: String
        let ext: String
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
    @Published var minFrequency = 10.0
    @Published var maxFrequency = 100.0
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
    @Published var statusMessage = "Load a file or use the generator."
    @Published var lastError: String?

    let bleManager = CoyoteBluetoothManager()

    private var loadedSource: (any PulseSource)?
    private var loadedImportedFile: ImportedFile?
    private var playbackTask: Task<Void, Never>?
    private var previousPowerA: Int?
    private var previousPowerB: Int?
    private let pulseInterval = 1.0 / 40.0
    private let outputBatchSize = Coyote3Protocol.pulseBatchSize
    private let maxHistoryPoints = 36
    private var playbackTickIndex = 0

    init() {
        syncBleLimits()
    }

    var shapeNames: [String] {
        WaveShape.generatorLibrary.map(\.name)
    }

    func importFile(from url: URL) {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            lastError = nil
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "hwl":
                let source = try HWLPulseSource(
                    data: data,
                    displayName: url.lastPathComponent,
                    settings: HWLSettings(profile: hwlPlaybackProfile)
                )
                loadedImportedFile = ImportedFile(data: data, displayName: url.lastPathComponent, ext: ext)
                load(source: source)
            case "funscript", "json":
                let source = try FunscriptPulseSource(data: data, displayName: url.lastPathComponent)
                loadedImportedFile = ImportedFile(data: data, displayName: url.lastPathComponent, ext: ext)
                load(source: source)
            default:
                throw HowlCoreError.unsupportedFileType(ext)
            }
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not load \(url.lastPathComponent)."
        }
    }

    func loadGenerator(playImmediately: Bool = false) {
        loadedImportedFile = nil
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
        startPlaybackLoop()
    }

    func stop() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        sendSilenceIfNeeded()
        currentPulse = .silence
        statusMessage = "Stopped."
    }

    func seek(to newPosition: TimeInterval) {
        position = newPosition
        playbackTickIndex = 0
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
        previousPowerA = nil
        previousPowerB = nil
        playbackTickIndex = 0
        statusMessage = "Loaded \(source.displayName)."
        renderCurrentFrame()
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

        if outputMode == .preview {
            previousPowerA = nil
            previousPowerB = nil
            bleManager.clearStagedPacket()
            return
        }

        syncBleLimits()
        renderCurrentFrame()
    }

    private func syncBleLimits() {
        bleManager.updateDesiredLimits(limitA: powerA, limitB: powerB)
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
        case .preview:
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
                    previousPowerA: previousPowerA,
                    previousPowerB: previousPowerB
                )
            } catch {
                lastError = error.localizedDescription
                return
            }
            bleManager.stage(packet)

            guard transmit else { return }
            guard playbackTickIndex.isMultiple(of: outputBatchSize) else { return }
            previousPowerA = powerA
            previousPowerB = powerB

            if outputMode == .coyote3Live {
                bleManager.sendLivePacket(packet)
            }
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
                previousPowerA: previousPowerA,
                previousPowerB: previousPowerB
            )
            bleManager.sendLivePacket(packet)
            previousPowerA = powerA
            previousPowerB = powerB
        } catch {
            lastError = error.localizedDescription
        }
    }
}
