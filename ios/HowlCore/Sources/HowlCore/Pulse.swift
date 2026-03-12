import Foundation

public struct Pulse: Codable, Equatable, Sendable {
    public var ampA: Float
    public var ampB: Float
    public var freqA: Float
    public var freqB: Float

    public init(
        ampA: Float = 0,
        ampB: Float = 0,
        freqA: Float = 0,
        freqB: Float = 0
    ) {
        self.ampA = ampA
        self.ampB = ampB
        self.freqA = freqA
        self.freqB = freqB
    }

    public static let silence = Pulse()
}

public protocol PulseSource: Sendable {
    var displayName: String { get }
    var duration: TimeInterval? { get }
    var shouldLoop: Bool { get }
    func pulse(at time: TimeInterval) -> Pulse
}

public enum HowlCoreError: LocalizedError {
    case invalidHWLHeader
    case invalidHWLBody
    case emptyFunscript
    case unsupportedFileType(String)
    case invalidFunscript
    case invalidCoyoteBatchSize(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidHWLHeader:
            return "The HWL header is invalid."
        case .invalidHWLBody:
            return "The HWL file is truncated or malformed."
        case .emptyFunscript:
            return "The funscript has no actions."
        case .unsupportedFileType(let ext):
            return "Unsupported file type: \(ext)"
        case .invalidFunscript:
            return "The funscript JSON could not be decoded."
        case .invalidCoyoteBatchSize(let expected, let actual):
            return "Expected \(expected) Coyote pulses but received \(actual)."
        }
    }
}
