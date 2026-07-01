import Foundation

public struct RawDelta: Equatable, Sendable {
    public let dx: Int
    public let dy: Int

    public init(dx: Int, dy: Int) {
        self.dx = dx
        self.dy = dy
    }
}

public struct TransformedDelta: Equatable, Sendable {
    public let dx: Int
    public let dy: Int
    public let magnitude: Int
    public let lookupMagnitude: Int
    public let gain: Double
    public let remainderX: Double
    public let remainderY: Double

    public init(dx: Int, dy: Int, magnitude: Int, lookupMagnitude: Int, gain: Double, remainderX: Double, remainderY: Double) {
        self.dx = dx
        self.dy = dy
        self.magnitude = magnitude
        self.lookupMagnitude = lookupMagnitude
        self.gain = gain
        self.remainderX = remainderX
        self.remainderY = remainderY
    }
}

public enum PointerAccelerationError: Error, CustomStringConvertible {
    case invalidSensitivity(Double)
    case invalidInputScale(Double)

    public var description: String {
        switch self {
        case .invalidSensitivity(let sensitivity):
            return "sensitivity must be finite and greater than 0, got \(sensitivity)"
        case .invalidInputScale(let inputScale):
            return "input-scale must be finite and greater than 0, got \(inputScale)"
        }
    }
}

public struct PointerAccelerationConfig: Equatable, Sendable {
    public let speed: Int
    public let sensitivity: Double
    public let inputScale: Double

    public init(speed: Int = 6, sensitivity: Double = 1.0, inputScale: Double = 1.0) throws {
        guard (1...11).contains(speed) else {
            throw EPPTableError.invalidSpeed(speed)
        }
        guard sensitivity.isFinite, sensitivity > 0 else {
            throw PointerAccelerationError.invalidSensitivity(sensitivity)
        }
        guard inputScale.isFinite, inputScale > 0 else {
            throw PointerAccelerationError.invalidInputScale(inputScale)
        }
        self.speed = speed
        self.sensitivity = sensitivity
        self.inputScale = inputScale
    }
}

public final class PointerAccelerator {
    public let table: EPPTable
    public let config: PointerAccelerationConfig

    private var previousRawX = 0
    private var previousRawY = 0
    private var remainderX = 0.0
    private var remainderY = 0.0

    public init(table: EPPTable, config: PointerAccelerationConfig) {
        self.table = table
        self.config = config
    }

    public convenience init(config: PointerAccelerationConfig) throws {
        let table = try EPPTableLoader.load(speed: config.speed)
        self.init(table: table, config: config)
    }

    public func reset() {
        previousRawX = 0
        previousRawY = 0
        remainderX = 0
        remainderY = 0
    }

    public func transform(_ raw: RawDelta) -> TransformedDelta {
        if raw.dx != 0 {
            if sign(raw.dx) != sign(previousRawX) {
                remainderX = 0
            }
            previousRawX = raw.dx
        }

        if raw.dy != 0 {
            if sign(raw.dy) != sign(previousRawY) {
                remainderY = 0
            }
            previousRawY = raw.dy
        }

        let magnitude = Int(floor(sqrt(Double(raw.dx * raw.dx + raw.dy * raw.dy))))
        let lookupMagnitude = scaledLookupMagnitude(for: magnitude)
        let gain = table.gain(forMagnitude: lookupMagnitude) * config.sensitivity

        let transformedX = Double(raw.dx) * gain + remainderX
        let transformedY = Double(raw.dy) * gain + remainderY

        let outputX = truncTowardZero(transformedX)
        let outputY = truncTowardZero(transformedY)

        remainderX = transformedX - Double(outputX)
        remainderY = transformedY - Double(outputY)

        return TransformedDelta(
            dx: outputX,
            dy: outputY,
            magnitude: magnitude,
            lookupMagnitude: lookupMagnitude,
            gain: gain,
            remainderX: remainderX,
            remainderY: remainderY
        )
    }

    private func scaledLookupMagnitude(for magnitude: Int) -> Int {
        guard magnitude > 0 else {
            return 0
        }
        return max(1, Int(floor(Double(magnitude) * config.inputScale)))
    }

    private func sign(_ value: Int) -> Int {
        value > 0 ? 1 : -1
    }

    private func truncTowardZero(_ value: Double) -> Int {
        value >= 0 ? Int(floor(value)) : Int(ceil(value))
    }
}
