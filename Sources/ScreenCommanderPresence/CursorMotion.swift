import CoreGraphics
import Foundation

/// Tuning for the agent cursor's glide. The defaults follow the recipe read
/// from Sky: damping 0.9, a response time that grows with distance and is
/// clamped to 0.12-2.2 s, and a click point at 99.5% progress or ~3 pt.
public struct CursorMotionTuning: Equatable, Sendable {
    public var dampingRatio: Double = 0.9
    public var minimumResponse: Double = 0.12
    public var maximumResponse: Double = 2.2
    /// Response grows with the square root of distance, so long moves stay
    /// quick without short moves looking twitchy.
    public var responsePerRootPoint: Double = 0.02
    /// Moves shorter than this are drawn as a straight line with no arc.
    public var straightLineThreshold: Double = 10
    /// Sideways bow of the Bézier arc as a fraction of distance.
    public var arcFraction: Double = 0.12
    public var maximumArc: Double = 90
    public var closeEnoughProgress: Double = 0.995
    public var closeEnoughDistance: Double = 3
    /// Below these the spring counts as settled and snaps to its target.
    public var settleDisplacement: Double = 0.0005
    public var settleVelocity: Double = 0.005

    public init() {}

    /// Spring response time for a move of `distance` points.
    public func response(forDistance distance: Double) -> Double {
        let raw = minimumResponse + responsePerRootPoint * max(0, distance).squareRoot()
        return min(max(raw, minimumResponse), maximumResponse)
    }
}

/// Cubic Bézier from the cursor's current point to its target.
public struct CursorPath: Equatable, Sendable {
    public var start: CGPoint
    public var control1: CGPoint
    public var control2: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }

    /// Builds the glide path. Short moves are straight. Longer moves bow
    /// gently to one side, always toward the top of the screen, so the
    /// cursor reads as a hand moving rather than a sliding token.
    public init(from start: CGPoint, to end: CGPoint, tuning: CursorMotionTuning = CursorMotionTuning()) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        self.start = start
        self.end = end

        guard distance >= tuning.straightLineThreshold else {
            control1 = CGPoint(x: start.x + dx / 3, y: start.y + dy / 3)
            control2 = CGPoint(x: start.x + dx * 2 / 3, y: start.y + dy * 2 / 3)
            return
        }

        // Unit normal to the chord, flipped so it points up the screen (CG y grows down).
        var nx = -dy / distance
        var ny = dx / distance
        if ny > 0 || (ny == 0 && nx > 0) {
            nx = -nx
            ny = -ny
        }
        let bow = min(distance * tuning.arcFraction, tuning.maximumArc)
        control1 = CGPoint(x: start.x + dx * 0.3 + nx * bow, y: start.y + dy * 0.3 + ny * bow)
        control2 = CGPoint(x: start.x + dx * 0.75 + nx * bow * 0.6, y: start.y + dy * 0.75 + ny * bow * 0.6)
    }

    public var chordLength: Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return (dx * dx + dy * dy).squareRoot()
    }

    public func point(at progress: Double) -> CGPoint {
        let t = min(max(progress, 0), 1)
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return CGPoint(
            x: a * start.x + b * control1.x + c * control2.x + d * end.x,
            y: a * start.y + b * control1.y + c * control2.y + d * end.y
        )
    }
}

/// A damped spring driving a value toward 1. Steps use the closed-form
/// solution, so the result does not depend on frame rate.
public struct CursorSpring: Equatable, Sendable {
    public private(set) var value: Double
    public private(set) var velocity: Double
    public let dampingRatio: Double
    public let response: Double
    public private(set) var isSettled = false

    private let tuning: CursorMotionTuning

    public init(response: Double, tuning: CursorMotionTuning = CursorMotionTuning(), value: Double = 0, velocity: Double = 0) {
        self.response = min(max(response, tuning.minimumResponse), tuning.maximumResponse)
        self.dampingRatio = tuning.dampingRatio
        self.value = value
        self.velocity = velocity
        self.tuning = tuning
    }

    public mutating func step(_ dt: Double) {
        guard !isSettled, dt > 0 else {
            return
        }

        let omega = 2 * Double.pi / response
        let zeta = dampingRatio
        let displacement0 = value - 1
        let velocity0 = velocity
        let displacement: Double
        let newVelocity: Double

        if zeta < 1 {
            let omegaD = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * dt)
            let cosine = cos(omegaD * dt)
            let sine = sin(omegaD * dt)
            let b = (velocity0 + zeta * omega * displacement0) / omegaD
            displacement = decay * (displacement0 * cosine + b * sine)
            newVelocity = decay * (velocity0 * cosine - ((omega * omega * displacement0 + zeta * omega * velocity0) / omegaD) * sine)
        } else {
            // Critically damped fallback for ratios at or above 1.
            let decay = exp(-omega * dt)
            let b = velocity0 + omega * displacement0
            displacement = decay * (displacement0 + b * dt)
            newVelocity = decay * (b - omega * (displacement0 + b * dt))
        }

        value = 1 + displacement
        velocity = newVelocity

        if abs(displacement) < tuning.settleDisplacement && abs(newVelocity) < tuning.settleVelocity {
            value = 1
            velocity = 0
            isSettled = true
        }
    }
}

/// One glide: a path plus the spring that advances along it.
public struct CursorMotion: Equatable, Sendable {
    public let path: CursorPath
    public private(set) var spring: CursorSpring
    public let tuning: CursorMotionTuning

    public init(from start: CGPoint, to end: CGPoint, tuning: CursorMotionTuning = CursorMotionTuning()) {
        let path = CursorPath(from: start, to: end, tuning: tuning)
        self.path = path
        self.tuning = tuning
        self.spring = CursorSpring(response: tuning.response(forDistance: path.chordLength), tuning: tuning)
    }

    /// Progress along the path, clamped to 0...1. The spring's slight
    /// overshoot is absorbed by the clamp, so the drawn position never runs
    /// past the target and never moves backward.
    public var progress: Double {
        min(max(spring.value, 0), 1)
    }

    public var point: CGPoint {
        path.point(at: progress)
    }

    public var remainingDistance: Double {
        let current = point
        let dx = path.end.x - current.x
        let dy = path.end.y - current.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The moment a click may fire.
    public var isCloseEnough: Bool {
        CursorMotion.isCloseEnough(progress: progress, remainingDistance: remainingDistance, tuning: tuning)
    }

    public var isFinished: Bool {
        spring.isSettled
    }

    public mutating func step(_ dt: Double) {
        spring.step(dt)
    }

    public static func isCloseEnough(progress: Double, remainingDistance: Double, tuning: CursorMotionTuning = CursorMotionTuning()) -> Bool {
        progress >= tuning.closeEnoughProgress || remainingDistance <= tuning.closeEnoughDistance
    }
}
