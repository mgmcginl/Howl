import Foundation

public enum InterpolationMode: String, CaseIterable, Sendable {
    case hermite
    case linear
}

public struct WavePoint: Hashable, Sendable {
    public var time: Double
    public var position: Double
    public var slope: Double?

    public init(time: Double, position: Double, slope: Double? = nil) {
        self.time = time
        self.position = position
        self.slope = slope
    }
}

public struct WaveShape: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let points: [WavePoint]
    public let interpolation: InterpolationMode

    public init(name: String, points: [WavePoint], interpolation: InterpolationMode) {
        let sortedPoints = points
            .sorted { $0.time < $1.time }
            .reduce(into: [WavePoint]()) { result, point in
                guard result.last?.time != point.time else { return }
                result.append(point)
            }

        precondition(sortedPoints.count >= 2, "WaveShape requires at least two unique points.")
        precondition(sortedPoints.allSatisfy { $0.time >= 0 && $0.time < 1 }, "Wave points must live in [0, 1).")

        self.id = name
        self.name = name
        self.interpolation = interpolation

        switch interpolation {
        case .linear:
            self.points = sortedPoints
        case .hermite:
            let slopes = WaveShape.computeMonotoneSlopes(sortedPoints)
            self.points = sortedPoints.enumerated().map { index, point in
                WavePoint(time: point.time, position: point.position, slope: point.slope ?? slopes[index])
            }
        }
    }

    public func cyclicalPosition(at normalizedTime: Double) -> Double {
        let phase = normalizedTime.floorWrapped
        let (previous, next) = surroundingPoints(for: phase)
        switch interpolation {
        case .linear:
            return linearInterpolate(
                t: phase,
                t0: previous.time,
                p0: previous.position,
                t1: next.time,
                p1: next.position
            ).clamped(to: 0...1)
        case .hermite:
            return hermiteInterpolate(
                t: phase,
                t0: previous.time,
                p0: previous.position,
                m0: previous.slope ?? 0,
                t1: next.time,
                p1: next.position,
                m1: next.slope ?? 0
            ).clamped(to: 0...1)
        }
    }

    private func surroundingPoints(for phase: Double) -> (WavePoint, WavePoint) {
        if let index = points.lastIndex(where: { $0.time <= phase }) {
            if index == points.count - 1 {
                let previous = points[index]
                let next = WavePoint(time: points[0].time + 1, position: points[0].position, slope: points[0].slope)
                return (previous, next)
            }
            return (points[index], points[index + 1])
        }

        let previous = WavePoint(
            time: points[points.count - 1].time - 1,
            position: points[points.count - 1].position,
            slope: points[points.count - 1].slope
        )
        return (previous, points[0])
    }

    private static func computeMonotoneSlopes(_ points: [WavePoint]) -> [Double] {
        let count = points.count
        var secants = Array(repeating: 0.0, count: count)
        var slopes = Array(repeating: 0.0, count: count)

        for index in 0..<count {
            let nextIndex = (index + 1) % count
            let current = points[index]
            let next = points[nextIndex]
            let deltaTime = index == count - 1 ? (1 + next.time) - current.time : next.time - current.time
            secants[index] = (next.position - current.position) / deltaTime
        }

        for index in 0..<count {
            let previousIndex = index == 0 ? count - 1 : index - 1
            if secants[previousIndex] * secants[index] <= 0 {
                slopes[index] = 0
            } else {
                slopes[index] = (secants[previousIndex] + secants[index]) * 0.5
            }
        }

        for index in 0..<count {
            let nextIndex = (index + 1) % count
            guard secants[index] != 0 else {
                slopes[index] = 0
                slopes[nextIndex] = 0
                continue
            }

            let a = slopes[index] / secants[index]
            let b = slopes[nextIndex] / secants[index]
            let hypotenuse = sqrt(a * a + b * b)
            if hypotenuse > 9 {
                let scale = 3 / hypotenuse
                slopes[index] = scale * a * secants[index]
                slopes[nextIndex] = scale * b * secants[index]
            }
        }

        return slopes
    }
}

public func lerp(_ start: Double, _ end: Double, fraction: Double) -> Double {
    start + ((end - start) * fraction)
}

public func linearInterpolate(
    t: Double,
    t0: Double,
    p0: Double,
    t1: Double,
    p1: Double
) -> Double {
    guard t1 > t0 else { return p0 }
    let phase = (t - t0) / (t1 - t0)
    return p0 + phase * (p1 - p0)
}

public func hermiteInterpolate(
    t: Double,
    t0: Double,
    p0: Double,
    m0: Double,
    t1: Double,
    p1: Double,
    m1: Double
) -> Double {
    guard t1 > t0 else { return p0 }
    let h = (t - t0) / (t1 - t0)
    let hSquared = h * h
    let hCubed = hSquared * h
    return p0 * (2 * hCubed - 3 * hSquared + 1)
        + m0 * (hCubed - 2 * hSquared + h) * (t1 - t0)
        + p1 * (-2 * hCubed + 3 * hSquared)
        + m1 * (hCubed - hSquared) * (t1 - t0)
}

public func hermiteInterpolateWithVelocityAndAcceleration(
    t: Double,
    t0: Double,
    p0: Double,
    m0: Double,
    t1: Double,
    p1: Double,
    m1: Double
) -> (position: Double, velocity: Double, acceleration: Double) {
    let position = hermiteInterpolate(t: t, t0: t0, p0: p0, m0: m0, t1: t1, p1: p1, m1: m1)
    let deltaTime = t1 - t0
    guard deltaTime != 0 else {
        return (position, 0, 0)
    }

    let h = (t - t0) / deltaTime
    let hSquared = h * h
    let dpdh = (6 * hSquared - 6 * h) * p0
        + (3 * hSquared - 4 * h + 1) * m0 * deltaTime
        + (-6 * hSquared + 6 * h) * p1
        + (3 * hSquared - 2 * h) * m1 * deltaTime

    let d2pdh2 = (12 * h - 6) * p0
        + (6 * h - 4) * m0 * deltaTime
        + (-12 * h + 6) * p1
        + (6 * h - 2) * m1 * deltaTime

    return (position, dpdh / deltaTime, d2pdh2 / (deltaTime * deltaTime))
}

public func calculatePositionalEffect(
    amplitude: Double,
    position: Double,
    positionalEffectStrength: Double
) -> (Double, Double) {
    let effectivePosition = 0.5 * (1 - positionalEffectStrength) + position * positionalEffectStrength
    return (
        amplitude * sqrt(1 - effectivePosition),
        amplitude * sqrt(effectivePosition)
    )
}

private extension Double {
    var floorWrapped: Double {
        let remainder = truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
