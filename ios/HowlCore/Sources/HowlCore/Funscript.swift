import Foundation

public enum FunscriptFrequencyAlgorithm: String, CaseIterable, Sendable {
    case position
    case fixed
}

public struct FunscriptSettings: Sendable {
    public var positionalEffectStrength: Double
    public var volume: Double
    public var frequencyAlgorithm: FunscriptFrequencyAlgorithm
    public var frequencyTimeOffset: Double
    public var fixedFrequencyA: Double
    public var fixedFrequencyB: Double

    public init(
        positionalEffectStrength: Double = 1.0,
        volume: Double = 0.3,
        frequencyAlgorithm: FunscriptFrequencyAlgorithm = .position,
        frequencyTimeOffset: Double = 0,
        fixedFrequencyA: Double = 0.4,
        fixedFrequencyB: Double = 0.6
    ) {
        self.positionalEffectStrength = positionalEffectStrength
        self.volume = volume
        self.frequencyAlgorithm = frequencyAlgorithm
        self.frequencyTimeOffset = frequencyTimeOffset
        self.fixedFrequencyA = fixedFrequencyA
        self.fixedFrequencyB = fixedFrequencyB
    }
}

private struct FunscriptDocument: Decodable {
    struct Action: Decodable {
        let at: Double
        let pos: Double
    }

    let actions: [Action]
}

private struct PositionVelocity: Sendable {
    let time: Double
    let position: Double
    let velocity: Double
}

public struct FunscriptPulseSource: PulseSource {
    public let displayName: String
    public let duration: TimeInterval?
    public let shouldLoop = false
    public let settings: FunscriptSettings

    private let samples: [PositionVelocity]

    public init(
        data: Data,
        displayName: String,
        settings: FunscriptSettings = FunscriptSettings()
    ) throws {
        let decoder = JSONDecoder()
        let document: FunscriptDocument
        do {
            document = try decoder.decode(FunscriptDocument.self, from: data)
        } catch {
            throw HowlCoreError.invalidFunscript
        }

        guard !document.actions.isEmpty else {
            throw HowlCoreError.emptyFunscript
        }

        let rawPositions = document.actions.map(\.pos)
        let minPosition = rawPositions.min() ?? 0
        let maxPosition = rawPositions.max() ?? 100
        let scale = minPosition == maxPosition ? 0.01 : 1 / (maxPosition - minPosition)
        let offset = minPosition == maxPosition ? 0 : -minPosition

        let scaled = document.actions.map { action in
            (
                time: action.at / 1_000,
                position: ((action.pos + offset) * scale).clamped(to: 0...1)
            )
        }

        self.samples = scaled.enumerated().map { index, current in
            let previous = index > 0 ? scaled[index - 1] : nil
            let next = index < scaled.count - 1 ? scaled[index + 1] : nil

            let velocity: Double
            switch (previous, next) {
            case (.none, .none):
                velocity = 0
            case (.none, .some(let next)):
                velocity = (next.position - current.position) / (next.time - current.time)
            case (.some(let previous), .none):
                velocity = (current.position - previous.position) / (current.time - previous.time)
            case (.some(let previous), .some(let next)):
                let previousSlope = (current.position - previous.position) / (current.time - previous.time)
                let nextSlope = (next.position - current.position) / (next.time - current.time)
                velocity = (previousSlope + nextSlope) * 0.5
            }

            return PositionVelocity(time: current.time, position: current.position, velocity: velocity)
        }

        self.displayName = displayName
        self.duration = samples.last?.time
        self.settings = settings
    }

    public func pulse(at time: TimeInterval) -> Pulse {
        let state = positionVelocityAcceleration(at: time)
        let shiftedPosition = position(at: time + settings.frequencyTimeOffset)
        let amplitude = calculateOverallAmplitude(
            velocity: state.velocity,
            acceleration: state.acceleration,
            exponent: max(1 - settings.volume, 0.001)
        )

        let channelAmplitudes = calculatePositionalEffect(
            amplitude: amplitude,
            position: state.position,
            positionalEffectStrength: settings.positionalEffectStrength
        )

        let frequencies: (Double, Double)
        switch settings.frequencyAlgorithm {
        case .position:
            frequencies = (shiftedPosition, state.position)
        case .fixed:
            frequencies = (settings.fixedFrequencyA, settings.fixedFrequencyB)
        }

        return Pulse(
            ampA: Float(channelAmplitudes.0),
            ampB: Float(channelAmplitudes.1),
            freqA: Float(frequencies.0.clamped(to: 0...1)),
            freqB: Float(frequencies.1.clamped(to: 0...1))
        )
    }

    private func position(at time: Double) -> Double {
        let bounds = neighbourBounds(for: time)
        switch bounds {
        case (nil, nil):
            return 0
        case (nil, let after?):
            return after.position
        case (let before?, nil):
            return before.position
        case (let before?, let after?):
            guard before.time != after.time, before.position != after.position else {
                return before.position
            }
            return hermiteInterpolate(
                t: time,
                t0: before.time,
                p0: before.position,
                m0: before.velocity,
                t1: after.time,
                p1: after.position,
                m1: after.velocity
            ).clamped(to: 0...1)
        }
    }

    private func positionVelocityAcceleration(at time: Double) -> (position: Double, velocity: Double, acceleration: Double) {
        let bounds = neighbourBounds(for: time)
        switch bounds {
        case (nil, nil):
            return (0, 0, 0)
        case (nil, let after?):
            return (after.position, 0, 0)
        case (let before?, nil):
            return (before.position, 0, 0)
        case (let before?, let after?):
            guard before.time != after.time, before.position != after.position else {
                return (before.position, 0, 0)
            }
            let result = hermiteInterpolateWithVelocityAndAcceleration(
                t: time,
                t0: before.time,
                p0: before.position,
                m0: before.velocity,
                t1: after.time,
                p1: after.position,
                m1: after.velocity
            )
            return (
                result.position.clamped(to: 0...1),
                result.velocity,
                result.acceleration
            )
        }
    }

    private func neighbourBounds(for time: Double) -> (PositionVelocity?, PositionVelocity?) {
        guard !samples.isEmpty else { return (nil, nil) }

        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }

        let afterIndex = low < samples.count ? low : nil
        let beforeIndex = low > 0 ? low - 1 : nil
        let before = beforeIndex.map { samples[$0] }
        let after = afterIndex.map { samples[$0] }
        return (before, after)
    }

    private func calculateOverallAmplitude(
        velocity: Double,
        acceleration: Double,
        exponent: Double
    ) -> Double {
        let threshold = 0.005
        let ratio = 0.5
        let maxSpeed = 5.0
        let maxMagnitude = 80.0

        let normalizedSpeed = min(abs(velocity) / maxSpeed, 1)
        let normalizedMagnitude = min(abs(acceleration) / maxMagnitude, 1)
        let rawAmplitude = normalizedSpeed * (1 - ratio) + normalizedMagnitude * ratio
        guard rawAmplitude >= threshold else { return 0 }
        return pow(rawAmplitude, exponent).clamped(to: 0...1)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
