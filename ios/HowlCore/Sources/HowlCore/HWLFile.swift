import Foundation

public enum HWLFile {
    public static let header = "YEAHBOI!"
    public static let pulsesPerSecond = 40.0
    public static let pulseDuration = 1.0 / pulsesPerSecond
    private static let headerByteCount = 8
    private static let pulseByteCount = 16

    public static func read(from data: Data) throws -> [Pulse] {
        guard data.count >= headerByteCount else {
            throw HowlCoreError.invalidHWLHeader
        }

        let headerData = data.prefix(headerByteCount)
        guard String(data: headerData, encoding: .ascii) == header else {
            throw HowlCoreError.invalidHWLHeader
        }

        var pulses: [Pulse] = []
        var offset = headerByteCount
        while offset < data.count {
            guard offset + pulseByteCount <= data.count else {
                throw HowlCoreError.invalidHWLBody
            }

            let ampA = readFloatLE(data, from: offset)
            let ampB = readFloatLE(data, from: offset + 4)
            let freqA = readFloatLE(data, from: offset + 8)
            let freqB = readFloatLE(data, from: offset + 12)
            pulses.append(Pulse(ampA: ampA, ampB: ampB, freqA: freqA, freqB: freqB))
            offset += pulseByteCount
        }

        return pulses
    }

    public static func write(_ pulses: [Pulse]) -> Data {
        var data = Data(header.utf8)
        data.reserveCapacity(headerByteCount + pulses.count * pulseByteCount)

        for pulse in pulses {
            appendFloatLE(pulse.ampA, to: &data)
            appendFloatLE(pulse.ampB, to: &data)
            appendFloatLE(pulse.freqA, to: &data)
            appendFloatLE(pulse.freqB, to: &data)
        }

        return data
    }

    private static func readFloatLE(_ data: Data, from offset: Int) -> Float {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return Float(bitPattern: b0 | b1 | b2 | b3)
    }

    private static func appendFloatLE(_ value: Float, to data: inout Data) {
        let bits = value.bitPattern
        data.append(UInt8(bits & 0xFF))
        data.append(UInt8((bits >> 8) & 0xFF))
        data.append(UInt8((bits >> 16) & 0xFF))
        data.append(UInt8((bits >> 24) & 0xFF))
    }
}

public enum HWLPlaybackProfile: String, CaseIterable, Identifiable, Sendable {
    case faithful = "Faithful"
    case smooth = "Smooth"
    case softened = "Softened"

    public var id: String { rawValue }

    public var detail: String {
        switch self {
        case .faithful:
            return "Closest to the raw 40 Hz file."
        case .smooth:
            return "Gentler interpolation with light smoothing."
        case .softened:
            return "More smoothing for calmer output."
        }
    }
}

public struct HWLSettings: Equatable, Sendable {
    public var profile: HWLPlaybackProfile
    public var interpolationMode: InterpolationMode
    public var amplitudeSmoothingWindow: Double
    public var frequencySmoothingWindow: Double

    public init() {
        self.init(profile: .smooth)
    }

    public init(
        profile: HWLPlaybackProfile = .smooth,
        interpolationMode: InterpolationMode,
        amplitudeSmoothingWindow: Double,
        frequencySmoothingWindow: Double
    ) {
        self.profile = profile
        self.interpolationMode = interpolationMode
        self.amplitudeSmoothingWindow = amplitudeSmoothingWindow
        self.frequencySmoothingWindow = frequencySmoothingWindow
    }

    public init(profile: HWLPlaybackProfile) {
        switch profile {
        case .faithful:
            self.init(
                profile: profile,
                interpolationMode: .linear,
                amplitudeSmoothingWindow: 0,
                frequencySmoothingWindow: 0
            )
        case .smooth:
            self.init(
                profile: profile,
                interpolationMode: .hermite,
                amplitudeSmoothingWindow: HWLFile.pulseDuration * 0.45,
                frequencySmoothingWindow: HWLFile.pulseDuration * 0.3
            )
        case .softened:
            self.init(
                profile: profile,
                interpolationMode: .hermite,
                amplitudeSmoothingWindow: HWLFile.pulseDuration * 0.85,
                frequencySmoothingWindow: HWLFile.pulseDuration * 0.6
            )
        }
    }
}

public struct HWLPulseSource: PulseSource {
    public let displayName: String
    public let pulses: [Pulse]
    public let duration: TimeInterval?
    public let shouldLoop = true
    public let settings: HWLSettings

    private let ampASeries: ChannelSeries
    private let ampBSeries: ChannelSeries
    private let freqASeries: ChannelSeries
    private let freqBSeries: ChannelSeries

    public init(
        data: Data,
        displayName: String,
        settings: HWLSettings = HWLSettings()
    ) throws {
        let pulses = try HWLFile.read(from: data)
        self.displayName = displayName
        self.pulses = pulses
        self.duration = Double(pulses.count) * HWLFile.pulseDuration
        self.settings = settings

        self.ampASeries = ChannelSeries(
            values: pulses.map { Double($0.ampA) },
            sampleDuration: HWLFile.pulseDuration
        )
        self.ampBSeries = ChannelSeries(
            values: pulses.map { Double($0.ampB) },
            sampleDuration: HWLFile.pulseDuration
        )
        self.freqASeries = ChannelSeries(
            values: pulses.map { Double($0.freqA) },
            sampleDuration: HWLFile.pulseDuration
        )
        self.freqBSeries = ChannelSeries(
            values: pulses.map { Double($0.freqB) },
            sampleDuration: HWLFile.pulseDuration
        )
    }

    public func pulse(at time: TimeInterval) -> Pulse {
        guard !pulses.isEmpty else { return .silence }

        return Pulse(
            ampA: Float(ampASeries.value(at: time, settings: settings, smoothingWindow: settings.amplitudeSmoothingWindow)),
            ampB: Float(ampBSeries.value(at: time, settings: settings, smoothingWindow: settings.amplitudeSmoothingWindow)),
            freqA: Float(freqASeries.value(at: time, settings: settings, smoothingWindow: settings.frequencySmoothingWindow)),
            freqB: Float(freqBSeries.value(at: time, settings: settings, smoothingWindow: settings.frequencySmoothingWindow))
        )
    }
}

private struct ChannelSeries: Sendable {
    private let values: [Double]
    private let sampleDuration: Double
    private let slopes: [Double]
    private let lastTime: Double

    init(values: [Double], sampleDuration: Double) {
        self.values = values
        self.sampleDuration = sampleDuration
        self.lastTime = sampleDuration * Double(max(values.count - 1, 0))
        self.slopes = ChannelSeries.computeMonotoneSlopes(values: values, sampleDuration: sampleDuration)
    }

    func value(at time: TimeInterval, settings: HWLSettings, smoothingWindow: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        guard values.count > 1 else { return values[0].clamped(to: 0...1) }

        if smoothingWindow <= 0 {
            return interpolatedValue(at: time, mode: settings.interpolationMode).clamped(to: 0...1)
        }

        let offsets = [-1.0, -0.5, 0, 0.5, 1.0]
        let weights = [1.0, 4.0, 6.0, 4.0, 1.0]
        let weighted = zip(offsets, weights).reduce(0.0) { partial, entry in
            let sampleTime = clampedTime(time + entry.0 * smoothingWindow)
            let value = interpolatedValue(at: sampleTime, mode: settings.interpolationMode)
            return partial + value * entry.1
        }

        return (weighted / weights.reduce(0, +)).clamped(to: 0...1)
    }

    private func interpolatedValue(at time: Double, mode: InterpolationMode) -> Double {
        let clamped = clampedTime(time)
        let index = clamped / sampleDuration
        let lowerIndex = Int(index)
        guard lowerIndex < values.count - 1 else {
            return values[values.count - 1]
        }

        let upperIndex = lowerIndex + 1
        let lowerTime = Double(lowerIndex) * sampleDuration
        let upperTime = Double(upperIndex) * sampleDuration

        switch mode {
        case .linear:
            return linearInterpolate(
                t: clamped,
                t0: lowerTime,
                p0: values[lowerIndex],
                t1: upperTime,
                p1: values[upperIndex]
            )
        case .hermite:
            return hermiteInterpolate(
                t: clamped,
                t0: lowerTime,
                p0: values[lowerIndex],
                m0: slopes[lowerIndex],
                t1: upperTime,
                p1: values[upperIndex],
                m1: slopes[upperIndex]
            )
        }
    }

    private func clampedTime(_ time: Double) -> Double {
        time.clamped(to: 0...lastTime)
    }

    private static func computeMonotoneSlopes(values: [Double], sampleDuration: Double) -> [Double] {
        guard values.count >= 2 else {
            return Array(repeating: 0, count: values.count)
        }

        var secants = Array(repeating: 0.0, count: values.count - 1)
        for index in secants.indices {
            secants[index] = (values[index + 1] - values[index]) / sampleDuration
        }

        var slopes = Array(repeating: 0.0, count: values.count)
        slopes[0] = secants[0]
        slopes[values.count - 1] = secants[secants.count - 1]

        if values.count > 2 {
            for index in 1..<(values.count - 1) {
                let previous = secants[index - 1]
                let next = secants[index]
                if previous * next <= 0 {
                    slopes[index] = 0
                } else {
                    slopes[index] = (previous + next) * 0.5
                }
            }
        }

        for index in secants.indices {
            let secant = secants[index]
            guard secant != 0 else {
                slopes[index] = 0
                slopes[index + 1] = 0
                continue
            }

            let a = slopes[index] / secant
            let b = slopes[index + 1] / secant
            let hypotenuse = sqrt(a * a + b * b)
            if hypotenuse > 9 {
                let scale = 3 / hypotenuse
                slopes[index] = scale * a * secant
                slopes[index + 1] = scale * b * secant
            }
        }

        return slopes
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
