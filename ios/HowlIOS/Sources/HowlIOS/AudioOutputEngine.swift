import AVFoundation
import Foundation

@MainActor
final class AudioOutputEngine: NSObject, ObservableObject {
    enum Mode {
        case idle
        case output
        case keepalive
    }

    @Published private(set) var statusSummary = "Idle"
    @Published private(set) var routeSummary = "Unknown"
    @Published private(set) var lastError: String?

    private struct PlaybackState {
        var source: (any PulseSource)?
        var position: Double = 0
        var sampleCursor: Double = 0
        var minFrequency: Double = 10
        var maxFrequency: Double = 100
        var gainA: Double = 0.1
        var gainB: Double = 0.1
        var phaseA: Double = 0
        var phaseB: Double = 0
        var isActive = false
        var mode: Mode = .idle
    }

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let stateLock = NSLock()
    private let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private let chunkFrameCount: AVAudioFrameCount = 4_096
    private let targetBufferedChunkCount = 3

    private var playbackState = PlaybackState()
    private var schedulingTask: Task<Void, Never>?
    private var scheduledBufferCount = 0

    override init() {
        super.init()
        configureEngine()
        updateRouteSummary()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start(
        source: any PulseSource,
        position: TimeInterval,
        minFrequency: Double,
        maxFrequency: Double,
        powerA: Int,
        powerB: Int
    ) {
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
        } catch {
            lastError = "Audio session category failed: \(error.localizedDescription)"
            statusSummary = "Audio output failed"
            return
        }

        do {
            try session.setActive(true)
            updateRouteSummary()

            let shouldResetPlaybackCursor = playbackState.isActive == false
            updateState(
                source: source,
                position: position,
                minFrequency: minFrequency,
                maxFrequency: maxFrequency,
                powerA: powerA,
                powerB: powerB,
                resetPlaybackCursor: shouldResetPlaybackCursor,
                isActive: true,
                mode: .output
            )

            if engine.isRunning == false {
                try engine.start()
            }

            if playerNode.isPlaying == false {
                playerNode.play()
            }

            ensureSchedulingLoop()
            topOffBuffers()
            statusSummary = "Audio output active"
            lastError = nil
        } catch {
            lastError = "Audio engine start failed: \(error.localizedDescription)"
            statusSummary = "Audio output failed"
        }
    }

    func startKeepalive() {
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
        } catch {
            lastError = "Keepalive session category failed: \(error.localizedDescription)"
            statusSummary = "Keepalive failed"
            return
        }

        do {
            try session.setActive(true)
            updateRouteSummary()
            updateKeepaliveState(isActive: true)

            if engine.isRunning == false {
                try engine.start()
            }

            if playerNode.isPlaying == false {
                playerNode.play()
            }

            ensureSchedulingLoop()
            topOffBuffers()
            statusSummary = "Background keepalive active"
            lastError = nil
        } catch {
            lastError = "Keepalive audio start failed: \(error.localizedDescription)"
            statusSummary = "Keepalive failed"
        }
    }

    func stop() {
        schedulingTask?.cancel()
        schedulingTask = nil
        scheduledBufferCount = 0
        updateActive(false)
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }

        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            lastError = error.localizedDescription
        }

        statusSummary = "Idle"
    }

    func seek(to position: TimeInterval) {
        stateLock.lock()
        playbackState.position = position
        playbackState.sampleCursor = 0
        playbackState.phaseA = 0
        playbackState.phaseB = 0
        stateLock.unlock()

        guard playerNode.isPlaying else { return }
        scheduledBufferCount = 0
        playerNode.stop()
        playerNode.play()
        topOffBuffers()
    }

    private func configureEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: renderFormat)
        engine.prepare()
    }

    private func ensureSchedulingLoop() {
        guard schedulingTask == nil else { return }
        schedulingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run {
                    self.topOffBuffers()
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func topOffBuffers() {
        guard playbackState.isActive else { return }
        while scheduledBufferCount < targetBufferedChunkCount {
            guard let buffer = makeBuffer() else { break }
            scheduledBufferCount += 1
            playerNode.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
                    if self.playbackState.isActive {
                        self.topOffBuffers()
                    }
                }
            }
        }
    }

    private func makeBuffer() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: renderFormat,
            frameCapacity: chunkFrameCount
        ) else {
            return nil
        }

        buffer.frameLength = chunkFrameCount
        guard let channels = buffer.floatChannelData else { return nil }
        let leftBuffer = channels[0]
        let rightBuffer = channels[1]

        let sampleRate = renderFormat.sampleRate
        let twoPi = Double.pi * 2

        stateLock.lock()
        var state = playbackState
        stateLock.unlock()

        for frame in 0..<Int(chunkFrameCount) {
            guard state.isActive else {
                leftBuffer[frame] = 0
                rightBuffer[frame] = 0
                continue
            }

            guard state.mode == .output, let source = state.source else {
                leftBuffer[frame] = 0
                rightBuffer[frame] = 0
                state.sampleCursor += 1
                continue
            }

            let absoluteTime = state.position + (state.sampleCursor / sampleRate)
            let pulse: Pulse
            if let duration = source.duration, duration > 0 {
                if source.shouldLoop {
                    pulse = source.pulse(at: absoluteTime.truncatingRemainder(dividingBy: duration))
                } else if absoluteTime >= duration {
                    leftBuffer[frame] = 0
                    rightBuffer[frame] = 0
                    state.isActive = false
                    continue
                } else {
                    pulse = source.pulse(at: absoluteTime)
                }
            } else {
                pulse = source.pulse(at: absoluteTime)
            }

            let frequencySpan = max(state.maxFrequency - state.minFrequency, 0)
            let frequencyA = state.minFrequency + frequencySpan * Double(pulse.freqA)
            let frequencyB = state.minFrequency + frequencySpan * Double(pulse.freqB)
            let amplitudeA = Double(pulse.ampA) * state.gainA
            let amplitudeB = Double(pulse.ampB) * state.gainB

            state.phaseA += twoPi * max(frequencyA, 1) / sampleRate
            state.phaseB += twoPi * max(frequencyB, 1) / sampleRate

            if state.phaseA >= twoPi { state.phaseA.formTruncatingRemainder(dividingBy: twoPi) }
            if state.phaseB >= twoPi { state.phaseB.formTruncatingRemainder(dividingBy: twoPi) }

            leftBuffer[frame] = Float(sin(state.phaseA) * amplitudeA)
            rightBuffer[frame] = Float(sin(state.phaseB) * amplitudeB)
            state.sampleCursor += 1
        }

        stateLock.lock()
        playbackState = state
        stateLock.unlock()
        return buffer
    }

    private func updateState(
        source: any PulseSource,
        position: TimeInterval,
        minFrequency: Double,
        maxFrequency: Double,
        powerA: Int,
        powerB: Int,
        resetPlaybackCursor: Bool,
        isActive: Bool,
        mode: Mode
    ) {
        stateLock.lock()
        playbackState.source = source
        playbackState.minFrequency = minFrequency
        playbackState.maxFrequency = maxFrequency
        playbackState.gainA = Self.channelGain(for: powerA)
        playbackState.gainB = Self.channelGain(for: powerB)
        playbackState.isActive = isActive
        playbackState.mode = mode

        if resetPlaybackCursor {
            playbackState.position = position
            playbackState.sampleCursor = 0
            playbackState.phaseA = 0
            playbackState.phaseB = 0
        }
        stateLock.unlock()
    }

    private func updateActive(_ isActive: Bool) {
        stateLock.lock()
        playbackState.isActive = isActive
        if isActive == false {
            playbackState.mode = .idle
            playbackState.source = nil
        }
        stateLock.unlock()
    }

    private func updateKeepaliveState(isActive: Bool) {
        stateLock.lock()
        playbackState.isActive = isActive
        playbackState.mode = isActive ? .keepalive : .idle
        playbackState.source = nil
        if isActive {
            playbackState.sampleCursor = 0
            playbackState.phaseA = 0
            playbackState.phaseB = 0
        }
        stateLock.unlock()
    }

    @objc
    private func handleRouteChange(_: Notification) {
        updateRouteSummary()
    }

    private func updateRouteSummary() {
        let outputs = session.currentRoute.outputs.map(\.portName)
        routeSummary = outputs.isEmpty ? "No active route" : outputs.joined(separator: ", ")
    }

    private static func channelGain(for power: Int) -> Double {
        let normalized = Double(power.clamped(to: 0...200)) / 200.0
        return normalized * 0.3
    }
}

private extension BinaryInteger {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
