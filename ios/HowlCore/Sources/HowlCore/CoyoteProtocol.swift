import Foundation

public enum Coyote3Protocol {
    public static let mainServiceUUID = UUID(uuidString: "0000180C-0000-1000-8000-00805f9b34fb")!
    public static let writeCharacteristicUUID = UUID(uuidString: "0000150A-0000-1000-8000-00805f9b34fb")!
    public static let notifyCharacteristicUUID = UUID(uuidString: "0000150B-0000-1000-8000-00805f9b34fb")!

    public static func pulsePacket(
        pulse: Pulse,
        powerA: Int,
        powerB: Int,
        minFrequency: Double,
        maxFrequency: Double,
        previousPowerA: Int? = nil,
        previousPowerB: Int? = nil
    ) -> Data {
        let strengthByte: UInt8
        if powerA != previousPowerA || powerB != previousPowerB {
            strengthByte = 0x1F
        } else {
            strengthByte = 0x00
        }

        let frequencySpan = maxFrequency - minFrequency
        let channelAFrequency = frequencyToCoyote(minFrequency + frequencySpan * Double(pulse.freqA))
        let channelBFrequency = frequencyToCoyote(minFrequency + frequencySpan * Double(pulse.freqB))
        let amplitudeA = UInt8((Double(pulse.ampA) * 100).rounded().clamped(to: 0...100))
        let amplitudeB = UInt8((Double(pulse.ampB) * 100).rounded().clamped(to: 0...100))

        return Data([
            0xB0,
            strengthByte,
            UInt8(powerA.clamped(to: 0...200)),
            UInt8(powerB.clamped(to: 0...200)),
            channelAFrequency,
            amplitudeA,
            channelBFrequency,
            amplitudeB
        ])
    }

    public static func parameterPacket(
        limitA: Int,
        limitB: Int,
        frequencyBalanceA: Int = 200,
        frequencyBalanceB: Int = 200,
        intensityBalanceA: Int = 0,
        intensityBalanceB: Int = 0
    ) -> Data {
        Data([
            0xBF,
            UInt8(limitA.clamped(to: 0...200)),
            UInt8(limitB.clamped(to: 0...200)),
            UInt8(frequencyBalanceA.clamped(to: 0...255)),
            UInt8(frequencyBalanceB.clamped(to: 0...255)),
            UInt8(intensityBalanceA.clamped(to: 0...255)),
            UInt8(intensityBalanceB.clamped(to: 0...255))
        ])
    }

    private static func frequencyToCoyote(_ frequency: Double) -> UInt8 {
        let period = 1_000 / frequency
        let converted: Double
        switch period {
        case 5...100:
            converted = period
        case 100...600:
            converted = ((period - 100) / 5) + 100
        case 600...1_000:
            converted = ((period - 600) / 10) + 200
        default:
            converted = 10
        }

        return UInt8(Int(converted.rounded()).clamped(to: 5...240))
    }
}

public enum Coyote2Protocol {
    public static let mainServiceUUID = UUID(uuidString: "955A180B-0FE2-F5AA-A094-84B8D4F3E8AD")!
    public static let powerCharacteristicUUID = UUID(uuidString: "955A1504-0FE2-F5AA-A094-84B8D4F3E8AD")!
    public static let patternACharacteristicUUID = UUID(uuidString: "955A1506-0FE2-F5AA-A094-84B8D4F3E8AD")!
    public static let patternBCharacteristicUUID = UUID(uuidString: "955A1505-0FE2-F5AA-A094-84B8D4F3E8AD")!

    public static func powerPacket(powerA: Int, powerB: Int) -> Data {
        let devicePowerA = (powerA.clamped(to: 0...200) * 7).clamped(to: 0...2_047)
        let devicePowerB = (powerB.clamped(to: 0...200) * 7).clamped(to: 0...2_047)
        let packed = (devicePowerA << 11) | devicePowerB
        return Data([
            UInt8(packed & 0xFF),
            UInt8((packed >> 8) & 0xFF),
            UInt8((packed >> 16) & 0xFF)
        ])
    }
}

private extension BinaryFloatingPoint {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension BinaryInteger {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
