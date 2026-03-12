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

public struct HWLPulseSource: PulseSource {
    public let displayName: String
    public let pulses: [Pulse]
    public let duration: TimeInterval?
    public let shouldLoop = true

    public init(data: Data, displayName: String) throws {
        let pulses = try HWLFile.read(from: data)
        self.displayName = displayName
        self.pulses = pulses
        self.duration = Double(pulses.count) * HWLFile.pulseDuration
    }

    public func pulse(at time: TimeInterval) -> Pulse {
        guard !pulses.isEmpty else { return .silence }

        let totalDuration = Double(pulses.count) * HWLFile.pulseDuration
        if time <= 0 { return pulses[0] }
        if time >= totalDuration { return pulses[pulses.count - 1] }

        let index = time / HWLFile.pulseDuration
        let lowerIndex = Int(index)
        guard lowerIndex < pulses.count - 1 else {
            return pulses[pulses.count - 1]
        }

        let upperIndex = lowerIndex + 1
        let lowerTime = Double(lowerIndex) * HWLFile.pulseDuration
        let upperTime = Double(upperIndex) * HWLFile.pulseDuration
        let lowerPulse = pulses[lowerIndex]
        let upperPulse = pulses[upperIndex]

        return Pulse(
            ampA: Float(linearInterpolate(t: time, t0: lowerTime, p0: Double(lowerPulse.ampA), t1: upperTime, p1: Double(upperPulse.ampA))),
            ampB: Float(linearInterpolate(t: time, t0: lowerTime, p0: Double(lowerPulse.ampB), t1: upperTime, p1: Double(upperPulse.ampB))),
            freqA: Float(linearInterpolate(t: time, t0: lowerTime, p0: Double(lowerPulse.freqA), t1: upperTime, p1: Double(upperPulse.freqA))),
            freqB: Float(linearInterpolate(t: time, t0: lowerTime, p0: Double(lowerPulse.freqB), t1: upperTime, p1: Double(upperPulse.freqB)))
        )
    }
}
