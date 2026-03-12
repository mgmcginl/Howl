import Foundation
import SwiftUI
import HowlCore

enum OutputMode: String, CaseIterable, Identifiable {
    case preview = "Preview Only"
    case coyote3PacketPreview = "Stage Coyote 3 Packet"

    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sourceName = "No source loaded"
    @Published var duration: TimeInterval?
    @Published var position: TimeInterval = 0
    @Published var isPlaying = false
    @Published var currentPulse: Pulse = .silence
    @Published var recentPulses: [Pulse] = []
    @Published var powerA = 20
    @Published var powerB = 20
    @Published var minFrequency = 10.0
    @Published var maxFrequency = 100.0
    @Published var outputMode: OutputMode = .preview
    @Published var generatorConfig: GeneratorConfig = .default
    @Published var selectedActivity: DemoActivity = .tease
    @Published var statusMessage = "Load a file or use the generator."
    @Published var lastError: String?

    let bleManager = CoyoteBluetoothManager()

    private var loadedSource: (any PulseSource)?
    private var playbackTask: Task<Void, Never>?
    private var previousPowerA: Int?
    private var previousPowerB: Int?
    private let pulseInterval = 1.0 / 40.0
    private let maxHistoryPoints = 36

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
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "hwl":
                let source = try HWLPulseSource(data: data, displayName: url.lastPathComponent)
                load(source: source)
            case "funscript", "json":
                let source = try FunscriptPulseSource(data: data, displayName: url.lastPathComponent)
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
        let source = GeneratorPulseSource(config: generatorConfig, displayName: "Generator")
        load(source: source)
        if playImmediately {
            play()
        }
    }

    func loadActivity(_ activity: DemoActivity, playImmediately: Bool = true) {
        selectedActivity = activity
        generatorConfig = activity.generatorConfig
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
        statusMessage = "Playing \(sourceName)."
        startPlaybackLoop()
    }

    func stop() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        statusMessage = "Stopped."
    }

    func seek(to newPosition: TimeInterval) {
        position = newPosition
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
        stageOutput(pulse)

        let nextPosition = position + pulseInterval
        if let duration = source.duration, nextPosition > duration {
            if source.shouldLoop {
                position = 0
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
            return
        }

        currentPulse = source.pulse(at: position)
        if recentPulses.isEmpty {
            recentPulses = [currentPulse]
        }
    }

    private func appendToHistory(_ pulse: Pulse) {
        recentPulses.append(pulse)
        if recentPulses.count > maxHistoryPoints {
            recentPulses.removeFirst(recentPulses.count - maxHistoryPoints)
        }
    }

    private func stageOutput(_ pulse: Pulse) {
        switch outputMode {
        case .preview:
            bleManager.clearStagedPacket()
        case .coyote3PacketPreview:
            let packet = Coyote3Protocol.pulsePacket(
                pulse: pulse,
                powerA: powerA,
                powerB: powerB,
                minFrequency: minFrequency,
                maxFrequency: maxFrequency,
                previousPowerA: previousPowerA,
                previousPowerB: previousPowerB
            )
            previousPowerA = powerA
            previousPowerB = powerB
            bleManager.stage(packet)
        }
    }
}
