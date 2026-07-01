import Foundation

public enum PointerEventClassification: String, Equatable, Sendable {
    case external
    case trackpad
    case unknown
}

public enum PointerControlRuleError: Error, CustomStringConvertible {
    case emptyFieldName
    case emptyExternalValue
    case emptyTrackpadValue
    case duplicateValues

    public var description: String {
        switch self {
        case .emptyFieldName:
            return "field name cannot be empty"
        case .emptyExternalValue:
            return "external value cannot be empty"
        case .emptyTrackpadValue:
            return "trackpad value cannot be empty"
        case .duplicateValues:
            return "external and trackpad values must differ"
        }
    }
}

public struct PointerControlRule: Equatable, Sendable {
    public let fieldName: String
    public let externalValue: String
    public let trackpadValue: String

    public init(fieldName: String, externalValue: String, trackpadValue: String) throws {
        guard !fieldName.isEmpty else {
            throw PointerControlRuleError.emptyFieldName
        }
        guard !externalValue.isEmpty else {
            throw PointerControlRuleError.emptyExternalValue
        }
        guard !trackpadValue.isEmpty else {
            throw PointerControlRuleError.emptyTrackpadValue
        }
        guard externalValue != trackpadValue else {
            throw PointerControlRuleError.duplicateValues
        }

        self.fieldName = fieldName
        self.externalValue = externalValue
        self.trackpadValue = trackpadValue
    }

    public func classify(fieldValue: String?) -> PointerEventClassification {
        if fieldValue == externalValue {
            return .external
        }
        if fieldValue == trackpadValue {
            return .trackpad
        }
        return .unknown
    }
}

public struct PointerControlDecision: Equatable, Sendable {
    public let classification: PointerEventClassification
    public let raw: RawDelta
    public let transformed: TransformedDelta?

    public var shouldTransform: Bool {
        transformed != nil
    }

    public var outputDelta: RawDelta {
        guard let transformed else {
            return raw
        }
        return RawDelta(dx: transformed.dx, dy: transformed.dy)
    }

    public var locationOffset: RawDelta {
        let output = outputDelta
        return RawDelta(dx: output.dx - raw.dx, dy: output.dy - raw.dy)
    }
}

public struct PointerControlStats: Equatable, Sendable {
    public private(set) var processedEvents: Int
    public private(set) var transformedEvents: Int
    public private(set) var passedThroughEvents: Int
    public private(set) var unknownEvents: Int

    public init(
        processedEvents: Int = 0,
        transformedEvents: Int = 0,
        passedThroughEvents: Int = 0,
        unknownEvents: Int = 0
    ) {
        self.processedEvents = processedEvents
        self.transformedEvents = transformedEvents
        self.passedThroughEvents = passedThroughEvents
        self.unknownEvents = unknownEvents
    }

    public mutating func record(_ decision: PointerControlDecision) {
        processedEvents += 1
        if decision.shouldTransform {
            transformedEvents += 1
        } else {
            passedThroughEvents += 1
            if decision.classification == .unknown {
                unknownEvents += 1
            }
        }
    }

    public func hasReachedSampleLimit(_ maxSamples: Int?) -> Bool {
        guard let maxSamples else {
            return false
        }
        return processedEvents >= maxSamples
    }
}

public final class PointerController {
    public let rule: PointerControlRule
    public let accelerator: PointerAccelerator

    public init(rule: PointerControlRule, accelerator: PointerAccelerator) {
        self.rule = rule
        self.accelerator = accelerator
    }

    public convenience init(rule: PointerControlRule, config: PointerAccelerationConfig) throws {
        try self.init(rule: rule, accelerator: PointerAccelerator(config: config))
    }

    public func process(fieldValue: String?, raw: RawDelta) -> PointerControlDecision {
        process(classification: rule.classify(fieldValue: fieldValue), raw: raw)
    }

    public func process(classification: PointerEventClassification, raw: RawDelta) -> PointerControlDecision {
        guard classification == .external, raw.dx != 0 || raw.dy != 0 else {
            return PointerControlDecision(classification: classification, raw: raw, transformed: nil)
        }

        return PointerControlDecision(
            classification: classification,
            raw: raw,
            transformed: accelerator.transform(raw)
        )
    }
}
