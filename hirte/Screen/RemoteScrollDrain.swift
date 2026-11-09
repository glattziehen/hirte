import Foundation

/// Native motion and received-row evidence, with an explicit clock for deterministic tests.
/// This only drains already received distance; it never advances beyond the authoritative frame.
struct RemoteScrollDrain {
    private struct Distance {
        var time: TimeInterval
        var native: CGFloat
        var arrived: CGFloat
    }
    private var distances: [Distance] = []
    private var nativeOffset: CGFloat?
    private var nativeTime: TimeInterval?
    private(set) var velocity: CGFloat = 0

    mutating func begin(at offset: CGFloat, time: TimeInterval) {
        nativeOffset = offset
        nativeTime = time
        velocity = 0
    }

    mutating func moved(to offset: CGFloat, time: TimeInterval) {
        if let previous = nativeOffset, let previousTime = nativeTime, time > previousTime {
            let dt = time - previousTime
            let delta = offset - previous
            velocity += (delta / dt - velocity) * (1 - exp(-dt / 0.03))
            distances.append(Distance(time: time, native: abs(delta), arrived: 0))
        }
        nativeOffset = offset
        nativeTime = time
        prune(at: time)
    }

    mutating func arrived(rows: Int, cellHeight: CGFloat, time: TimeInterval) {
        distances.append(Distance(time: time, native: 0, arrived: CGFloat(abs(rows)) * cellHeight))
        prune(at: time)
    }

    mutating func stop() {
        velocity = 0
        nativeOffset = nil
        nativeTime = nil
    }

    private mutating func prune(at time: TimeInterval) {
        distances.removeAll { $0.time < time - 0.5 }
    }

    func gain(cellHeight: CGFloat) -> CGFloat {
        let arrived = distances.reduce(0) { $0 + $1.arrived }
        let native = distances.reduce(0) { $0 + $1.native }
        guard arrived >= 3 * cellHeight, native > 0 else { return 1 }
        return min(4, max(0.25, arrived / native))
    }

    mutating func remaining(offset: CGFloat, cellHeight: CGFloat, time: TimeInterval, dt: TimeInterval) -> CGFloat {
        prune(at: time)
        return Self.remaining(offset: offset, cellHeight: cellHeight, velocity: velocity,
                              velocityAge: nativeTime.map { time - $0 } ?? .infinity,
                              gain: gain(cellHeight: cellHeight), dt: dt)
    }

    static func remaining(offset: CGFloat, cellHeight: CGFloat, velocity: CGFloat,
                          velocityAge: TimeInterval, gain: CGFloat = 1, dt: TimeInterval) -> CGFloat {
        let dt = max(0, dt)
        guard abs(velocity) >= 25, velocityAge >= 0, velocityAge < 0.05,
              offset * velocity > 0 else { return offset * exp(-dt / 0.04) }
        let backlog = abs(offset)
        let speed = abs(velocity)
        let goal = cellHeight / 2 + min(speed * 0.015, 1.5 * cellHeight)
        // A gain below 1 keeps the band behind a program that ignores reports; above the
        // goal it would let the backlog grow into the snap limit at the start of a fling.
        let gain = backlog > goal ? max(gain, 1) : gain
        let rate = max(speed * gain + (backlog - goal) / 0.25,
                       (backlog - 2 * cellHeight) / 0.04, 0)
        let remaining = backlog - min(backlog, rate * dt)
        return offset > 0 ? remaining : -remaining
    }
}
