import Foundation
import WinPointerCore

enum SmokeTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SmokeTestError.failed(message)
    }
}

func checkNear(_ actual: Double, _ expected: Double, accuracy: Double = 0.0001, _ message: String) throws {
    if abs(actual - expected) >= accuracy {
        throw SmokeTestError.failed("\(message): expected \(expected), got \(actual)")
    }
}

func runSmokeTests() throws {
    let table = try EPPTableLoader.load(speed: 6)
    try check(table.speed == 6, "speed 6 table has wrong speed")
    try check(table.values.count == 128, "speed 6 table should contain 128 entries")
    try checkNear(table.values[1], 0.58, "table[1]")
    try checkNear(table.values[14], 16.9, "table[14]")
    try checkNear(table.values[127], 327.76, "table[127]")

    for speed in 1...11 {
        let speedTable = try EPPTableLoader.load(speed: speed)
        try check(speedTable.speed == speed, "table for speed \(speed) has wrong speed")
        try check(speedTable.values.count == 128, "table for speed \(speed) should contain 128 entries")
    }

    let slow = try PointerAccelerator(config: PointerAccelerationConfig(speed: 1, sensitivity: 1.0))
        .transform(RawDelta(dx: 10, dy: 0))
    let fast = try PointerAccelerator(config: PointerAccelerationConfig(speed: 11, sensitivity: 1.0))
        .transform(RawDelta(dx: 10, dy: 0))
    try check(slow.gain < fast.gain, "speed 1 should have lower gain than speed 11")

    do {
        _ = try PointerAccelerationConfig(speed: 0)
        throw SmokeTestError.failed("speed 0 should be rejected")
    } catch EPPTableError.invalidSpeed {
    }

    do {
        _ = try PointerAccelerationConfig(speed: 12)
        throw SmokeTestError.failed("speed 12 should be rejected")
    } catch EPPTableError.invalidSpeed {
    }

    do {
        _ = try PointerAccelerationConfig(inputScale: 0)
        throw SmokeTestError.failed("input scale 0 should be rejected")
    } catch PointerAccelerationError.invalidInputScale {
    }

    let config = try PointerAccelerationConfig(speed: 6, sensitivity: 1.0)
    let accelerator = try PointerAccelerator(config: config)

    let first = accelerator.transform(RawDelta(dx: 10, dy: 0))
    try check(first.magnitude == 10, "magnitude for 10,0 should be 10")
    try check(first.lookupMagnitude == 10, "default lookup magnitude should match magnitude")
    try checkNear(first.gain, 1.088, "gain for magnitude 10")
    try check(first.dx == 10, "first transform dx should be 10")
    try check(first.dy == 0, "first transform dy should be 0")
    try checkNear(first.remainderX, 0.88, "first remainder x")

    let second = accelerator.transform(RawDelta(dx: 1, dy: 0))
    try check(second.dx == 1, "second transform should carry remainder")
    try checkNear(second.remainderX, 0.46, "second remainder x")

    let signReset = try PointerAccelerator(config: config)
    _ = signReset.transform(RawDelta(dx: 10, dy: 0))
    let reversed = signReset.transform(RawDelta(dx: -1, dy: 0))
    try check(reversed.dx == 0, "reversed transform should truncate to zero")
    try checkNear(reversed.remainderX, -0.58, "reversed remainder x")

    let sensitiveConfig = try PointerAccelerationConfig(speed: 6, sensitivity: 2.0)
    let sensitive = try PointerAccelerator(config: sensitiveConfig)
    let scaled = sensitive.transform(RawDelta(dx: 10, dy: 0))
    try checkNear(scaled.gain, 2.176, "scaled gain")
    try check(scaled.dx == 21, "scaled dx should be 21")
    try checkNear(scaled.remainderX, 0.76, "scaled remainder x")

    let diagonal = try PointerAccelerator(config: config).transform(RawDelta(dx: 3, dy: 4))
    try check(diagonal.magnitude == 5, "diagonal magnitude should be 5")
    try checkNear(diagonal.gain, 0.844, "diagonal gain")
    try check(diagonal.dx == 2, "diagonal dx should be 2")
    try check(diagonal.dy == 3, "diagonal dy should be 3")

    let inputScaledConfig = try PointerAccelerationConfig(speed: 6, sensitivity: 1.0, inputScale: 0.25)
    let inputScaled = try PointerAccelerator(config: inputScaledConfig).transform(RawDelta(dx: 100, dy: 0))
    try check(inputScaled.magnitude == 100, "input-scaled magnitude should preserve raw magnitude")
    try check(inputScaled.lookupMagnitude == 25, "input scale should reduce lookup magnitude")
    try checkNear(inputScaled.gain, 1.8864, "input-scaled gain")
    try check(inputScaled.dx == 188, "input-scaled dx should use scaled lookup gain on raw delta")

    let rule = try PointerControlRule(fieldName: "sourceState", externalValue: "1", trackpadValue: "2")
    let controller = try PointerController(rule: rule, config: config)

    let externalDecision = controller.process(fieldValue: "1", raw: RawDelta(dx: 57, dy: 0))
    try check(externalDecision.classification == .external, "external value should classify as external")
    try check(externalDecision.shouldTransform, "external mouse movement should be transformed")
    try check(externalDecision.outputDelta.dx > 57, "external mouse output should be accelerated")
    try check(externalDecision.locationOffset.dx == externalDecision.outputDelta.dx - 57, "external location offset should match delta change")

    let directClassificationController = try PointerController(rule: rule, config: config)
    let directExternalDecision = directClassificationController.process(classification: .external, raw: RawDelta(dx: 57, dy: 0))
    try check(directExternalDecision.classification == .external, "direct external classification should be preserved")
    try check(directExternalDecision.shouldTransform, "direct external classification should transform")

    let directTrackpadDecision = directClassificationController.process(classification: .trackpad, raw: RawDelta(dx: 57, dy: 0))
    try check(directTrackpadDecision.classification == .trackpad, "direct trackpad classification should be preserved")
    try check(!directTrackpadDecision.shouldTransform, "direct trackpad classification should pass through")

    let directUnknownDecision = directClassificationController.process(classification: .unknown, raw: RawDelta(dx: 57, dy: 0))
    try check(directUnknownDecision.classification == .unknown, "direct unknown classification should be preserved")
    try check(!directUnknownDecision.shouldTransform, "direct unknown classification should pass through")

    let smallExternalController = try PointerController(rule: rule, config: config)
    let smallExternalDecision = smallExternalController.process(fieldValue: "1", raw: RawDelta(dx: 1, dy: 0))
    try check(smallExternalDecision.shouldTransform, "small external movement should still go through transform")
    try check(smallExternalDecision.outputDelta == RawDelta(dx: 0, dy: 0), "small external movement should preserve fractional remainder by outputting zero")
    try check(smallExternalDecision.locationOffset == RawDelta(dx: -1, dy: 0), "small external location offset should cancel the original event location delta")

    let secondSmallExternalDecision = smallExternalController.process(fieldValue: "1", raw: RawDelta(dx: 1, dy: 0))
    try check(secondSmallExternalDecision.outputDelta == RawDelta(dx: 1, dy: 0), "small external movement should release accumulated fractional remainder")
    try check(secondSmallExternalDecision.locationOffset == RawDelta(dx: 0, dy: 0), "small external location offset should be zero when output equals raw")

    let trackpadDecision = controller.process(fieldValue: "2", raw: RawDelta(dx: 57, dy: 0))
    try check(trackpadDecision.classification == .trackpad, "trackpad value should classify as trackpad")
    try check(!trackpadDecision.shouldTransform, "trackpad movement should not be transformed")
    try check(trackpadDecision.outputDelta == RawDelta(dx: 57, dy: 0), "trackpad output should pass through")
    try check(trackpadDecision.locationOffset == RawDelta(dx: 0, dy: 0), "trackpad location should not be offset")

    let smallTrackpadDecision = controller.process(fieldValue: "2", raw: RawDelta(dx: 1, dy: 0))
    try check(!smallTrackpadDecision.shouldTransform, "small trackpad movement should not be transformed")
    try check(smallTrackpadDecision.outputDelta == RawDelta(dx: 1, dy: 0), "small trackpad movement should pass through")
    try check(smallTrackpadDecision.locationOffset == RawDelta(dx: 0, dy: 0), "small trackpad location should not be offset")

    let unknownDecision = controller.process(fieldValue: nil, raw: RawDelta(dx: 57, dy: 0))
    try check(unknownDecision.classification == .unknown, "missing field should classify as unknown")
    try check(!unknownDecision.shouldTransform, "unknown movement should not be transformed")

    var stats = PointerControlStats()
    stats.record(externalDecision)
    stats.record(trackpadDecision)
    stats.record(unknownDecision)
    try check(stats.processedEvents == 3, "stats should count every processed movement event")
    try check(stats.transformedEvents == 1, "stats should count transformed external movement")
    try check(stats.passedThroughEvents == 2, "stats should count trackpad and unknown pass-through movement")
    try check(stats.unknownEvents == 1, "stats should count unknown pass-through movement")
    try check(!stats.hasReachedSampleLimit(nil), "nil sample limit should never stop")
    try check(!stats.hasReachedSampleLimit(4), "sample limit should not stop before processed count")
    try check(stats.hasReachedSampleLimit(3), "sample limit should stop at processed count")
    try check(stats.hasReachedSampleLimit(2), "sample limit should stop after processed count exceeds limit")

    let zeroExternalDecision = controller.process(fieldValue: "1", raw: RawDelta(dx: 0, dy: 0))
    try check(zeroExternalDecision.classification == .external, "zero external movement should still classify as external")
    try check(!zeroExternalDecision.shouldTransform, "zero movement should not be transformed")

    do {
        _ = try PointerControlRule(fieldName: "sourceState", externalValue: "1", trackpadValue: "1")
        throw SmokeTestError.failed("duplicate pointer control values should be rejected")
    } catch PointerControlRuleError.duplicateValues {
    }
}

do {
    try runSmokeTests()
    print("All WinPointerCore smoke tests passed.")
} catch {
    FileHandle.standardError.write(Data(("Smoke tests failed: \(error)\n").utf8))
    exit(1)
}
