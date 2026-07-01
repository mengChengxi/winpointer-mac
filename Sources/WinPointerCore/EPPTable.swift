import Foundation

public enum EPPTableError: Error, CustomStringConvertible {
    case invalidSpeed(Int)
    case missingResource(String)
    case unreadableResource(URL, String)
    case malformedLine(String)
    case missingMaxCounts
    case missingValue(Int)

    public var description: String {
        switch self {
        case .invalidSpeed(let speed):
            return "speed must be in 1...11, got \(speed)"
        case .missingResource(let name):
            return "missing EPP table resource \(name).dat"
        case .unreadableResource(let url, let reason):
            return "could not read \(url.path): \(reason)"
        case .malformedLine(let line):
            return "malformed EPP table line: \(line)"
        case .missingMaxCounts:
            return "EPP table is missing max-counts"
        case .missingValue(let index):
            return "EPP table is missing value for count \(index)"
        }
    }
}

public struct EPPTable: Sendable {
    public let speed: Int
    public let values: [Double]

    public init(speed: Int, values: [Double]) throws {
        guard (1...11).contains(speed) else {
            throw EPPTableError.invalidSpeed(speed)
        }
        self.speed = speed
        self.values = values
    }

    public var maxIndex: Int {
        max(0, values.count - 1)
    }

    public func gain(forMagnitude magnitude: Int) -> Double {
        guard magnitude > 0, values.count > 1 else {
            return 0
        }
        let index = min(magnitude, maxIndex)
        guard index > 0 else {
            return 0
        }
        return values[index] / Double(index)
    }
}

public enum EPPTableLoader {
    public static func load(speed: Int) throws -> EPPTable {
        try load(speed: speed, bundle: .module)
    }

    public static func load(speed: Int, bundle: Bundle) throws -> EPPTable {
        guard (1...11).contains(speed) else {
            throw EPPTableError.invalidSpeed(speed)
        }

        let name = "f\(speed)"
        let url = bundle.url(forResource: name, withExtension: "dat", subdirectory: "EPP")
            ?? bundle.url(forResource: name, withExtension: "dat", subdirectory: "Resources/EPP")
            ?? bundle.url(forResource: name, withExtension: "dat")

        guard let url else {
            throw EPPTableError.missingResource(name)
        }

        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw EPPTableError.unreadableResource(url, error.localizedDescription)
        }

        return try parse(speed: speed, text: text)
    }

    public static func parse(speed: Int, text: String) throws -> EPPTable {
        guard (1...11).contains(speed) else {
            throw EPPTableError.invalidSpeed(speed)
        }

        var maxCounts: Int?
        var parsedValues: [Int: Double] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !line.isEmpty else {
                continue
            }

            let parts = line.split(separator: ":", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard parts.count == 2 else {
                throw EPPTableError.malformedLine(line)
            }

            if parts[0] == "max-counts" {
                guard let value = Int(parts[1]) else {
                    throw EPPTableError.malformedLine(line)
                }
                maxCounts = value
                continue
            }

            guard let index = Int(parts[0]), let value = Double(parts[1]) else {
                throw EPPTableError.malformedLine(line)
            }
            parsedValues[index] = value
        }

        guard let maxCounts else {
            throw EPPTableError.missingMaxCounts
        }

        var values: [Double] = []
        values.reserveCapacity(maxCounts + 1)
        for index in 0...maxCounts {
            guard let value = parsedValues[index] else {
                throw EPPTableError.missingValue(index)
            }
            values.append(value)
        }

        return try EPPTable(speed: speed, values: values)
    }
}
