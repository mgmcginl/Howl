import Foundation

public enum GeneratorChannelID: String, CaseIterable, Identifiable, Sendable {
    case a
    case b

    public var id: String { rawValue }
    public var label: String { self == .a ? "Channel A" : "Channel B" }
}

public struct GeneratorChannelConfig: Equatable, Sendable {
    public var amplitudeShape: String
    public var frequencyShape: String
    public var minAmplitude: Double
    public var maxAmplitude: Double
    public var minFrequencyNormalized: Double
    public var maxFrequencyNormalized: Double

    public init(
        amplitudeShape: String = "Curvy triangle",
        frequencyShape: String = "Sawtooth",
        minAmplitude: Double = 0.2,
        maxAmplitude: Double = 0.85,
        minFrequencyNormalized: Double = 0.1,
        maxFrequencyNormalized: Double = 0.9
    ) {
        self.amplitudeShape = amplitudeShape
        self.frequencyShape = frequencyShape
        self.minAmplitude = minAmplitude
        self.maxAmplitude = maxAmplitude
        self.minFrequencyNormalized = minFrequencyNormalized
        self.maxFrequencyNormalized = maxFrequencyNormalized
    }
}

public struct GeneratorConfig: Equatable, Sendable {
    public var speed: Double
    public var channelA: GeneratorChannelConfig
    public var channelB: GeneratorChannelConfig

    public init(
        speed: Double = 0.65,
        channelA: GeneratorChannelConfig = GeneratorChannelConfig(),
        channelB: GeneratorChannelConfig = GeneratorChannelConfig(
            amplitudeShape: "Flourish",
            frequencyShape: "Curvy fangs",
            minAmplitude: 0.15,
            maxAmplitude: 0.92,
            minFrequencyNormalized: 0.2,
            maxFrequencyNormalized: 0.95
        )
    ) {
        self.speed = speed
        self.channelA = channelA
        self.channelB = channelB
    }

    public static let `default` = GeneratorConfig()
}

public struct GeneratorPulseSource: PulseSource {
    public let displayName: String
    public let duration: TimeInterval? = nil
    public let shouldLoop = true

    public let config: GeneratorConfig

    public init(config: GeneratorConfig, displayName: String = "Generator") {
        self.config = config
        self.displayName = displayName
    }

    public func pulse(at time: TimeInterval) -> Pulse {
        let phase = time * config.speed
        let channelAPulse = buildChannelPulse(config.channelA, phase: phase)
        let channelBPulse = buildChannelPulse(config.channelB, phase: phase)

        return Pulse(
            ampA: Float(channelAPulse.amplitude),
            ampB: Float(channelBPulse.amplitude),
            freqA: Float(channelAPulse.frequency),
            freqB: Float(channelBPulse.frequency)
        )
    }

    private func buildChannelPulse(_ channel: GeneratorChannelConfig, phase: Double) -> (amplitude: Double, frequency: Double) {
        let amplitudeShape = WaveShape.generatorLibrary.named(channel.amplitudeShape)
        let frequencyShape = WaveShape.generatorLibrary.named(channel.frequencyShape)
        let amplitude = lerp(channel.minAmplitude, channel.maxAmplitude, fraction: amplitudeShape.cyclicalPosition(at: phase))
        let frequency = lerp(
            channel.minFrequencyNormalized,
            channel.maxFrequencyNormalized,
            fraction: frequencyShape.cyclicalPosition(at: phase)
        )
        return (amplitude.clamped(to: 0...1), frequency.clamped(to: 0...1))
    }
}

public enum DemoActivity: String, CaseIterable, Identifiable, Sendable {
    case tease = "Tease"
    case orbit = "Orbit"
    case ladder = "Ladder"

    public var id: String { rawValue }

    public var generatorConfig: GeneratorConfig {
        switch self {
        case .tease:
            return GeneratorConfig(
                speed: 0.42,
                channelA: GeneratorChannelConfig(
                    amplitudeShape: "Gentle attack",
                    frequencyShape: "Curvy triangle",
                    minAmplitude: 0.05,
                    maxAmplitude: 0.8,
                    minFrequencyNormalized: 0.15,
                    maxFrequencyNormalized: 0.6
                ),
                channelB: GeneratorChannelConfig(
                    amplitudeShape: "Flourish",
                    frequencyShape: "Sawtooth",
                    minAmplitude: 0.1,
                    maxAmplitude: 0.92,
                    minFrequencyNormalized: 0.35,
                    maxFrequencyNormalized: 0.95
                )
            )
        case .orbit:
            return GeneratorConfig(
                speed: 0.7,
                channelA: GeneratorChannelConfig(
                    amplitudeShape: "Curvy fangs",
                    frequencyShape: "Rising tide",
                    minAmplitude: 0.15,
                    maxAmplitude: 0.9,
                    minFrequencyNormalized: 0.1,
                    maxFrequencyNormalized: 0.9
                ),
                channelB: GeneratorChannelConfig(
                    amplitudeShape: "Jelly",
                    frequencyShape: "Flourish",
                    minAmplitude: 0.2,
                    maxAmplitude: 0.95,
                    minFrequencyNormalized: 0.15,
                    maxFrequencyNormalized: 0.98
                )
            )
        case .ladder:
            return GeneratorConfig(
                speed: 0.95,
                channelA: GeneratorChannelConfig(
                    amplitudeShape: "Steps",
                    frequencyShape: "Double time",
                    minAmplitude: 0.25,
                    maxAmplitude: 0.92,
                    minFrequencyNormalized: 0.2,
                    maxFrequencyNormalized: 0.85
                ),
                channelB: GeneratorChannelConfig(
                    amplitudeShape: "Triple trouble",
                    frequencyShape: "Tap + slide",
                    minAmplitude: 0.15,
                    maxAmplitude: 1.0,
                    minFrequencyNormalized: 0.15,
                    maxFrequencyNormalized: 1.0
                )
            )
        }
    }
}

public extension WaveShape {
    static let generatorLibrary: [WaveShape] = [
        WaveShape(
            name: "Sawtooth",
            points: [WavePoint(time: 0, position: 0), WavePoint(time: 0.99999, position: 1)],
            interpolation: .linear
        ),
        WaveShape(
            name: "Curvy triangle",
            points: [WavePoint(time: 0, position: 0), WavePoint(time: 0.5, position: 1)],
            interpolation: .hermite
        ),
        WaveShape(
            name: "Flourish",
            points: [
                WavePoint(time: 0, position: 0),
                WavePoint(time: 0.5, position: 0.8, slope: -0.6),
                WavePoint(time: 0.66, position: 0.6, slope: 0.3),
                WavePoint(time: 0.86, position: 1.0, slope: 0),
                WavePoint(time: 0.9, position: 1.0, slope: 0)
            ],
            interpolation: .hermite
        ),
        WaveShape(
            name: "Curvy fangs",
            points: [
                WavePoint(time: 0, position: 0),
                WavePoint(time: 0.35, position: 1),
                WavePoint(time: 0.5, position: 0.5),
                WavePoint(time: 0.65, position: 1)
            ],
            interpolation: .hermite
        ),
        WaveShape(
            name: "Gentle attack",
            points: [WavePoint(time: 0, position: 0), WavePoint(time: 0.75, position: 1)],
            interpolation: .hermite
        ),
        WaveShape(
            name: "Rising tide",
            points: [
                WavePoint(time: 0, position: 0),
                WavePoint(time: 0.1, position: 0.4),
                WavePoint(time: 0.2, position: 0.2),
                WavePoint(time: 0.3, position: 0.6),
                WavePoint(time: 0.4, position: 0.4),
                WavePoint(time: 0.5, position: 0.8),
                WavePoint(time: 0.6, position: 0.6),
                WavePoint(time: 0.7, position: 1),
                WavePoint(time: 0.8, position: 0.8)
            ],
            interpolation: .hermite
        ),
        WaveShape(
            name: "Jelly",
            points: [
                WavePoint(time: 0, position: 0),
                WavePoint(time: 0.2, position: 1),
                WavePoint(time: 0.3, position: 0.7),
                WavePoint(time: 0.4, position: 1),
                WavePoint(time: 0.5, position: 0.7),
                WavePoint(time: 0.6, position: 1),
                WavePoint(time: 0.7, position: 0.7),
                WavePoint(time: 0.8, position: 1)
            ],
            interpolation: .hermite
        ),
        WaveShape(
            name: "Double time",
            points: [
                WavePoint(time: 0, position: 0),
                WavePoint(time: 0.25, position: 1),
                WavePoint(time: 0.5, position: 0),
                WavePoint(time: 0.625, position: 1),
                WavePoint(time: 0.75, position: 0),
                WavePoint(time: 0.875, position: 1)
            ],
            interpolation: .hermite
        ),
        WaveShape(
            name: "Triple trouble",
            points: [
                WavePoint(time: 0, position: 0),
                WavePoint(time: 0.10, position: 0.98, slope: 0.05),
                WavePoint(time: 0.14, position: 1),
                WavePoint(time: 0.28, position: 0),
                WavePoint(time: 0.38, position: 0.98, slope: 0.05),
                WavePoint(time: 0.42, position: 1),
                WavePoint(time: 0.56, position: 0),
                WavePoint(time: 0.66, position: 0.98, slope: 0.05),
                WavePoint(time: 0.7, position: 1),
                WavePoint(time: 0.84, position: 0)
            ],
            interpolation: .hermite
        ),
        WaveShape(
            name: "Tap + slide",
            points: [
                WavePoint(time: 0, position: 1),
                WavePoint(time: 0.09999, position: 1),
                WavePoint(time: 0.1, position: 0),
                WavePoint(time: 0.19999, position: 0),
                WavePoint(time: 0.2, position: 1),
                WavePoint(time: 0.29999, position: 1),
                WavePoint(time: 0.3, position: 0),
                WavePoint(time: 0.39999, position: 0),
                WavePoint(time: 0.4, position: 1),
                WavePoint(time: 0.5, position: 1),
                WavePoint(time: 0.99999, position: 0)
            ],
            interpolation: .linear
        ),
        WaveShape(
            name: "Steps",
            points: [
                WavePoint(time: 0, position: 0),
                WavePoint(time: 0.19999, position: 0),
                WavePoint(time: 0.2, position: 0.25),
                WavePoint(time: 0.39999, position: 0.25),
                WavePoint(time: 0.4, position: 0.5),
                WavePoint(time: 0.59999, position: 0.5),
                WavePoint(time: 0.6, position: 0.75),
                WavePoint(time: 0.79999, position: 0.75),
                WavePoint(time: 0.8, position: 1),
                WavePoint(time: 0.99999, position: 1)
            ],
            interpolation: .linear
        )
    ]
}

private extension Array where Element == WaveShape {
    func named(_ name: String) -> WaveShape {
        first(where: { $0.name == name }) ?? self[0]
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
