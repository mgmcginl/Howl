import AVFoundation
import Foundation

@MainActor
final class AudioOutputEngine: NSObject, ObservableObject {
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
    }

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private lazy var sourceNode = makeSourceNode()

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
                options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
            updateRouteSummary()
            updateState(
                source: source,
                position: position,
                minFrequency: minFrequency,
                maxFrequency: maxFrequency,
                powerA: powerA,
                powerB: powerB,
                resetPhase: false,
                isActive: true
            )

            if engine.isRunning == false {
                try engine.start()
            }

            statusSummary = "Audio output active"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            statusSummary = "Audio output failed"
        }
    }

    func stop() {
        updateActive(false)
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
    }

    private var playbackState = PlaybackState()

    private func configureEngine() {
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let preferredFormat = AVAudioFormat(
            standardFormatWithSampleRate: max(outputFormat.sampleRate, 44_100),
            channels: 2
        )!

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: preferredFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: preferredFormat)
        engine.prepare()
    }

    private func makeSourceNode() -> AVAudioSourceNode {
        AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            return self.render(frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }

    private func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let leftBuffer = ablPointer[safe: 0]?.mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        let rightBuffer = ablPointer.count > 1
            ? ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
            : nil

        let sampleRate = max(engine.outputNode.outputFormat(forBus: 0).sampleRate, 44_100)
        let twoPi = Double.pi * 2

        stateLock.lock()
        var state = playbackState
        stateLock.unlock()

        for frame in 0..<Int(frameCount) {
            guard state.isActive, let source = state.source else {
                leftBuffer[frame] = 0
                rightBuffer?[frame] = 0
                continue
            }

            let absoluteTime = state.position + (state.sampleCursor / sampleRate)
            let pulse: Pulse
            if let duration = source.duration, duration > 0 {
                if source.shouldLoop {
                    pulse = source.pulse(at: absoluteTime.truncatingRemainder(dividingBy: duration))
                } else if absoluteTime >= duration {
                    leftBuffer[frame] = 0
                    rightBuffer?[frame] = 0
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

            let sampleA = Float(sin(state.phaseA) * amplitudeA)
            let sampleB = Float(sin(state.phaseB) * amplitudeB)
            leftBuffer[frame] = sampleA
            rightBuffer?[frame] = sampleB
            state.sampleCursor += 1
        }

        stateLock.lock()
        playbackState = state
        stateLock.unlock()
        return noErr
    }

    private func updateState(
        source: any PulseSource,
        position: TimeInterval,
        minFrequency: Double,
        maxFrequency: Double,
        powerA: Int,
        powerB: Int,
        resetPhase: Bool,
        isActive: Bool
    ) {
        stateLock.lock()
        playbackState.source = source
        playbackState.position = position
        playbackState.sampleCursor = 0
        playbackState.minFrequency = minFrequency
        playbackState.maxFrequency = maxFrequency
        playbackState.gainA = Self.channelGain(for: powerA)
        playbackState.gainB = Self.channelGain(for: powerB)
        playbackState.isActive = isActive
        if resetPhase {
            playbackState.phaseA = 0
            playbackState.phaseB = 0
        }
        stateLock.unlock()
    }

    private func updateActive(_ isActive: Bool) {
        stateLock.lock()
        playbackState.isActive = isActive
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

private extension UnsafeMutableAudioBufferListPointer {
    subscript(safe index: Int) -> AudioBuffer? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private extension BinaryInteger {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
