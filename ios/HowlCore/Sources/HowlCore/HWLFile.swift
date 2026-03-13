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

    public static func analyze(_ pulses: [Pulse]) -> HWLAnalysis {
        guard !pulses.isEmpty else {
            return HWLAnalysis(
                pulseCount: 0,
                duration: 0,
                averageAmplitudeA: 0,
                averageAmplitudeB: 0,
                peakAmplitudeA: 0,
                peakAmplitudeB: 0,
                averageFrequencyA: 0,
                averageFrequencyB: 0,
                activeRatio: 0,
                abruptness: 0,
                channelDifference: 0
            )
        }

        let pulseCount = pulses.count
        let duration = Double(pulseCount) * pulseDuration

        let averageAmplitudeA = pulses.reduce(0.0) { $0 + Double($1.ampA) } / Double(pulseCount)
        let averageAmplitudeB = pulses.reduce(0.0) { $0 + Double($1.ampB) } / Double(pulseCount)
        let peakAmplitudeA = pulses.map(\.ampA).max().map(Double.init) ?? 0
        let peakAmplitudeB = pulses.map(\.ampB).max().map(Double.init) ?? 0
        let averageFrequencyA = pulses.reduce(0.0) { $0 + Double($1.freqA) } / Double(pulseCount)
        let averageFrequencyB = pulses.reduce(0.0) { $0 + Double($1.freqB) } / Double(pulseCount)
        let activeRatio = Double(
            pulses.filter { $0.ampA > 0.12 || $0.ampB > 0.12 }.count
        ) / Double(pulseCount)

        let abruptness: Double
        let channelDifference: Double

        if pulses.count > 1 {
            let transitions = zip(pulses, pulses.dropFirst())
            abruptness = transitions.reduce(0.0) { partial, pair in
                let amplitudeStep =
                    abs(Double(pair.1.ampA - pair.0.ampA))
                    + abs(Double(pair.1.ampB - pair.0.ampB))
                let frequencyStep =
                    abs(Double(pair.1.freqA - pair.0.freqA))
                    + abs(Double(pair.1.freqB - pair.0.freqB))
                return partial + (amplitudeStep * 0.7) + (frequencyStep * 0.3)
            } / Double(pulseCount - 1)

            channelDifference = pulses.reduce(0.0) { partial, pulse in
                partial
                    + abs(Double(pulse.ampA - pulse.ampB)) * 0.65
                    + abs(Double(pulse.freqA - pulse.freqB)) * 0.35
            } / Double(pulseCount)
        } else {
            abruptness = 0
            channelDifference =
                abs(Double(pulses[0].ampA - pulses[0].ampB)) * 0.65
                + abs(Double(pulses[0].freqA - pulses[0].freqB)) * 0.35
        }

        return HWLAnalysis(
            pulseCount: pulseCount,
            duration: duration,
            averageAmplitudeA: averageAmplitudeA,
            averageAmplitudeB: averageAmplitudeB,
            peakAmplitudeA: peakAmplitudeA,
            peakAmplitudeB: peakAmplitudeB,
            averageFrequencyA: averageFrequencyA,
            averageFrequencyB: averageFrequencyB,
            activeRatio: activeRatio,
            abruptness: abruptness,
            channelDifference: channelDifference
        )
    }

    public static func derive(_ pulses: [Pulse], profile: HWLDerivedProfile) -> [Pulse] {
        guard pulses.count > 1 else { return pulses }

        let amplitudeA = movingAverage(pulses.map { Double($0.ampA) }, radius: profile.amplitudeWindowRadius)
        let amplitudeB = movingAverage(pulses.map { Double($0.ampB) }, radius: profile.amplitudeWindowRadius)
        let frequencyA = movingAverage(pulses.map { Double($0.freqA) }, radius: profile.frequencyWindowRadius)
        let frequencyB = movingAverage(pulses.map { Double($0.freqB) }, radius: profile.frequencyWindowRadius)

        var derived: [Pulse] = []
        derived.reserveCapacity(pulses.count)

        for index in pulses.indices {
            let mixedAmplitudeA = blendChannel(
                primary: amplitudeA[index],
                secondary: amplitudeB[index],
                blend: profile.channelBlend
            )
            let mixedAmplitudeB = blendChannel(
                primary: amplitudeB[index],
                secondary: amplitudeA[index],
                blend: profile.channelBlend
            )
            let mixedFrequencyA = blendChannel(
                primary: frequencyA[index],
                secondary: frequencyB[index],
                blend: profile.channelBlend * 0.5
            )
            let mixedFrequencyB = blendChannel(
                primary: frequencyB[index],
                secondary: frequencyA[index],
                blend: profile.channelBlend * 0.5
            )

            let ampA = shapeAmplitude(mixedAmplitudeA, profile: profile)
            let ampB = shapeAmplitude(mixedAmplitudeB, profile: profile)
            let freqA = shapeFrequency(mixedFrequencyA, profile: profile)
            let freqB = shapeFrequency(mixedFrequencyB, profile: profile)

            derived.append(
                Pulse(
                    ampA: Float(ampA.clamped(to: 0...1)),
                    ampB: Float(ampB.clamped(to: 0...1)),
                    freqA: Float(freqA.clamped(to: 0...1)),
                    freqB: Float(freqB.clamped(to: 0...1))
                )
            )
        }

        return applySlewLimit(to: derived, amplitudeLimit: profile.amplitudeSlewLimit, frequencyLimit: profile.frequencySlewLimit)
    }

    private static func movingAverage(_ values: [Double], radius: Int) -> [Double] {
        guard radius > 0, values.count > 2 else { return values }

        return values.indices.map { index in
            let lower = max(0, index - radius)
            let upper = min(values.count - 1, index + radius)
            let slice = values[lower...upper]
            return slice.reduce(0.0, +) / Double(slice.count)
        }
    }

    private static func blendChannel(primary: Double, secondary: Double, blend: Double) -> Double {
        primary * (1 - blend) + secondary * blend
    }

    private static func shapeAmplitude(_ value: Double, profile: HWLDerivedProfile) -> Double {
        let powered = pow(value.clamped(to: 0...1), profile.amplitudeGamma)
        return (powered * profile.amplitudeBoost).clamped(to: 0...profile.amplitudeCeiling)
    }

    private static func shapeFrequency(_ value: Double, profile: HWLDerivedProfile) -> Double {
        let centered = pow(value.clamped(to: 0...1), profile.frequencyGamma)
        return (centered * profile.frequencyScale).clamped(to: 0...1)
    }

    private static func applySlewLimit(
        to pulses: [Pulse],
        amplitudeLimit: Double,
        frequencyLimit: Double
    ) -> [Pulse] {
        guard pulses.count > 1 else { return pulses }

        var limited = pulses

        for index in 1..<limited.count {
            limited[index].ampA = Float(limitStep(
                current: Double(limited[index].ampA),
                previous: Double(limited[index - 1].ampA),
                maxDelta: amplitudeLimit
            ))
            limited[index].ampB = Float(limitStep(
                current: Double(limited[index].ampB),
                previous: Double(limited[index - 1].ampB),
                maxDelta: amplitudeLimit
            ))
            limited[index].freqA = Float(limitStep(
                current: Double(limited[index].freqA),
                previous: Double(limited[index - 1].freqA),
                maxDelta: frequencyLimit
            ))
            limited[index].freqB = Float(limitStep(
                current: Double(limited[index].freqB),
                previous: Double(limited[index - 1].freqB),
                maxDelta: frequencyLimit
            ))
        }

        return limited
    }

    private static func limitStep(current: Double, previous: Double, maxDelta: Double) -> Double {
        let delta = (current - previous).clamped(to: -maxDelta...maxDelta)
        return (previous + delta).clamped(to: 0...1)
    }
}

public enum HWLDerivedProfile: String, CaseIterable, Identifiable, Sendable {
    case comfort = "Comfort"
    case smooth = "Smooth"
    case punchy = "Punchy"

    public var id: String { rawValue }

    public var detail: String {
        switch self {
        case .comfort:
            return "Softens peaks, narrows the top end, and calms abrupt transitions."
        case .smooth:
            return "Lightly smooths the original without flattening it too much."
        case .punchy:
            return "Keeps contrast and energy while shaving the harshest steps."
        }
    }

    fileprivate var amplitudeWindowRadius: Int {
        switch self {
        case .comfort: return 3
        case .smooth: return 2
        case .punchy: return 1
        }
    }

    fileprivate var frequencyWindowRadius: Int {
        switch self {
        case .comfort: return 4
        case .smooth: return 2
        case .punchy: return 1
        }
    }

    fileprivate var amplitudeBoost: Double {
        switch self {
        case .comfort: return 0.96
        case .smooth: return 1.0
        case .punchy: return 1.08
        }
    }

    fileprivate var amplitudeCeiling: Double {
        switch self {
        case .comfort: return 0.9
        case .smooth: return 0.97
        case .punchy: return 1.0
        }
    }

    fileprivate var amplitudeGamma: Double {
        switch self {
        case .comfort: return 1.08
        case .smooth: return 1.0
        case .punchy: return 0.92
        }
    }

    fileprivate var frequencyScale: Double {
        switch self {
        case .comfort: return 0.82
        case .smooth: return 0.92
        case .punchy: return 1.02
        }
    }

    fileprivate var frequencyGamma: Double {
        switch self {
        case .comfort: return 1.06
        case .smooth: return 1.0
        case .punchy: return 0.95
        }
    }

    fileprivate var channelBlend: Double {
        switch self {
        case .comfort: return 0.08
        case .smooth: return 0.04
        case .punchy: return 0.02
        }
    }

    fileprivate var amplitudeSlewLimit: Double {
        switch self {
        case .comfort: return 0.12
        case .smooth: return 0.18
        case .punchy: return 0.24
        }
    }

    fileprivate var frequencySlewLimit: Double {
        switch self {
        case .comfort: return 0.1
        case .smooth: return 0.14
        case .punchy: return 0.2
        }
    }
}

public struct HWLAnalysis: Equatable, Sendable {
    public let pulseCount: Int
    public let duration: TimeInterval
    public let averageAmplitudeA: Double
    public let averageAmplitudeB: Double
    public let peakAmplitudeA: Double
    public let peakAmplitudeB: Double
    public let averageFrequencyA: Double
    public let averageFrequencyB: Double
    public let activeRatio: Double
    public let abruptness: Double
    public let channelDifference: Double

    public var tags: [String] {
        var values = ["HWL"]

        if channelDifference > 0.18 {
            values.append("A/B Split")
        } else {
            values.append("A/B Matched")
        }

        if abruptness > 0.24 {
            values.append("Spiky")
        } else if abruptness < 0.08 {
            values.append("Gentle")
        }

        if activeRatio > 0.72 {
            values.append("Dense")
        } else if activeRatio < 0.28 {
            values.append("Sparse")
        }

        return values
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
