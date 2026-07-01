import ApplicationServices
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import IOKit.hid
import WinPointerCore

@main
struct WinPointerCLI {
    static func main() {
        do {
            try CommandRunner(arguments: Array(CommandLine.arguments.dropFirst())).run()
        } catch let error as CLIError {
            FileHandle.standardError.write(Data((error.description + "\n").utf8))
            exit(Int32(error.exitCode))
        } catch {
            FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
            exit(1)
        }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case runtime(String)

    var description: String {
        switch self {
        case .usage(let message):
            return "usage error: \(message)\n\n\(CommandRunner.usage)"
        case .runtime(let message):
            return "error: \(message)"
        }
    }

    var exitCode: Int {
        switch self {
        case .usage:
            return 64
        case .runtime:
            return 1
        }
    }
}

struct CommandRunner {
    let arguments: [String]
    private static let defaultSpeed = 4

    static let usage = """
    winpointer devices
    winpointer doctor [--json]
    winpointer hid-services
    winpointer hid-accel-snapshot
    winpointer hid-write-restore-test --registry ID --key KEY --value NUMBER [--execute --confirm WRITE_RESTORE_TEST]
    winpointer run [--speed 1..11] [--samples N] [--timeout-ms N] [--verbose]
    winpointer run --dry-run [--speed 1..11] [--sensitivity FLOAT] [--input-scale FLOAT]
    winpointer run --shadow [--speed 1..11] [--sensitivity FLOAT] [--input-scale FLOAT] [--quiet] [--samples N]
    winpointer hid-probe [--samples N] [--speed 1..11] [--sensitivity FLOAT] [--input-scale FLOAT] [--quiet]
    winpointer probe [--speed 1..11] [--sensitivity FLOAT] [--input-scale FLOAT] [--samples N] [--tap session|hid] [--debug-fields] [--summary] [--quiet] [--json]
    winpointer compare-summaries --external FILE --trackpad FILE [--min-samples N] [--min-abs-delta N] [--json]
    winpointer compare-summary-set --external FILE [--external FILE ...] --trackpad FILE [--trackpad FILE ...] [--min-samples N] [--min-abs-delta N] [--json]
    winpointer attribution-probe --field FIELD --external-value VALUE --trackpad-value VALUE [--tap session|hid] [--samples N] [--quiet] [--json]
    winpointer pass-through-probe --confirm PASS_THROUGH_TAP [--tap session|hid] [--samples N] [--timeout-ms N] [--quiet] [--json]
    winpointer stage2-gate --summary-set FILE --attribution FILE --pass-through FILE [--json]
    winpointer bench-transform [--iterations N] [--speed 1..11] [--sensitivity FLOAT] [--input-scale FLOAT]
    winpointer transform --dx INT --dy INT [--speed 1..11] [--sensitivity FLOAT] [--input-scale FLOAT]
    winpointer status
    winpointer stop
    winpointer kill-switch
    """

    func run() throws {
        guard let command = arguments.first else {
            throw CLIError.usage("missing command")
        }

        let options = Array(arguments.dropFirst())
        switch command {
        case "devices":
            try ensureNoExtraOptions(options)
            printDevices(DeviceEnumerator.listDevices())
        case "doctor":
            try validateKnownOptions(options, valueOptions: [], flagOptions: ["--json"])
            try printDoctorReport(outputJSON: try parseFlag("--json", in: options))
        case "hid-services":
            try ensureNoExtraOptions(options)
            printHIDServices(HIDServiceDiagnostics.listServices())
        case "hid-accel-snapshot":
            try ensureNoExtraOptions(options)
            try printHIDAccelerationSnapshot(HIDServiceDiagnostics.listServices())
        case "hid-write-restore-test":
            try validateKnownOptions(
                options,
                valueOptions: ["--registry", "--key", "--value", "--confirm"],
                flagOptions: ["--execute"]
            )
            try runHIDWriteRestoreTest(options: options)
        case "run":
            let config = try parseAccelerationConfig(
                options,
                allowedExtraOptions: ["--samples", "--stage2-gate", "--confirm", "--timeout-ms"],
                allowedFlags: ["--dry-run", "--shadow", "--quiet", "--real", "--hid-overlay", "--verbose"]
            )
            let dryRun = try parseFlag("--dry-run", in: options)
            let shadow = try parseFlag("--shadow", in: options)
            let quiet = try parseFlag("--quiet", in: options)
            let verbose = try parseFlag("--verbose", in: options)
            let real = try parseFlag("--real", in: options)
            let hidOverlay = try parseFlag("--hid-overlay", in: options)
            if [dryRun, shadow, real].filter({ $0 }).count > 1 {
                throw CLIError.usage("--dry-run, --shadow, and --real cannot be used together")
            }
            if verbose && (dryRun || shadow) {
                throw CLIError.usage("--verbose is only valid with pointer control run")
            }
            if !real {
                if try parseStringOption("--stage2-gate", in: options) != nil {
                    throw CLIError.usage("--stage2-gate is only valid with --real")
                }
                if dryRun || shadow, try parseStringOption("--confirm", in: options) != nil {
                    throw CLIError.usage("--confirm is only valid with --real")
                }
            }
            if dryRun {
                printRunDryRun(config: config)
                return
            }
            if shadow {
                let samples = try parseIntOption("--samples", in: options)
                if let samples, samples <= 0 {
                    throw CLIError.usage("--samples must be greater than 0")
                }
                let runner = try HIDRawProbeRunner(
                    config: config,
                    maxSamples: samples,
                    mode: .shadowRun,
                    quiet: quiet
                )
                try runner.start()
                return
            }
            let samples = try parseIntOption("--samples", in: options)
            if let samples, samples <= 0 {
                throw CLIError.usage("--samples must be greater than 0")
            }
            let timeoutMilliseconds = try parseIntOption("--timeout-ms", in: options)
            if let timeoutMilliseconds, timeoutMilliseconds <= 0 {
                throw CLIError.usage("--timeout-ms must be greater than 0")
            }
            if real {
                if hidOverlay {
                    if try parseStringOption("--stage2-gate", in: options) != nil {
                        throw CLIError.usage("--stage2-gate cannot be used with --hid-overlay")
                    }
                    let runner = try HIDOverlayRealRunRunner(
                        config: config,
                        maxSamples: samples,
                        timeoutMilliseconds: timeoutMilliseconds,
                        quiet: !verbose
                    )
                    try runner.start()
                    return
                }
                guard try parseStringOption("--confirm", in: options) == "EXPERIMENTAL_REAL_RUN" else {
                    throw CLIError.usage("legacy run --real --stage2-gate requires --confirm EXPERIMENTAL_REAL_RUN")
                }
                guard let gatePath = try parseStringOption("--stage2-gate", in: options) else {
                    throw CLIError.usage("run --real requires --stage2-gate FILE")
                }
                let gate = try loadRealRunGate(path: gatePath)
                let runner = try RealRunRunner(
                    config: config,
                    gate: gate,
                    maxSamples: samples,
                    timeoutMilliseconds: timeoutMilliseconds,
                    quiet: quiet
                )
                try runner.start()
                return
            }
            if let confirm = try parseStringOption("--confirm", in: options),
               confirm != "EXPERIMENTAL_REAL_RUN" {
                throw CLIError.usage("--confirm expects EXPERIMENTAL_REAL_RUN")
            }
            let runner = try HIDOverlayRealRunRunner(
                config: config,
                maxSamples: samples,
                timeoutMilliseconds: timeoutMilliseconds,
                quiet: !verbose
            )
            try runner.start()
        case "hid-probe":
            let config = try parseAccelerationConfig(
                options,
                allowedExtraOptions: ["--samples"],
                allowedFlags: ["--quiet"]
            )
            let samples = try parseIntOption("--samples", in: options) ?? 20
            guard samples > 0 else {
                throw CLIError.usage("--samples must be greater than 0")
            }
            let quiet = try parseFlag("--quiet", in: options)
            let runner = try HIDRawProbeRunner(config: config, maxSamples: samples, mode: .probe, quiet: quiet)
            try runner.start()
        case "probe":
            let config = try parseAccelerationConfig(
                options,
                allowedExtraOptions: ["--samples", "--tap"],
                allowedFlags: ["--debug-fields", "--summary", "--quiet", "--json"]
            )
            let samples = try parseIntOption("--samples", in: options) ?? 20
            guard samples > 0 else {
                throw CLIError.usage("--samples must be greater than 0")
            }
            let tapPlacement = try EventTapPlacement.parse(try parseStringOption("--tap", in: options) ?? "session")
            let debugFields = try parseFlag("--debug-fields", in: options)
            let summary = try parseFlag("--summary", in: options)
            let quiet = try parseFlag("--quiet", in: options)
            let json = try parseFlag("--json", in: options)
            if quiet && !summary {
                throw CLIError.usage("--quiet is only valid with --summary")
            }
            if json && !summary {
                throw CLIError.usage("--json is only valid with --summary")
            }
            let runner = try ProbeRunner(
                config: config,
                maxSamples: samples,
                tapPlacement: tapPlacement,
                debugFields: debugFields,
                summary: summary,
                quiet: quiet || json,
                outputFormat: json ? .json : .text
            )
            try runner.start()
        case "compare-summaries":
            try validateKnownOptions(
                options,
                valueOptions: ["--external", "--trackpad", "--min-samples", "--min-abs-delta"],
                flagOptions: ["--json"]
            )
            guard let externalPath = try parseStringOption("--external", in: options),
                  let trackpadPath = try parseStringOption("--trackpad", in: options) else {
                throw CLIError.usage("compare-summaries requires --external and --trackpad")
            }
            let minimumSamples = try parseIntOption("--min-samples", in: options) ?? 10
            let minimumAbsDelta = try parseIntOption("--min-abs-delta", in: options) ?? 10
            guard minimumSamples > 0 else {
                throw CLIError.usage("--min-samples must be greater than 0")
            }
            guard minimumAbsDelta >= 0 else {
                throw CLIError.usage("--min-abs-delta must be greater than or equal to 0")
            }
            let outputJSON = try parseFlag("--json", in: options)
            try compareEventSummaries(
                externalPath: externalPath,
                trackpadPath: trackpadPath,
                minimumSamples: minimumSamples,
                minimumAbsDelta: minimumAbsDelta,
                outputJSON: outputJSON
            )
        case "compare-summary-set":
            try validateKnownOptions(
                options,
                valueOptions: ["--external", "--trackpad", "--min-samples", "--min-abs-delta"],
                flagOptions: ["--json"]
            )
            let externalPaths = try parseStringOptions("--external", in: options)
            let trackpadPaths = try parseStringOptions("--trackpad", in: options)
            guard externalPaths.count >= 2 else {
                throw CLIError.usage("compare-summary-set requires at least two --external files")
            }
            guard trackpadPaths.count >= 2 else {
                throw CLIError.usage("compare-summary-set requires at least two --trackpad files")
            }
            let minimumSamples = try parseIntOption("--min-samples", in: options) ?? 10
            let minimumAbsDelta = try parseIntOption("--min-abs-delta", in: options) ?? 10
            guard minimumSamples > 0 else {
                throw CLIError.usage("--min-samples must be greater than 0")
            }
            guard minimumAbsDelta >= 0 else {
                throw CLIError.usage("--min-abs-delta must be greater than or equal to 0")
            }
            let outputJSON = try parseFlag("--json", in: options)
            try compareEventSummarySet(
                externalPaths: externalPaths,
                trackpadPaths: trackpadPaths,
                minimumSamples: minimumSamples,
                minimumAbsDelta: minimumAbsDelta,
                outputJSON: outputJSON
            )
        case "attribution-probe":
            try validateKnownOptions(
                options,
                valueOptions: ["--field", "--external-value", "--trackpad-value", "--tap", "--samples"],
                flagOptions: ["--quiet", "--json"]
            )
            guard let fieldName = try parseStringOption("--field", in: options),
                  let externalValue = try parseStringOption("--external-value", in: options),
                  let trackpadValue = try parseStringOption("--trackpad-value", in: options) else {
                throw CLIError.usage("attribution-probe requires --field, --external-value, and --trackpad-value")
            }
            guard attributionCandidateFields.contains(fieldName) else {
                throw CLIError.usage("--field must be one of \(attributionCandidateFieldOrder.joined(separator: ","))")
            }
            guard externalValue != trackpadValue else {
                throw CLIError.usage("--external-value and --trackpad-value must differ")
            }
            let samples = try parseIntOption("--samples", in: options) ?? 30
            guard samples > 0 else {
                throw CLIError.usage("--samples must be greater than 0")
            }
            let tapPlacement = try EventTapPlacement.parse(try parseStringOption("--tap", in: options) ?? "hid")
            let quiet = try parseFlag("--quiet", in: options)
            let json = try parseFlag("--json", in: options)
            let runner = AttributionProbeRunner(
                tapPlacement: tapPlacement,
                maxSamples: samples,
                fieldName: fieldName,
                externalValue: externalValue,
                trackpadValue: trackpadValue,
                quiet: quiet || json,
                outputJSON: json
            )
            try runner.start()
        case "pass-through-probe":
            try validateKnownOptions(
                options,
                valueOptions: ["--confirm", "--tap", "--samples", "--timeout-ms"],
                flagOptions: ["--quiet", "--json"]
            )
            guard try parseStringOption("--confirm", in: options) == "PASS_THROUGH_TAP" else {
                throw CLIError.usage("pass-through-probe requires --confirm PASS_THROUGH_TAP")
            }
            let samples = try parseIntOption("--samples", in: options) ?? 30
            guard samples > 0 else {
                throw CLIError.usage("--samples must be greater than 0")
            }
            let timeoutMilliseconds = try parseIntOption("--timeout-ms", in: options) ?? 10_000
            guard timeoutMilliseconds > 0 else {
                throw CLIError.usage("--timeout-ms must be greater than 0")
            }
            let tapPlacement = try EventTapPlacement.parse(try parseStringOption("--tap", in: options) ?? "hid")
            let quiet = try parseFlag("--quiet", in: options)
            let json = try parseFlag("--json", in: options)
            let runner = PassThroughProbeRunner(
                tapPlacement: tapPlacement,
                maxSamples: samples,
                timeoutMilliseconds: timeoutMilliseconds,
                quiet: quiet || json,
                outputJSON: json
            )
            try runner.start()
        case "stage2-gate":
            try validateKnownOptions(
                options,
                valueOptions: ["--summary-set", "--attribution", "--pass-through"],
                flagOptions: ["--json"]
            )
            guard let summarySetPath = try parseStringOption("--summary-set", in: options),
                  let attributionPath = try parseStringOption("--attribution", in: options),
                  let passThroughPath = try parseStringOption("--pass-through", in: options) else {
                throw CLIError.usage("stage2-gate requires --summary-set, --attribution, and --pass-through")
            }
            let outputJSON = try parseFlag("--json", in: options)
            try runStage2Gate(
                summarySetPath: summarySetPath,
                attributionPath: attributionPath,
                passThroughPath: passThroughPath,
                outputJSON: outputJSON
            )
        case "bench-transform":
            let config = try parseAccelerationConfig(options, allowedExtraOptions: ["--iterations"])
            let iterations = try parseIntOption("--iterations", in: options) ?? 1_000_000
            guard iterations > 0 else {
                throw CLIError.usage("--iterations must be greater than 0")
            }
            try runTransformBenchmark(config: config, iterations: iterations)
        case "transform":
            let config = try parseAccelerationConfig(options, allowedExtraOptions: ["--dx", "--dy"])
            guard let dx = try parseIntOption("--dx", in: options),
                  let dy = try parseIntOption("--dy", in: options) else {
                throw CLIError.usage("transform requires --dx and --dy")
            }
            let accelerator = try PointerAccelerator(config: config)
            let transformed = accelerator.transform(RawDelta(dx: dx, dy: dy))
            printTransform(raw: RawDelta(dx: dx, dy: dy), transformed: transformed, config: config)
        case "status":
            try ensureNoExtraOptions(options)
            print("No background daemon is implemented in this prototype.")
        case "stop", "kill-switch":
            try ensureNoExtraOptions(options)
            print("No background daemon or persistent hook is implemented in this prototype.")
        default:
            throw CLIError.usage("unknown command \(command)")
        }
    }

    private func parseAccelerationConfig(
        _ options: [String],
        allowedExtraOptions: Set<String> = [],
        allowedFlags: Set<String> = []
    ) throws -> PointerAccelerationConfig {
        try validateKnownOptions(
            options,
            valueOptions: Set(["--speed", "--sensitivity", "--input-scale"]).union(allowedExtraOptions),
            flagOptions: allowedFlags
        )
        let speed = try parseIntOption("--speed", in: options) ?? Self.defaultSpeed
        let sensitivity = try parseDoubleOption("--sensitivity", in: options) ?? Self.automaticSensitivity()
        let inputScale = try parseDoubleOption("--input-scale", in: options) ?? Self.automaticInputScale()
        do {
            return try PointerAccelerationConfig(
                speed: speed,
                sensitivity: sensitivity,
                inputScale: inputScale
            )
        } catch {
            throw CLIError.usage(String(describing: error))
        }
    }

    private static func automaticSensitivity() -> Double {
        1.0
    }

    private static func automaticInputScale() -> Double {
        0.08
    }

    private func parseIntOption(_ name: String, in options: [String]) throws -> Int? {
        guard let raw = try parseStringOption(name, in: options) else {
            return nil
        }
        guard let value = Int(raw) else {
            throw CLIError.usage("\(name) expects an integer")
        }
        return value
    }

    private func parseDoubleOption(_ name: String, in options: [String]) throws -> Double? {
        guard let raw = try parseStringOption(name, in: options) else {
            return nil
        }
        guard let value = Double(raw) else {
            throw CLIError.usage("\(name) expects a number")
        }
        return value
    }

    private func parseStringOption(_ name: String, in options: [String]) throws -> String? {
        var value: String?
        var index = 0
        while index < options.count {
            let option = options[index]
            if option == name {
                guard index + 1 < options.count else {
                    throw CLIError.usage("\(name) requires a value")
                }
                if value != nil {
                    throw CLIError.usage("\(name) was provided more than once")
                }
                value = options[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return value
    }

    private func parseStringOptions(_ name: String, in options: [String]) throws -> [String] {
        var values: [String] = []
        var index = 0
        while index < options.count {
            let option = options[index]
            if option == name {
                guard index + 1 < options.count else {
                    throw CLIError.usage("\(name) requires a value")
                }
                values.append(options[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        return values
    }

    private func parseFlag(_ name: String, in options: [String]) throws -> Bool {
        var found = false
        for option in options where option == name {
            if found {
                throw CLIError.usage("\(name) was provided more than once")
            }
            found = true
        }
        return found
    }

    private func validateKnownOptions(
        _ options: [String],
        valueOptions: Set<String>,
        flagOptions: Set<String> = []
    ) throws {
        var index = 0
        while index < options.count {
            let option = options[index]
            guard option.hasPrefix("--") else {
                throw CLIError.usage("unexpected argument \(option)")
            }
            if flagOptions.contains(option) {
                index += 1
                continue
            }
            guard valueOptions.contains(option) else {
                throw CLIError.usage("unknown option \(option)")
            }
            guard index + 1 < options.count else {
                throw CLIError.usage("\(option) requires a value")
            }
            index += 2
        }
    }

    private func ensureNoExtraOptions(_ options: [String]) throws {
        guard options.isEmpty else {
            throw CLIError.usage("unexpected options: \(options.joined(separator: " "))")
        }
    }

    private func runHIDWriteRestoreTest(options: [String]) throws {
        guard let registryID = try parseStringOption("--registry", in: options),
              let key = try parseStringOption("--key", in: options),
              let value = try parseDoubleOption("--value", in: options) else {
            throw CLIError.usage("hid-write-restore-test requires --registry, --key, and --value")
        }

        let execute = try parseFlag("--execute", in: options)
        let confirm = try parseStringOption("--confirm", in: options)
        if execute && confirm != "WRITE_RESTORE_TEST" {
            throw CLIError.usage("--execute requires --confirm WRITE_RESTORE_TEST")
        }

        let services = HIDServiceDiagnostics.listServices()
        guard let target = services.first(where: { $0.registryID == registryID }) else {
            throw CLIError.runtime("registry \(registryID) was not found")
        }
        guard target.isCandidate else {
            throw CLIError.runtime("registry \(registryID) is not an external mouse candidate; refusing write test")
        }
        guard target.accelerationProperties.contains(where: { $0.key == key }) else {
            throw CLIError.runtime("property \(key) is not visible on candidate registry \(registryID); refusing write test")
        }

        print("hid-write-restore-test")
        print("target=\(target.productName) registry=\(target.registryID)")
        print("key=\(key) temporary-value=\(value)")
        print("current-properties:")
        for property in target.accelerationProperties {
            print("  \(property.key)=\(property.valueDescription)")
        }

        guard execute else {
            print("dry-run: no HID property was written")
            print("to execute: add --execute --confirm WRITE_RESTORE_TEST")
            return
        }

        let result = try HIDServiceDiagnostics.writeNumberThenRestore(
            registryID: registryID,
            key: key,
            temporaryValue: value
        )
        print("executed: temporary write and restore completed")
        print("original=\(result.originalValue)")
        print("after-write=\(result.valueAfterWrite)")
        print("after-restore=\(result.valueAfterRestore)")
    }

    private func runTransformBenchmark(config: PointerAccelerationConfig, iterations: Int) throws {
        let accelerator = try PointerAccelerator(config: config)
        let pattern = [
            RawDelta(dx: 1, dy: 0),
            RawDelta(dx: -1, dy: 2),
            RawDelta(dx: 7, dy: -4),
            RawDelta(dx: -14, dy: 2),
            RawDelta(dx: 23, dy: 1),
            RawDelta(dx: 57, dy: -25),
            RawDelta(dx: 118, dy: -32),
            RawDelta(dx: -315, dy: 17),
            RawDelta(dx: 0, dy: 1),
            RawDelta(dx: -6, dy: 0),
        ]

        var checksum: Int64 = 0
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            let transformed = accelerator.transform(pattern[index % pattern.count])
            checksum &+= Int64(transformed.dx)
            checksum &+= Int64(transformed.dy) &* 31
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        print("bench-transform")
        print("speed=\(config.speed) sensitivity=\(config.sensitivity) input-scale=\(config.inputScale) iterations=\(iterations)")
        print("elapsed=\(formatSeconds(elapsed))")
        print("avg-transform-ns=\(formatDouble(Double(elapsed) / Double(iterations), fractionDigits: 1))")
        print("transforms-per-second=\(formatDouble(Double(iterations) / seconds(elapsed), fractionDigits: 0))")
        print("checksum=\(checksum)")
        print("mode=CPU-only; no HID access, no event tap, no system setting writes")
    }
}

private func printDevices(_ devices: [DeviceInfo]) {
    if devices.isEmpty {
        print("No pointing HID devices found.")
        return
    }

    print("STATUS      USAGE      VENDOR PRODUCT LOCATION TRANSPORT PRODUCT")
    for device in devices {
        let status: String
        if device.isCandidate {
            status = "candidate"
        } else if device.isProtected {
            status = "protected"
        } else {
            status = "ignored"
        }

        let vendor = device.vendorID.map(String.init) ?? "-"
        let product = device.productID.map(String.init) ?? "-"
        let location = device.locationID.map(String.init) ?? "-"
        let line = [
            status.padding(toLength: 11, withPad: " ", startingAt: 0),
            device.usageDescription.padding(toLength: 10, withPad: " ", startingAt: 0),
            vendor.padding(toLength: 6, withPad: " ", startingAt: 0),
            product.padding(toLength: 7, withPad: " ", startingAt: 0),
            location.padding(toLength: 8, withPad: " ", startingAt: 0),
            device.transport.padding(toLength: 9, withPad: " ", startingAt: 0),
            "\(device.productName) (\(device.reason))",
        ].joined(separator: " ")
        print(line)
    }
}

private func printHIDServices(_ services: [HIDServiceInfo]) {
    if services.isEmpty {
        print("No pointing HID services found.")
        return
    }

    print("STATUS      USAGE      MOUSE POINTER VENDOR PRODUCT LOCATION TRANSPORT PRODUCT")
    for service in services {
        let status: String
        if service.isCandidate {
            status = "candidate"
        } else if service.isProtected {
            status = "protected"
        } else {
            status = "ignored"
        }

        let vendor = service.vendorID.map(String.init) ?? "-"
        let product = service.productID.map(String.init) ?? "-"
        let location = service.locationID.map(String.init) ?? "-"
        let line = [
            status.padding(toLength: 11, withPad: " ", startingAt: 0),
            service.usageDescription.padding(toLength: 10, withPad: " ", startingAt: 0),
            (service.conformsToMouse ? "yes" : "no ").padding(toLength: 5, withPad: " ", startingAt: 0),
            (service.conformsToPointer ? "yes" : "no ").padding(toLength: 7, withPad: " ", startingAt: 0),
            vendor.padding(toLength: 6, withPad: " ", startingAt: 0),
            product.padding(toLength: 7, withPad: " ", startingAt: 0),
            location.padding(toLength: 8, withPad: " ", startingAt: 0),
            service.transport.padding(toLength: 9, withPad: " ", startingAt: 0),
            "\(service.productName) (\(service.reason)) registry=\(service.registryID)",
        ].joined(separator: " ")
        print(line)

        if service.accelerationProperties.isEmpty {
            print("  acceleration: none visible")
        } else {
            for property in service.accelerationProperties {
                print("  \(property.key)=\(property.valueDescription)")
            }
        }
    }
}

private func printHIDAccelerationSnapshot(_ services: [HIDServiceInfo]) throws {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let serviceObjects: [[String: Any]] = services.map { service in
        [
            "registryID": service.registryID,
            "productName": service.productName,
            "manufacturer": service.manufacturer,
            "transport": service.transport,
            "vendorID": jsonValue(service.vendorID),
            "productID": jsonValue(service.productID),
            "locationID": jsonValue(service.locationID),
            "primaryUsagePage": jsonValue(service.primaryUsagePage),
            "primaryUsage": jsonValue(service.primaryUsage),
            "conformsToMouse": service.conformsToMouse,
            "conformsToPointer": service.conformsToPointer,
            "isCandidate": service.isCandidate,
            "isProtected": service.isProtected,
            "reason": service.reason,
            "accelerationProperties": service.accelerationProperties.map { property in
                [
                    "key": property.key,
                    "value": property.valueDescription,
                ]
            },
        ]
    }

    let snapshot: [String: Any] = [
        "schemaVersion": 1,
        "createdAt": timestamp,
        "tool": "winpointer-mac",
        "mode": "read-only",
        "services": serviceObjects,
    ]

    let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
        throw CLIError.runtime("could not encode snapshot as UTF-8")
    }
    print(text)
}

private func jsonValue<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

private func encodeJSONString(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
        throw CLIError.runtime("could not encode JSON as UTF-8")
    }
    return text
}

private func loadJSONObject(path: String, expectedKind: String) throws -> [String: Any] {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw CLIError.runtime("could not read JSON file \(path): \(error.localizedDescription)")
    }

    let root: Any
    do {
        root = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw CLIError.runtime("could not parse JSON file \(path): \(error.localizedDescription)")
    }

    guard let object = root as? [String: Any] else {
        throw CLIError.runtime("JSON file \(path) does not contain an object")
    }
    guard object["kind"] as? String == expectedKind else {
        throw CLIError.runtime("JSON file \(path) is not a \(expectedKind) object")
    }
    return object
}

private func jsonIntValue(_ value: Any?) -> Int? {
    if let int = value as? Int {
        return int
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    return nil
}

private func jsonStringValue(_ value: Any?) -> String? {
    if let string = value as? String {
        return string
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    return nil
}

private struct DoctorCheck {
    let status: String
    let name: String
    let detail: String
}

private struct DoctorReport {
    let devices: [DeviceInfo]
    let services: [HIDServiceInfo]
    let deviceCandidates: [DeviceInfo]
    let protectedDevices: [DeviceInfo]
    let serviceCandidates: [HIDServiceInfo]
    let protectedServices: [HIDServiceInfo]
    let checks: [DoctorCheck]
    let nextSteps: [String]
}

private func makeDoctorReport() -> DoctorReport {
    let devices = DeviceEnumerator.listDevices()
    let services = HIDServiceDiagnostics.listServices()
    let deviceCandidates = devices.filter(\.isCandidate)
    let protectedDevices = devices.filter(\.isProtected)
    let serviceCandidates = services.filter(\.isCandidate)
    let protectedServices = services.filter(\.isProtected)
    let candidatePointerCurveServices = serviceCandidates.filter { service in
        service.accelerationProperties.contains { property in
            property.key == "HIDAccelCurves" || property.key == "IOHIDSetAcceleration"
        }
    }

    let checks: [DoctorCheck] = [
        DoctorCheck(
            status: deviceCandidates.isEmpty ? "blocker" : "ok",
            name: "external-device-candidates",
            detail: "\(deviceCandidates.count) candidate(s), \(protectedDevices.count) protected device(s)"
        ),
        DoctorCheck(
            status: serviceCandidates.isEmpty ? "blocker" : "ok",
            name: "hid-service-candidates",
            detail: "\(serviceCandidates.count) candidate service(s), \(protectedServices.count) protected service(s)"
        ),
        DoctorCheck(
            status: candidatePointerCurveServices.isEmpty ? "info" : "ok",
            name: "per-device-pointer-curve",
            detail: candidatePointerCurveServices.isEmpty
                ? "candidate services do not expose HIDAccelCurves or IOHIDSetAcceleration; active-tap control does not require HID curve writes"
                : "\(candidatePointerCurveServices.count) candidate service(s) expose pointer curve controls"
        ),
        checkHIDRawOpen(),
        checkAccessibilityTrust(),
        checkEventTapCreation(.session),
        checkEventTapCreation(.hid),
        checkActiveEventTapCreation(.session),
        checkActiveEventTapCreation(.hid),
        DoctorCheck(
            status: "blocker",
            name: "device-attribution",
            detail: "not verified here; collect repeated probe --summary --json captures and run compare-summary-set"
        ),
        DoctorCheck(
            status: "blocker",
            name: "real-run",
            detail: "default run remains disabled; experimental --real requires a ready stage2 gate and explicit confirmation"
        ),
        DoctorCheck(
            status: "ok",
            name: "persistence",
            detail: "no daemon, launch agent, login item, driver, or persistent hook is implemented"
        ),
    ]

    let nextSteps = [
        "If IOHID raw input is blocked, grant Input Monitoring to the terminal app and retry run --shadow.",
        "If active event taps are blocked, grant Accessibility to the terminal app that launches winpointer.",
        "Collect repeated external mouse and trackpad JSON summaries, then run compare-summary-set.",
        "If repeatable candidate fields are found, run attribution-probe with those values for live listen-only verification.",
        "Run pass-through-probe only after granting active event-tap permission.",
        "Run stage2-gate with the summary-set, attribution, and pass-through JSON outputs.",
        "Use run --real only with a ready stage2 gate, explicit confirmation, and a short --samples limit first.",
    ]

    return DoctorReport(
        devices: devices,
        services: services,
        deviceCandidates: deviceCandidates,
        protectedDevices: protectedDevices,
        serviceCandidates: serviceCandidates,
        protectedServices: protectedServices,
        checks: checks,
        nextSteps: nextSteps
    )
}

private func printDoctorReport(outputJSON: Bool) throws {
    let report = makeDoctorReport()

    if outputJSON {
        printFlush(try encodeJSONString(doctorReportObject(report)))
        return
    }

    print("winpointer doctor")
    print("mode=read-only; no pointer movement, no HID writes, no persistent changes")
    for check in report.checks {
        printDoctorCheck(check)
    }

    if !report.deviceCandidates.isEmpty {
        print("candidate-devices:")
        for device in report.deviceCandidates {
            print("  \(device.id) \(device.productName) transport=\(device.transport)")
        }
    }

    if !report.serviceCandidates.isEmpty {
        print("candidate-services:")
        for service in report.serviceCandidates {
            let properties = service.accelerationProperties.map(\.key).joined(separator: ",")
            print("  registry=\(service.registryID) \(service.productName) transport=\(service.transport) acceleration=\(properties.isEmpty ? "none" : properties)")
        }
    }

    print("next:")
    for (index, step) in report.nextSteps.enumerated() {
        print("  \(index + 1). \(step)")
    }
}

private func doctorReportObject(_ report: DoctorReport) -> [String: Any] {
    let blockers = report.checks.filter { $0.status == "blocker" }
    return [
        "schemaVersion": 1,
        "kind": "doctor-report",
        "mode": "read-only",
        "summary": [
            "result": blockers.isEmpty ? "ok" : "blocker",
            "blockerCount": blockers.count,
            "deviceCandidateCount": report.deviceCandidates.count,
            "protectedDeviceCount": report.protectedDevices.count,
            "serviceCandidateCount": report.serviceCandidates.count,
            "protectedServiceCount": report.protectedServices.count,
        ],
        "checks": report.checks.map { check in
            [
                "status": check.status,
                "name": check.name,
                "detail": check.detail,
            ]
        },
        "candidateDevices": report.deviceCandidates.map(deviceObject),
        "candidateServices": report.serviceCandidates.map(hidServiceObject),
        "protectedDevices": report.protectedDevices.map(deviceObject),
        "protectedServices": report.protectedServices.map(hidServiceObject),
        "next": report.nextSteps,
    ]
}

private func deviceObject(_ device: DeviceInfo) -> [String: Any] {
    [
        "id": device.id,
        "productName": device.productName,
        "manufacturer": device.manufacturer,
        "transport": device.transport,
        "vendorID": jsonValue(device.vendorID),
        "productID": jsonValue(device.productID),
        "locationID": jsonValue(device.locationID),
        "primaryUsagePage": jsonValue(device.primaryUsagePage),
        "primaryUsage": jsonValue(device.primaryUsage),
        "usage": device.usageDescription,
        "isCandidate": device.isCandidate,
        "isProtected": device.isProtected,
        "reason": device.reason,
    ]
}

private func hidServiceObject(_ service: HIDServiceInfo) -> [String: Any] {
    [
        "registryID": service.registryID,
        "productName": service.productName,
        "manufacturer": service.manufacturer,
        "transport": service.transport,
        "vendorID": jsonValue(service.vendorID),
        "productID": jsonValue(service.productID),
        "locationID": jsonValue(service.locationID),
        "primaryUsagePage": jsonValue(service.primaryUsagePage),
        "primaryUsage": jsonValue(service.primaryUsage),
        "usage": service.usageDescription,
        "conformsToMouse": service.conformsToMouse,
        "conformsToPointer": service.conformsToPointer,
        "isCandidate": service.isCandidate,
        "isProtected": service.isProtected,
        "reason": service.reason,
        "accelerationProperties": service.accelerationProperties.map { property in
            [
                "key": property.key,
                "value": property.valueDescription,
            ]
        },
    ]
}

private func printDoctorCheck(_ check: DoctorCheck) {
    let status = check.status.padding(toLength: 7, withPad: " ", startingAt: 0)
    print("\(status) \(check.name) - \(check.detail)")
}

private func checkHIDRawOpen() -> DoctorCheck {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: NSDictionary = [
        kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
        kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching)

    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    defer {
        if result == kIOReturnSuccess {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    if result == kIOReturnSuccess {
        return DoctorCheck(status: "ok", name: "iohid-raw-input", detail: "IOHIDManager opened for mouse devices")
    }

    if result == kIOReturnNotPermitted {
        return DoctorCheck(status: "blocker", name: "iohid-raw-input", detail: "\(formatIOReturn(result)) not permitted; grant Input Monitoring to the terminal app")
    }

    return DoctorCheck(status: "blocker", name: "iohid-raw-input", detail: "IOHIDManager open failed with \(formatIOReturn(result))")
}

private func checkAccessibilityTrust() -> DoctorCheck {
    if AXIsProcessTrusted() {
        return DoctorCheck(status: "ok", name: "accessibility-trust", detail: "current process is trusted for Accessibility")
    }

    return DoctorCheck(
        status: "blocker",
        name: "accessibility-trust",
        detail: "current process is not trusted for Accessibility; grant Accessibility to the terminal app that launches winpointer"
    )
}

private func checkEventTapCreation(_ placement: EventTapPlacement) -> DoctorCheck {
    let mask = CGEventMask(1) << CGEventType.mouseMoved.rawValue
    guard let tap = CGEvent.tapCreate(
        tap: placement.cgLocation,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: doctorEventTapCallback,
        userInfo: nil
    ) else {
        return DoctorCheck(
            status: "blocker",
            name: "cg-event-\(placement.rawValue)-tap",
            detail: "could not create listen-only tap; grant Accessibility/Input Monitoring to the terminal app"
        )
    }

    CGEvent.tapEnable(tap: tap, enable: false)
    CFMachPortInvalidate(tap)
    return DoctorCheck(status: "ok", name: "cg-event-\(placement.rawValue)-tap", detail: "listen-only tap can be created")
}

private func checkActiveEventTapCreation(_ placement: EventTapPlacement) -> DoctorCheck {
    let mask = CGEventMask(1) << CGEventType.mouseMoved.rawValue
    guard let tap = CGEvent.tapCreate(
        tap: placement.cgLocation,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: doctorEventTapCallback,
        userInfo: nil
    ) else {
        return DoctorCheck(
            status: "blocker",
            name: "active-\(placement.rawValue)-tap",
            detail: "could not create active pass-through tap; \(activeTapPermissionHint())"
        )
    }

    CFMachPortInvalidate(tap)
    return DoctorCheck(status: "ok", name: "active-\(placement.rawValue)-tap", detail: "active pass-through tap can be created")
}

private func activeTapPermissionHint() -> String {
    if AXIsProcessTrusted() {
        return "Accessibility is trusted, so verify Input Monitoring for the terminal app"
    }
    return "grant Accessibility to the terminal app that launches winpointer; Full Disk Access is not sufficient"
}

private func seconds(_ nanoseconds: UInt64) -> Double {
    max(Double(nanoseconds) / 1_000_000_000.0, Double.leastNonzeroMagnitude)
}

private func formatSeconds(_ nanoseconds: UInt64) -> String {
    "\(formatDouble(seconds(nanoseconds), fractionDigits: 6))s"
}

private func formatDouble(_ value: Double, fractionDigits: Int) -> String {
    "%.\(fractionDigits)f".withCString { format in
        String(format: String(cString: format), value)
    }
}

private func printRunDryRun(config: PointerAccelerationConfig) {
    let services = HIDServiceDiagnostics.listServices()
    let candidates = services.filter(\.isCandidate)
    let protected = services.filter(\.isProtected)

    print("run dry-run")
    print("speed=\(config.speed) sensitivity=\(config.sensitivity) input-scale=\(config.inputScale)")
    print("candidate-services=\(candidates.count) protected-services=\(protected.count)")

    if candidates.isEmpty {
        print("blocker: no external HID mouse service candidate was found")
        return
    }

    for service in candidates {
        print("candidate: \(service.productName) registry=\(service.registryID) usage=\(service.usageDescription) transport=\(service.transport)")
        if service.accelerationProperties.isEmpty {
            print("  visible-acceleration-properties: none")
        } else {
            for property in service.accelerationProperties {
                print("  \(property.key)=\(property.valueDescription)")
            }
        }
    }

    let supportsVisiblePointerCurve = candidates.contains { service in
        service.accelerationProperties.contains { property in
            property.key == "HIDAccelCurves" || property.key == "IOHIDSetAcceleration"
        }
    }

    if !supportsVisiblePointerCurve {
        print("blocker: candidate service does not expose HIDAccelCurves or IOHIDSetAcceleration as readable properties")
        print("next: per-device HID curve control remains blocked; use the CGEvent stage2 gate before any experimental run --real test")
        return
    }

    print("blocker: curve write format is not implemented yet")
}

private func printTransform(raw: RawDelta, transformed: TransformedDelta, config: PointerAccelerationConfig) {
    print("speed=\(config.speed) sensitivity=\(config.sensitivity) input-scale=\(config.inputScale)")
    print(
        "raw=(\(raw.dx),\(raw.dy)) magnitude=\(transformed.magnitude) lookup-magnitude=\(transformed.lookupMagnitude) gain=\(String(format: "%.5f", transformed.gain)) transformed=(\(transformed.dx),\(transformed.dy)) remainder=(\(String(format: "%.5f", transformed.remainderX)),\(String(format: "%.5f", transformed.remainderY)))"
    )
}

enum EventTapPlacement: String {
    case session
    case hid

    static func parse(_ value: String) throws -> EventTapPlacement {
        switch value {
        case "session":
            return .session
        case "hid":
            return .hid
        default:
            throw CLIError.usage("--tap must be session or hid")
        }
    }

    var cgLocation: CGEventTapLocation {
        switch self {
        case .session:
            return .cgSessionEventTap
        case .hid:
            return .cghidEventTap
        }
    }
}

private struct RealRunGate {
    let tapPlacement: EventTapPlacement
    let fieldName: String
    let attributionField: CGEventField
    let externalValue: String
    let trackpadValue: String
    let externalIntegerValue: Int64
    let trackpadIntegerValue: Int64
}

private func loadRealRunGate(path: String) throws -> RealRunGate {
    let object = try loadJSONObject(path: path, expectedKind: "stage2-gate-result")
    guard object["result"] as? String == "ready" else {
        throw CLIError.runtime("stage2 gate is not ready; run stage2-gate again and resolve blockers before using run --real")
    }
    guard let tapValue = object["tap"] as? String else {
        throw CLIError.runtime("stage2 gate output is missing tap")
    }
    let tapPlacement = try EventTapPlacement.parse(tapValue)
    guard let candidate = object["candidate"] as? [String: Any],
          let fieldName = candidate["name"] as? String,
          let externalValue = jsonStringValue(candidate["external"]),
          let trackpadValue = jsonStringValue(candidate["trackpad"]) else {
        throw CLIError.runtime("stage2 gate output is missing candidate field values")
    }
    guard attributionCandidateFields.contains(fieldName) else {
        throw CLIError.runtime("stage2 gate candidate field \(fieldName) is not allowed for real run")
    }
    guard let attributionField = eventDebugIntegerField(named: fieldName) else {
        throw CLIError.runtime("stage2 gate candidate field \(fieldName) cannot be read from CGEvent")
    }
    guard externalValue != trackpadValue else {
        throw CLIError.runtime("stage2 gate external and trackpad values must differ")
    }
    guard let externalIntegerValue = Int64(externalValue),
          let trackpadIntegerValue = Int64(trackpadValue) else {
        throw CLIError.runtime("stage2 gate candidate values must be integer CGEvent field values")
    }

    return RealRunGate(
        tapPlacement: tapPlacement,
        fieldName: fieldName,
        attributionField: attributionField,
        externalValue: externalValue,
        trackpadValue: trackpadValue,
        externalIntegerValue: externalIntegerValue,
        trackpadIntegerValue: trackpadIntegerValue
    )
}

final class ProbeRunner {
    enum OutputFormat {
        case text
        case json
    }

    private let accelerator: PointerAccelerator
    private let maxSamples: Int
    private let tapPlacement: EventTapPlacement
    private let debugFields: Bool
    private let summary: Bool
    private let quiet: Bool
    private let outputFormat: OutputFormat
    private var sampleCount = 0
    private var fieldCounts: [String: [String: Int]] = [:]
    private var totalAbsDx = 0
    private var totalAbsDy = 0
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?

    init(
        config: PointerAccelerationConfig,
        maxSamples: Int,
        tapPlacement: EventTapPlacement,
        debugFields: Bool,
        summary: Bool,
        quiet: Bool,
        outputFormat: OutputFormat
    ) throws {
        self.accelerator = try PointerAccelerator(config: config)
        self.maxSamples = maxSamples
        self.tapPlacement = tapPlacement
        self.debugFields = debugFields
        self.summary = summary
        self.quiet = quiet
        self.outputFormat = outputFormat
    }

    func start() throws {
        let mask = eventMask([
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ])

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: tapPlacement.cgLocation,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: probeCallback,
            userInfo: refcon
        ) else {
            throw CLIError.runtime("could not create \(tapPlacement.rawValue) event tap. Grant Accessibility/Input Monitoring permissions to the terminal app and retry.")
        }

        self.eventTap = eventTap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            throw CLIError.runtime("could not create event tap run loop source")
        }

        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            throw CLIError.runtime("could not get current run loop")
        }
        runLoop = currentRunLoop
        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        if outputFormat == .text {
            printFlush("Listening for \(maxSamples) mouse movement samples on \(tapPlacement.rawValue) tap. This prototype only observes; it does not move the pointer.")
            if summary {
                printFlush("summary=true; collect one run with the external mouse and one run with the trackpad, then compare stable fields.")
            }
            if quiet {
                printFlush("quiet=true; per-event output is disabled, final summary still prints.")
            }
        }
        CFRunLoopRun()
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
        if summary {
            try printEventFieldSummary()
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let raw = RawDelta(
            dx: Int(event.getIntegerValueField(.mouseEventDeltaX)),
            dy: Int(event.getIntegerValueField(.mouseEventDeltaY))
        )
        let transformed = accelerator.transform(raw)
        sampleCount += 1
        let snapshot = eventDebugSnapshot(type: type, event: event)
        if summary {
            recordSummary(snapshot: snapshot, raw: raw)
        }
        if !quiet {
            var line = "\(sampleCount): raw=(\(raw.dx),\(raw.dy)) magnitude=\(transformed.magnitude) lookup-magnitude=\(transformed.lookupMagnitude) gain=\(String(format: "%.5f", transformed.gain)) transformed=(\(transformed.dx),\(transformed.dy))"
            if debugFields {
                line += " \(snapshot.description)"
            }
            printFlush(line)
        }

        if sampleCount >= maxSamples, let runLoop {
            CFRunLoopStop(runLoop)
        }

        return Unmanaged.passUnretained(event)
    }

    private func eventMask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private func recordSummary(snapshot: EventDebugSnapshot, raw: RawDelta) {
        totalAbsDx += abs(raw.dx)
        totalAbsDy += abs(raw.dy)

        for field in snapshot.fields {
            var values = fieldCounts[field.name, default: [:]]
            values[field.value, default: 0] += 1
            fieldCounts[field.name] = values
        }
    }

    private func printEventFieldSummary() throws {
        let summary = EventSummary(
            tap: tapPlacement.rawValue,
            samples: sampleCount,
            totalAbsDx: totalAbsDx,
            totalAbsDy: totalAbsDy,
            fieldCounts: fieldCounts
        )

        switch outputFormat {
        case .text:
            printFlush("event-field-summary")
            printFlush("tap=\(summary.tap) samples=\(summary.samples) total-abs-delta=(\(summary.totalAbsDx),\(summary.totalAbsDy))")
            for field in summary.fields {
                let stability = field.isStable ? "stable" : "variable"
                let topValues = field.topValues(limit: 8)
                    .map { "\($0.value):\($0.count)" }
                    .joined(separator: ",")
                printFlush("  \(field.name): \(stability) unique=\(field.values.count) values=\(topValues)")
            }
            printFlush("interpretation: only a field that is stable within one device run and different between external-mouse and trackpad runs is useful for safe CGEvent attribution.")
        case .json:
            printFlush(try summary.jsonString())
        }
    }
}

final class AttributionProbeRunner {
    private struct ClassificationStats {
        var count = 0
        var totalAbsDx = 0
        var totalAbsDy = 0
    }

    private enum Classification: String, CaseIterable {
        case external
        case trackpad
        case unknown
    }

    private let tapPlacement: EventTapPlacement
    private let maxSamples: Int
    private let fieldName: String
    private let externalValue: String
    private let trackpadValue: String
    private let quiet: Bool
    private let outputJSON: Bool
    private var sampleCount = 0
    private var stats: [Classification: ClassificationStats] = [:]
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?

    init(
        tapPlacement: EventTapPlacement,
        maxSamples: Int,
        fieldName: String,
        externalValue: String,
        trackpadValue: String,
        quiet: Bool,
        outputJSON: Bool
    ) {
        self.tapPlacement = tapPlacement
        self.maxSamples = maxSamples
        self.fieldName = fieldName
        self.externalValue = externalValue
        self.trackpadValue = trackpadValue
        self.quiet = quiet
        self.outputJSON = outputJSON
    }

    func start() throws {
        let mask = eventMask([
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ])

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: tapPlacement.cgLocation,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: attributionProbeCallback,
            userInfo: refcon
        ) else {
            throw CLIError.runtime("could not create \(tapPlacement.rawValue) event tap. Grant Accessibility/Input Monitoring permissions to the terminal app and retry.")
        }

        self.eventTap = eventTap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            throw CLIError.runtime("could not create event tap run loop source")
        }

        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            throw CLIError.runtime("could not get current run loop")
        }
        runLoop = currentRunLoop
        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        if !outputJSON {
            printFlush("Listening for \(maxSamples) events on \(tapPlacement.rawValue) tap. Attribution probe is listen-only; it does not move the pointer.")
            printFlush("classifier=\(fieldName) external=\(externalValue) trackpad=\(trackpadValue)")
            if quiet {
                printFlush("quiet=true; per-event output is disabled, final stats still print.")
            }
        }

        CFRunLoopRun()
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
        try printSummary()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let raw = RawDelta(
            dx: Int(event.getIntegerValueField(.mouseEventDeltaX)),
            dy: Int(event.getIntegerValueField(.mouseEventDeltaY))
        )
        let snapshot = eventDebugSnapshot(type: type, event: event)
        let value = snapshot.value(named: fieldName) ?? "<missing>"
        let classification = classify(value: value)
        sampleCount += 1

        var current = stats[classification, default: ClassificationStats()]
        current.count += 1
        current.totalAbsDx += abs(raw.dx)
        current.totalAbsDy += abs(raw.dy)
        stats[classification] = current

        if !quiet {
            printFlush("\(sampleCount): class=\(classification.rawValue) \(fieldName)=\(value) raw=(\(raw.dx),\(raw.dy))")
        }

        if sampleCount >= maxSamples, let runLoop {
            CFRunLoopStop(runLoop)
        }

        return Unmanaged.passUnretained(event)
    }

    private func eventMask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private func classify(value: String) -> Classification {
        if value == externalValue {
            return .external
        }
        if value == trackpadValue {
            return .trackpad
        }
        return .unknown
    }

    private func printSummary() throws {
        let unknownCount = stats[.unknown, default: ClassificationStats()].count
        let result = unknownCount > 0 ? "needs-review" : "classified"
        let reason: Any = unknownCount > 0
            ? "some events did not match the external or trackpad attribution values"
            : NSNull()

        if outputJSON {
            let object: [String: Any] = [
                "schemaVersion": 1,
                "kind": "attribution-probe-result",
                "tap": tapPlacement.rawValue,
                "samples": sampleCount,
                "field": fieldName,
                "expectedValues": [
                    "external": externalValue,
                    "trackpad": trackpadValue,
                ],
                "classes": classificationStatsObject(),
                "result": result,
                "reason": reason,
                "mode": "listen-only",
            ]
            printFlush(try encodeJSONString(object))
            return
        }

        printFlush("attribution-probe-summary")
        printFlush("tap=\(tapPlacement.rawValue) samples=\(sampleCount) field=\(fieldName)")
        for classification in Classification.allCases {
            let current = stats[classification, default: ClassificationStats()]
            printFlush("  \(classification.rawValue): count=\(current.count) total-abs-delta=(\(current.totalAbsDx),\(current.totalAbsDy))")
        }

        if unknownCount > 0 {
            printFlush("result=needs-review")
            printFlush("reason=some events did not match the external or trackpad attribution values")
        } else {
            printFlush("result=classified")
            printFlush("next=repeat once moving only the external mouse and once moving only the trackpad before considering any real interception path")
        }
    }

    private func classificationStatsObject() -> [String: Any] {
        var object: [String: Any] = [:]
        for classification in Classification.allCases {
            let current = stats[classification, default: ClassificationStats()]
            object[classification.rawValue] = [
                "count": current.count,
                "totalAbsDelta": [
                    "dx": current.totalAbsDx,
                    "dy": current.totalAbsDy,
                ],
            ]
        }
        return object
    }
}

final class PassThroughProbeRunner {
    private let tapPlacement: EventTapPlacement
    private let maxSamples: Int
    private let timeoutMilliseconds: Int
    private let quiet: Bool
    private let outputJSON: Bool
    private var sampleCount = 0
    private var timeoutCount = 0
    private var userDisabledCount = 0
    private var totalAbsDx = 0
    private var totalAbsDy = 0
    private var startedAt: UInt64 = 0
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?

    init(
        tapPlacement: EventTapPlacement,
        maxSamples: Int,
        timeoutMilliseconds: Int,
        quiet: Bool,
        outputJSON: Bool
    ) {
        self.tapPlacement = tapPlacement
        self.maxSamples = maxSamples
        self.timeoutMilliseconds = timeoutMilliseconds
        self.quiet = quiet
        self.outputJSON = outputJSON
    }

    func start() throws {
        let mask = eventMask([
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ])

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: tapPlacement.cgLocation,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: passThroughProbeCallback,
            userInfo: refcon
        ) else {
            throw CLIError.runtime("could not create active \(tapPlacement.rawValue) event tap. \(activeTapPermissionHint())")
        }

        self.eventTap = eventTap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            throw CLIError.runtime("could not create event tap run loop source")
        }

        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            throw CLIError.runtime("could not get current run loop")
        }
        runLoop = currentRunLoop
        let timeout = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Double(timeoutMilliseconds) / 1000.0,
            0,
            0,
            0
        ) { [weak self] _ in
            guard let self, let runLoop = self.runLoop else {
                return
            }
            CFRunLoopStop(runLoop)
        }

        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        CFRunLoopAddTimer(currentRunLoop, timeout, .commonModes)
        startedAt = DispatchTime.now().uptimeNanoseconds
        CGEvent.tapEnable(tap: eventTap, enable: true)

        if !outputJSON {
            printFlush("Running active pass-through \(tapPlacement.rawValue) tap for up to \(maxSamples) events or \(timeoutMilliseconds)ms.")
            printFlush("mode=pass-through; every event is returned unchanged; no pointer movement is injected or suppressed.")
            if quiet {
                printFlush("quiet=true; per-event output is disabled, final stats still print.")
            }
        }

        CFRunLoopRun()

        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFRunLoopRemoveTimer(currentRunLoop, timeout, .commonModes)
        CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
        CFMachPortInvalidate(eventTap)
        try printSummary()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            timeoutCount += 1
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByUserInput {
            userDisabledCount += 1
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let raw = RawDelta(
            dx: Int(event.getIntegerValueField(.mouseEventDeltaX)),
            dy: Int(event.getIntegerValueField(.mouseEventDeltaY))
        )
        sampleCount += 1
        totalAbsDx += abs(raw.dx)
        totalAbsDy += abs(raw.dy)

        if !quiet {
            printFlush("\(sampleCount): pass-through raw=(\(raw.dx),\(raw.dy)) type=\(type.rawValue)")
        }

        if sampleCount >= maxSamples, let runLoop {
            CFRunLoopStop(runLoop)
        }

        return Unmanaged.passUnretained(event)
    }

    private func eventMask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private func printSummary() throws {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        let reasons = passThroughReviewReasons()
        let result = reasons.isEmpty
            ? "pass-through-stable"
            : "needs-review"
        let reason: Any = reasons.isEmpty ? NSNull() : reasons.joined(separator: "; ")

        if outputJSON {
            let object: [String: Any] = [
                "schemaVersion": 1,
                "kind": "pass-through-probe-result",
                "tap": tapPlacement.rawValue,
                "samples": sampleCount,
                "requestedSamples": maxSamples,
                "elapsedSeconds": seconds(elapsed),
                "totalAbsDelta": [
                    "dx": totalAbsDx,
                    "dy": totalAbsDy,
                ],
                "tapDisabledByTimeout": timeoutCount,
                "tapDisabledByUserInput": userDisabledCount,
                "result": result,
                "reason": reason,
                "mode": "active-pass-through",
            ]
            printFlush(try encodeJSONString(object))
            return
        }

        printFlush("pass-through-probe-summary")
        printFlush("tap=\(tapPlacement.rawValue) samples=\(sampleCount) elapsed=\(formatSeconds(elapsed))")
        printFlush("total-abs-delta=(\(totalAbsDx),\(totalAbsDy))")
        printFlush("tap-disabled-by-timeout=\(timeoutCount) tap-disabled-by-user-input=\(userDisabledCount)")
        if result == "pass-through-stable" {
            printFlush("result=pass-through-stable")
            printFlush("next=this only proves active tap pass-through stability; experimental mutation still requires stage2-gate readiness")
        } else {
            printFlush("result=needs-review")
            for currentReason in reasons {
                printFlush("reason=\(currentReason)")
            }
        }
    }

    private func passThroughReviewReasons() -> [String] {
        var reasons: [String] = []
        if sampleCount < maxSamples {
            reasons.append("probe stopped before collecting requested samples")
        }
        if timeoutCount > 0 || userDisabledCount > 0 {
            reasons.append("the active tap was disabled while probing")
        }
        return reasons
    }
}

final class RealRunRunner {
    private let gate: RealRunGate
    private let maxSamples: Int?
    private let timeoutMilliseconds: Int?
    private let quiet: Bool
    private let controller: PointerController
    private var stats = PointerControlStats()
    private var timeoutCount = 0
    private var userDisabledCount = 0
    private var timeoutExpired = false
    private var startedAt: UInt64 = 0
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var signalSources: [DispatchSourceSignal] = []

    fileprivate init(
        config: PointerAccelerationConfig,
        gate: RealRunGate,
        maxSamples: Int?,
        timeoutMilliseconds: Int?,
        quiet: Bool
    ) throws {
        self.gate = gate
        self.maxSamples = maxSamples
        self.timeoutMilliseconds = timeoutMilliseconds
        self.quiet = quiet
        let rule = try PointerControlRule(
            fieldName: gate.fieldName,
            externalValue: gate.externalValue,
            trackpadValue: gate.trackpadValue
        )
        self.controller = try PointerController(rule: rule, config: config)
    }

    func start() throws {
        let mask = eventMask([
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ])

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: gate.tapPlacement.cgLocation,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: realRunCallback,
            userInfo: refcon
        ) else {
            throw CLIError.runtime("could not create active \(gate.tapPlacement.rawValue) event tap. \(activeTapPermissionHint())")
        }

        self.eventTap = eventTap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            throw CLIError.runtime("could not create event tap run loop source")
        }

        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            throw CLIError.runtime("could not get current run loop")
        }
        runLoop = currentRunLoop
        installSignalHandlers(runLoop: currentRunLoop)
        let timeout = makeTimeout(runLoop: currentRunLoop)
        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        if let timeout {
            CFRunLoopAddTimer(currentRunLoop, timeout, .commonModes)
        }
        startedAt = DispatchTime.now().uptimeNanoseconds
        CGEvent.tapEnable(tap: eventTap, enable: true)

        if !quiet {
            printFlush("Running EXPERIMENTAL real-run on \(gate.tapPlacement.rawValue) tap. Press Ctrl-C to stop.")
            printFlush("classifier=\(gate.fieldName) external=\(gate.externalValue) trackpad=\(gate.trackpadValue)")
            printFlush("mode=active-event-mutation; external mouse deltas are transformed in-place; other events pass through unchanged.")
        }

        CFRunLoopRun()

        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let timeout {
            CFRunLoopRemoveTimer(currentRunLoop, timeout, .commonModes)
        }
        CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
        CFMachPortInvalidate(eventTap)
        cancelSignalHandlers()
        printSummary()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            timeoutCount += 1
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByUserInput {
            userDisabledCount += 1
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let raw = RawDelta(
            dx: Int(event.getIntegerValueField(.mouseEventDeltaX)),
            dy: Int(event.getIntegerValueField(.mouseEventDeltaY))
        )
        let decision = controller.process(
            classification: classifyAttributionValue(event.getIntegerValueField(gate.attributionField)),
            raw: raw
        )
        stats.record(decision)

        guard let transformed = decision.transformed else {
            stopIfSampleLimitReached()
            return Unmanaged.passUnretained(event)
        }

        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(transformed.dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(transformed.dy))
        event.location = transformedLocation(event.location, offset: decision.locationOffset)
        stopIfSampleLimitReached()

        return Unmanaged.passUnretained(event)
    }

    private func classifyAttributionValue(_ value: Int64) -> PointerEventClassification {
        if value == gate.externalIntegerValue {
            return .external
        }
        if value == gate.trackpadIntegerValue {
            return .trackpad
        }
        return .unknown
    }

    private func stopIfSampleLimitReached() {
        if stats.hasReachedSampleLimit(maxSamples), let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    private func eventMask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private func transformedLocation(_ location: CGPoint, offset: RawDelta) -> CGPoint {
        CGPoint(
            x: location.x + CGFloat(offset.dx),
            y: location.y + CGFloat(offset.dy)
        )
    }

    private func makeTimeout(runLoop: CFRunLoop) -> CFRunLoopTimer? {
        guard let timeoutMilliseconds else {
            return nil
        }
        return CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Double(timeoutMilliseconds) / 1000.0,
            0,
            0,
            0
        ) { [weak self] _ in
            self?.timeoutExpired = true
            CFRunLoopStop(runLoop)
        }
    }

    private func installSignalHandlers(runLoop: CFRunLoop) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                printFlush("Received signal \(signalNumber); stopping experimental real-run.")
                CFRunLoopStop(runLoop)
            }
            source.resume()
            return source
        }
    }

    private func cancelSignalHandlers() {
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }

    private func printSummary() {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        printFlush("Stopped experimental real-run.")
        printFlush("processed-events=\(stats.processedEvents) transformed-events=\(stats.transformedEvents) passed-through-events=\(stats.passedThroughEvents) unknown-events=\(stats.unknownEvents)")
        printFlush("tap-disabled-by-timeout=\(timeoutCount) tap-disabled-by-user-input=\(userDisabledCount)")
        printFlush("timeout-expired=\(timeoutExpired)")
        printFlush("elapsed=\(formatSeconds(elapsed))")
    }
}

final class HIDOverlayRealRunRunner {
    private struct PendingReport {
        var timestamp: UInt64
        var dx = 0
        var dy = 0
    }

    private struct PendingMatch {
        let raw: RawDelta
        let transformed: TransformedDelta
        let target: CGPoint
        let deviceID: String
        let hidTimestamp: UInt64
        let createdAt: UInt64
    }

    private let maxSamples: Int?
    private let timeoutMilliseconds: Int?
    private let quiet: Bool
    private let candidateIDs: Set<String>
    private let accelerator: PointerAccelerator
    private var displayBounds: [CGRect]
    private var lastDisplayBoundsRefresh: UInt64
    private static let syntheticEventMarker: Int64 = 0x57504D414331
    private static let cursorResyncThresholdSquared: CGFloat = 64 * 64
    private static let displayBoundsRefreshInterval: UInt64 = 1_000_000_000
    private var hidReportCount = 0
    private var eventCount = 0
    private var matchedEventCount = 0
    private var passedThroughEventCount = 0
    private var droppedMatchCount = 0
    private var hidDrivenMoveCount = 0
    private var warpFailureCount = 0
    private var syntheticEventCount = 0
    private var syntheticEventFailureCount = 0
    private var timeoutCount = 0
    private var userDisabledCount = 0
    private var timeoutExpired = false
    private var startedAt: UInt64 = 0
    private var runLoop: CFRunLoop?
    private var manager: IOHIDManager?
    private var eventTap: CFMachPort?
    private var virtualCursorPosition: CGPoint?
    private var pendingByDevice: [String: PendingReport] = [:]
    private var pendingMatches: [PendingMatch] = []
    private var signalSources: [DispatchSourceSignal] = []

    init(
        config: PointerAccelerationConfig,
        maxSamples: Int?,
        timeoutMilliseconds: Int?,
        quiet: Bool
    ) throws {
        self.maxSamples = maxSamples
        self.timeoutMilliseconds = timeoutMilliseconds
        self.quiet = quiet
        self.accelerator = try PointerAccelerator(config: config)
        self.displayBounds = Self.activeDisplayBounds()
        self.lastDisplayBoundsRefresh = DispatchTime.now().uptimeNanoseconds
        self.candidateIDs = Set(
            DeviceEnumerator.listDevices()
                .filter(\.isCandidate)
                .map(\.id)
        )
    }

    func start() throws {
        guard !candidateIDs.isEmpty else {
            throw CLIError.runtime("no external HID mouse candidates found")
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: NSDictionary = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            if result == kIOReturnNotPermitted {
                throw CLIError.runtime("could not open IOHIDManager: \(formatIOReturn(result)) not permitted. Grant Input Monitoring permission to the terminal app and retry.")
            }
            throw CLIError.runtime("could not open IOHIDManager: \(formatIOReturn(result))")
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, hidOverlayValueCallback, refcon)

        let mask = eventMask([
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ])
        guard let eventTap = CGEvent.tapCreate(
            tap: CGEventTapLocation.cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hidOverlayEventCallback,
            userInfo: refcon
        ) else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw CLIError.runtime("could not create active hid event tap. \(activeTapPermissionHint())")
        }
        self.eventTap = eventTap

        guard let eventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw CLIError.runtime("could not create event tap run loop source")
        }

        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            CFMachPortInvalidate(eventTap)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw CLIError.runtime("could not get current run loop")
        }
        runLoop = currentRunLoop
        installSignalHandlers(runLoop: currentRunLoop)
        let timeout = makeTimeout(runLoop: currentRunLoop)
        CFRunLoopAddSource(currentRunLoop, eventSource, .commonModes)
        IOHIDManagerScheduleWithRunLoop(manager, currentRunLoop, CFRunLoopMode.commonModes.rawValue)
        if let timeout {
            CFRunLoopAddTimer(currentRunLoop, timeout, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)

        if !quiet {
            printFlush("Running EXPERIMENTAL HID-driven real-run. Press Ctrl-C to stop.")
            printFlush("mode=hid-driven-takeover; external HID reports move the cursor immediately, matched macOS events are swallowed and replaced.")
            printFlush("candidate-ids=\(candidateIDs.sorted().joined(separator: ","))")
        }

        startedAt = DispatchTime.now().uptimeNanoseconds
        CFRunLoopRun()
        flushPendingReports()

        if let timeout {
            CFRunLoopRemoveTimer(currentRunLoop, timeout, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFRunLoopRemoveSource(currentRunLoop, eventSource, .commonModes)
        CFMachPortInvalidate(eventTap)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, currentRunLoop, CFRunLoopMode.commonModes.rawValue)
        cancelSignalHandlers()
        printSummary()
    }

    func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        guard usagePage == kHIDPage_GenericDesktop,
              usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y else {
            return
        }

        let device = IOHIDElementGetDevice(element)
        let deviceID = Self.deviceID(device)
        guard candidateIDs.contains(deviceID) else {
            return
        }

        let integerValue = IOHIDValueGetIntegerValue(value)
        let timestamp = IOHIDValueGetTimeStamp(value)

        if let pending = pendingByDevice[deviceID], pending.timestamp != timestamp {
            emitReport(deviceID: deviceID, report: pending)
        }

        var report = pendingByDevice[deviceID] ?? PendingReport(timestamp: timestamp)
        report.timestamp = timestamp
        if usage == kHIDUsage_GD_X {
            report.dx = integerValue
        } else {
            report.dy = integerValue
        }
        pendingByDevice[deviceID] = report
    }

    private func flushPendingReports() {
        for (deviceID, report) in pendingByDevice {
            emitReport(deviceID: deviceID, report: report)
        }
        pendingByDevice.removeAll()
    }

    private func emitReport(deviceID: String, report: PendingReport) {
        guard report.dx != 0 || report.dy != 0 else {
            pendingByDevice.removeValue(forKey: deviceID)
            return
        }

        let raw = RawDelta(dx: report.dx, dy: report.dy)
        let transformed = accelerator.transform(raw)
        let base = cursorBaseLocation()
        let target = transformedLocation(base, transformed: transformed)
        if CGWarpMouseCursorPosition(target) != .success {
            warpFailureCount += 1
            virtualCursorPosition = nil
        } else {
            hidDrivenMoveCount += 1
            virtualCursorPosition = target
        }

        hidReportCount += 1
        pendingMatches.append(PendingMatch(
            raw: raw,
            transformed: transformed,
            target: target,
            deviceID: deviceID,
            hidTimestamp: report.timestamp,
            createdAt: DispatchTime.now().uptimeNanoseconds
        ))
        if pendingMatches.count > 128 {
            pendingMatches.removeFirst()
            droppedMatchCount += 1
        }

        pendingByDevice.removeValue(forKey: deviceID)
        if !quiet {
            printFlush("hid \(hidReportCount): raw=(\(raw.dx),\(raw.dy)) magnitude=\(transformed.magnitude) lookup-magnitude=\(transformed.lookupMagnitude) transformed=(\(transformed.dx),\(transformed.dy)) target=(\(Int(target.x)),\(Int(target.y))) pending-matches=\(pendingMatches.count)")
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            timeoutCount += 1
            virtualCursorPosition = nil
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByUserInput {
            userDisabledCount += 1
            virtualCursorPosition = nil
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let eventRaw = RawDelta(
            dx: Int(event.getIntegerValueField(.mouseEventDeltaX)),
            dy: Int(event.getIntegerValueField(.mouseEventDeltaY))
        )
        guard eventRaw.dx != 0 || eventRaw.dy != 0 else {
            return Unmanaged.passUnretained(event)
        }

        eventCount += 1
        flushPendingReports()
        pruneExpiredMatches()
        guard let matchIndex = matchIndex(for: eventRaw, eventTimestamp: event.timestamp) else {
            passedThroughEventCount += 1
            virtualCursorPosition = nil
            return Unmanaged.passUnretained(event)
        }

        let match = pendingMatches.remove(at: matchIndex)
        let syntheticTarget = virtualCursorPosition ?? match.target
        if postSyntheticEvent(from: event, target: syntheticTarget, transformed: match.transformed) {
            syntheticEventCount += 1
        } else {
            syntheticEventFailureCount += 1
        }
        matchedEventCount += 1
        if !quiet {
            printFlush("match \(matchedEventCount): device=\(match.deviceID) event-raw=(\(eventRaw.dx),\(eventRaw.dy)) hid-raw=(\(match.raw.dx),\(match.raw.dy)) lookup-magnitude=\(match.transformed.lookupMagnitude) transformed=(\(match.transformed.dx),\(match.transformed.dy)) synthetic-target=(\(Int(syntheticTarget.x)),\(Int(syntheticTarget.y)))")
        }

        if let maxSamples, matchedEventCount >= maxSamples, let runLoop {
            pendingByDevice.removeAll()
            pendingMatches.removeAll()
            virtualCursorPosition = nil
            CFRunLoopStop(runLoop)
        }

        return nil
    }

    private func matchIndex(for eventRaw: RawDelta, eventTimestamp: UInt64) -> Int? {
        if let exact = pendingMatches.firstIndex(where: { $0.raw == eventRaw }) {
            return exact
        }

        let compatible = pendingMatches.enumerated().filter { _, match in
            directionsAreCompatible(eventRaw: eventRaw, hidRaw: match.raw)
        }
        guard !compatible.isEmpty else {
            return nil
        }

        if eventTimestamp > 0 {
            return compatible.min { lhs, rhs in
                timestampDistance(lhs.element.hidTimestamp, eventTimestamp)
                    < timestampDistance(rhs.element.hidTimestamp, eventTimestamp)
            }?.offset
        }
        return compatible.first?.offset
    }

    private func directionsAreCompatible(eventRaw: RawDelta, hidRaw: RawDelta) -> Bool {
        axisIsCompatible(eventRaw.dx, hidRaw.dx)
            && axisIsCompatible(eventRaw.dy, hidRaw.dy)
            && (hidRaw.dx != 0 || hidRaw.dy != 0)
    }

    private func axisIsCompatible(_ eventValue: Int, _ hidValue: Int) -> Bool {
        eventValue == 0 || hidValue == 0 || (eventValue > 0) == (hidValue > 0)
    }

    private func pruneExpiredMatches() {
        let now = DispatchTime.now().uptimeNanoseconds
        let before = pendingMatches.count
        pendingMatches.removeAll { match in
            now - match.createdAt > 100_000_000
        }
        droppedMatchCount += before - pendingMatches.count
    }

    private func eventMask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private func timestampDistance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : rhs - lhs
    }

    private func postSyntheticEvent(from original: CGEvent, target: CGPoint, transformed: TransformedDelta) -> Bool {
        guard let synthetic = original.copy() else {
            return false
        }
        synthetic.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        synthetic.setIntegerValueField(.mouseEventDeltaX, value: Int64(transformed.dx))
        synthetic.setIntegerValueField(.mouseEventDeltaY, value: Int64(transformed.dy))
        synthetic.location = target
        synthetic.post(tap: .cgSessionEventTap)
        return true
    }

    private func currentCursorLocation(fallback: CGPoint) -> CGPoint {
        CGEvent(source: nil)?.location ?? fallback
    }

    private func cursorBaseLocation() -> CGPoint {
        let actual = currentCursorLocation(fallback: virtualCursorPosition ?? .zero)
        refreshDisplayBoundsIfNeeded(force: containingDisplayIndex(for: actual) == nil)

        guard let virtual = virtualCursorPosition else {
            return actual
        }
        if shouldResyncCursor(actual: actual, virtual: virtual) {
            return actual
        }
        return virtual
    }

    private func shouldResyncCursor(actual: CGPoint, virtual: CGPoint) -> Bool {
        let actualDisplay = containingDisplayIndex(for: actual)
        let virtualDisplay = containingDisplayIndex(for: virtual)
        if let actualDisplay, let virtualDisplay, actualDisplay != virtualDisplay {
            return true
        }
        if actualDisplay != nil && virtualDisplay == nil {
            return true
        }
        return distanceSquared(from: actual, to: virtual) > Self.cursorResyncThresholdSquared
    }

    private func refreshDisplayBoundsIfNeeded(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || now - lastDisplayBoundsRefresh >= Self.displayBoundsRefreshInterval else {
            return
        }

        let refreshed = Self.activeDisplayBounds()
        if !refreshed.isEmpty {
            displayBounds = refreshed
        }
        lastDisplayBoundsRefresh = now
    }

    private func transformedLocation(_ location: CGPoint, transformed: TransformedDelta) -> CGPoint {
        clampToDisplayBounds(
            CGPoint(
                x: location.x + CGFloat(transformed.dx),
                y: location.y + CGFloat(transformed.dy)
            )
        )
    }

    private func clampToDisplayBounds(_ point: CGPoint) -> CGPoint {
        guard !displayBounds.isEmpty else {
            return point
        }
        if displayBounds.contains(where: { $0.contains(point) }) {
            return point
        }
        return displayBounds
            .map { bounds in clampedPoint(point, to: bounds) }
            .min { lhs, rhs in
                distanceSquared(from: point, to: lhs) < distanceSquared(from: point, to: rhs)
            } ?? point
    }

    private func clampedPoint(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else {
            return point
        }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }

    private func containingDisplayIndex(for point: CGPoint) -> Int? {
        displayBounds.firstIndex { $0.contains(point) }
    }

    private func distanceSquared(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func makeTimeout(runLoop: CFRunLoop) -> CFRunLoopTimer? {
        guard let timeoutMilliseconds else {
            return nil
        }
        return CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Double(timeoutMilliseconds) / 1000.0,
            0,
            0,
            0
        ) { [weak self] _ in
            self?.timeoutExpired = true
            CFRunLoopStop(runLoop)
        }
    }

    private func installSignalHandlers(runLoop: CFRunLoop) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                printFlush("Received signal \(signalNumber); stopping HID overlay real-run.")
                CFRunLoopStop(runLoop)
            }
            source.resume()
            return source
        }
    }

    private func cancelSignalHandlers() {
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }

    private func printSummary() {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        printFlush("Stopped HID-driven real-run.")
        printFlush("hid-reports=\(hidReportCount) cg-events=\(eventCount) matched-events=\(matchedEventCount) passed-through-events=\(passedThroughEventCount) pending-matches=\(pendingMatches.count) dropped-matches=\(droppedMatchCount)")
        printFlush("hid-driven-moves=\(hidDrivenMoveCount)")
        printFlush("warp-failures=\(warpFailureCount)")
        printFlush("synthetic-events=\(syntheticEventCount) synthetic-event-failures=\(syntheticEventFailureCount)")
        printFlush("tap-disabled-by-timeout=\(timeoutCount) tap-disabled-by-user-input=\(userDisabledCount)")
        printFlush("timeout-expired=\(timeoutExpired)")
        printFlush("elapsed=\(formatSeconds(elapsed))")
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return []
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let result = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(displayCount, buffer.baseAddress, &displayCount)
        }
        guard result == .success else {
            return []
        }

        return displays
            .prefix(Int(displayCount))
            .map(CGDisplayBounds)
            .filter { $0.width > 0 && $0.height > 0 }
    }

    private static func deviceID(_ device: IOHIDDevice) -> String {
        let vendor = intProperty(device, kIOHIDVendorIDKey).map(String.init) ?? "unknown"
        let product = intProperty(device, kIOHIDProductIDKey).map(String.init) ?? "unknown"
        let location = intProperty(device, kIOHIDLocationIDKey).map(String.init) ?? "unknown"
        return "\(vendor):\(product):\(location)"
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        if let number = IOHIDDeviceGetProperty(device, (key as NSString) as CFString) as? NSNumber {
            return number.intValue
        }
        return nil
    }
}

final class HIDRawProbeRunner {
    enum Mode {
        case probe
        case shadowRun

        var description: String {
            switch self {
            case .probe:
                return "probe"
            case .shadowRun:
                return "shadow-run"
            }
        }
    }

    private struct PendingReport {
        var timestamp: UInt64
        var dx = 0
        var dy = 0
    }

    private let maxSamples: Int?
    private let mode: Mode
    private let quiet: Bool
    private let candidateIDs: Set<String>
    private let accelerator: PointerAccelerator
    private var sampleCount = 0
    private var startedAt: UInt64 = 0
    private var transformTimeNanoseconds: UInt64 = 0
    private var runLoop: CFRunLoop?
    private var manager: IOHIDManager?
    private var pendingByDevice: [String: PendingReport] = [:]
    private var signalSources: [DispatchSourceSignal] = []

    init(config: PointerAccelerationConfig, maxSamples: Int?, mode: Mode, quiet: Bool) throws {
        self.maxSamples = maxSamples
        self.mode = mode
        self.quiet = quiet
        self.accelerator = try PointerAccelerator(config: config)
        self.candidateIDs = Set(
            DeviceEnumerator.listDevices()
                .filter(\.isCandidate)
                .map(\.id)
        )
    }

    func start() throws {
        guard !candidateIDs.isEmpty else {
            throw CLIError.runtime("no external HID mouse candidates found")
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: NSDictionary = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            if result == kIOReturnNotPermitted {
                throw CLIError.runtime("could not open IOHIDManager: \(formatIOReturn(result)) not permitted. Grant Input Monitoring permission to the terminal app and retry.")
            }
            throw CLIError.runtime("could not open IOHIDManager: \(formatIOReturn(result))")
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, hidValueCallback, refcon)

        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw CLIError.runtime("could not get current run loop")
        }
        runLoop = currentRunLoop
        installSignalHandlers(runLoop: currentRunLoop)
        IOHIDManagerScheduleWithRunLoop(manager, currentRunLoop, CFRunLoopMode.commonModes.rawValue)

        if let maxSamples {
            printFlush("Listening for \(maxSamples) IOHID reports from external mouse candidate devices only.")
        } else {
            printFlush("Running HID \(mode.description) from external mouse candidate devices only. Press Ctrl-C to stop.")
        }
        printFlush("candidate-ids=\(candidateIDs.sorted().joined(separator: ","))")
        if quiet {
            printFlush("quiet=true; per-report output is disabled, final stats still print")
        }
        startedAt = DispatchTime.now().uptimeNanoseconds
        CFRunLoopRun()
        flushPendingReports()

        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, currentRunLoop, CFRunLoopMode.commonModes.rawValue)
        cancelSignalHandlers()
        printRuntimeStats()
    }

    func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        guard usagePage == kHIDPage_GenericDesktop,
              usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y else {
            return
        }

        let device = IOHIDElementGetDevice(element)

        let deviceID = Self.deviceID(device)
        guard candidateIDs.contains(deviceID) else {
            return
        }

        let axis = usage == kHIDUsage_GD_X ? "x" : "y"
        let integerValue = IOHIDValueGetIntegerValue(value)
        let timestamp = IOHIDValueGetTimeStamp(value)

        if let pending = pendingByDevice[deviceID], pending.timestamp != timestamp {
            emitReport(deviceID: deviceID, report: pending)
        }

        var report = pendingByDevice[deviceID] ?? PendingReport(timestamp: timestamp)
        report.timestamp = timestamp
        if axis == "x" {
            report.dx = integerValue
        } else {
            report.dy = integerValue
        }
        pendingByDevice[deviceID] = report
    }

    private func flushPendingReports() {
        for (deviceID, report) in pendingByDevice {
            emitReport(deviceID: deviceID, report: report)
        }
        pendingByDevice.removeAll()
    }

    private func emitReport(deviceID: String, report: PendingReport) {
        guard report.dx != 0 || report.dy != 0 else {
            pendingByDevice.removeValue(forKey: deviceID)
            return
        }

        let raw = RawDelta(dx: report.dx, dy: report.dy)
        let transformStarted = DispatchTime.now().uptimeNanoseconds
        let transformed = accelerator.transform(raw)
        transformTimeNanoseconds += DispatchTime.now().uptimeNanoseconds - transformStarted
        sampleCount += 1
        if !quiet {
            printFlush(
                "\(sampleCount): device=\(deviceID) raw=(\(raw.dx),\(raw.dy)) magnitude=\(transformed.magnitude) lookup-magnitude=\(transformed.lookupMagnitude) gain=\(String(format: "%.5f", transformed.gain)) transformed=(\(transformed.dx),\(transformed.dy)) timestamp=\(report.timestamp)"
            )
        }
        pendingByDevice.removeValue(forKey: deviceID)

        if let maxSamples, sampleCount >= maxSamples {
            pendingByDevice.removeAll()
            if let runLoop {
                CFRunLoopStop(runLoop)
            }
        }
    }

    private func printRuntimeStats() {
        let stoppedAt = DispatchTime.now().uptimeNanoseconds
        let elapsed = stoppedAt > startedAt ? stoppedAt - startedAt : 0
        let averageTransform = sampleCount > 0 ? Double(transformTimeNanoseconds) / Double(sampleCount) : 0
        let rate = sampleCount > 0 ? Double(sampleCount) / seconds(elapsed) : 0

        printFlush("Stopped HID \(mode.description).")
        printFlush("processed-reports=\(sampleCount)")
        printFlush("elapsed=\(formatSeconds(elapsed)) reports-per-second=\(formatDouble(rate, fractionDigits: 1))")
        printFlush("avg-transform-ns=\(formatDouble(averageTransform, fractionDigits: 1)) total-transform=\(formatSeconds(transformTimeNanoseconds))")
    }

    private static func deviceID(_ device: IOHIDDevice) -> String {
        let vendor = intProperty(device, kIOHIDVendorIDKey).map(String.init) ?? "unknown"
        let product = intProperty(device, kIOHIDProductIDKey).map(String.init) ?? "unknown"
        let location = intProperty(device, kIOHIDLocationIDKey).map(String.init) ?? "unknown"
        return "\(vendor):\(product):\(location)"
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        if let number = IOHIDDeviceGetProperty(device, (key as NSString) as CFString) as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func installSignalHandlers(runLoop: CFRunLoop) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                printFlush("Received signal \(signalNumber); stopping \(self.mode.description).")
                CFRunLoopStop(runLoop)
            }
            source.resume()
            return source
        }
    }

    private func cancelSignalHandlers() {
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}

private func formatIOReturn(_ value: IOReturn) -> String {
    let unsigned = UInt32(bitPattern: value)
    return "0x\(String(unsigned, radix: 16))"
}

private struct EventSummaryValueCount {
    let value: String
    let count: Int
}

private struct EventSummaryField {
    let name: String
    let values: [String: Int]

    var isStable: Bool {
        values.count == 1
    }

    var stableValue: String? {
        guard isStable else {
            return nil
        }
        return values.keys.first
    }

    func topValues(limit: Int) -> [EventSummaryValueCount] {
        values
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(limit)
            .map { EventSummaryValueCount(value: $0.key, count: $0.value) }
    }
}

private struct EventSummary {
    let tap: String
    let samples: Int
    let totalAbsDx: Int
    let totalAbsDy: Int
    let fieldCounts: [String: [String: Int]]

    var fields: [EventSummaryField] {
        let ordered = EventDebugSnapshot.summaryFieldOrder.compactMap { fieldName -> EventSummaryField? in
            guard let values = fieldCounts[fieldName], !values.isEmpty else {
                return nil
            }
            return EventSummaryField(name: fieldName, values: values)
        }

        let extra = fieldCounts.keys
            .filter { !EventDebugSnapshot.summaryFieldOrder.contains($0) }
            .sorted()
            .map { EventSummaryField(name: $0, values: fieldCounts[$0] ?? [:]) }

        return ordered + extra
    }

    func jsonString() throws -> String {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "kind": "cg-event-summary",
            "tap": tap,
            "samples": samples,
            "totalAbsDelta": [
                "dx": totalAbsDx,
                "dy": totalAbsDy,
            ],
            "fields": fields.map { field in
                [
                    "name": field.name,
                    "stable": field.isStable,
                    "unique": field.values.count,
                    "stableValue": jsonValue(field.stableValue),
                    "values": field.values,
                ] as [String: Any]
            },
        ]

        return try encodeJSONString(object)
    }

    static func load(path: String) throws -> EventSummary {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw CLIError.runtime("could not read summary file \(path): \(error.localizedDescription)")
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CLIError.runtime("could not parse summary file \(path) as JSON: \(error.localizedDescription)")
        }

        guard let object = root as? [String: Any],
              object["kind"] as? String == "cg-event-summary" else {
            throw CLIError.runtime("summary file \(path) is not a cg-event-summary JSON file")
        }

        guard let tap = object["tap"] as? String,
              let samples = intValue(object["samples"]),
              let delta = object["totalAbsDelta"] as? [String: Any],
              let totalAbsDx = intValue(delta["dx"]),
              let totalAbsDy = intValue(delta["dy"]),
              let fieldObjects = object["fields"] as? [[String: Any]] else {
            throw CLIError.runtime("summary file \(path) is missing required fields")
        }

        var fieldCounts: [String: [String: Int]] = [:]
        for fieldObject in fieldObjects {
            guard let name = fieldObject["name"] as? String,
                  let valuesObject = fieldObject["values"] as? [String: Any] else {
                throw CLIError.runtime("summary file \(path) contains an invalid field entry")
            }

            var values: [String: Int] = [:]
            for (value, countObject) in valuesObject {
                guard let count = intValue(countObject) else {
                    throw CLIError.runtime("summary file \(path) contains a non-integer count for field \(name)")
                }
                values[value] = count
            }
            fieldCounts[name] = values
        }

        return EventSummary(
            tap: tap,
            samples: samples,
            totalAbsDx: totalAbsDx,
            totalAbsDy: totalAbsDy,
            fieldCounts: fieldCounts
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }
}

private let attributionCandidateFieldOrder = [
    "subtype",
    "instant",
    "sourcePID",
    "sourceUser",
    "sourceState",
]

private let attributionCandidateFields = Set(attributionCandidateFieldOrder)

private struct SummaryRun {
    let role: String
    let index: Int
    let path: String
    let summary: EventSummary

    var label: String {
        "\(role)[\(index)]"
    }
}

private typealias AttributionCandidate = (name: String, external: String, trackpad: String)

private func compareEventSummaries(
    externalPath: String,
    trackpadPath: String,
    minimumSamples: Int,
    minimumAbsDelta: Int,
    outputJSON: Bool
) throws {
    let external = try EventSummary.load(path: externalPath)
    let trackpad = try EventSummary.load(path: trackpadPath)

    let externalFields = Dictionary(uniqueKeysWithValues: external.fields.map { ($0.name, $0) })
    let trackpadFields = Dictionary(uniqueKeysWithValues: trackpad.fields.map { ($0.name, $0) })
    let sharedFieldNames = EventDebugSnapshot.summaryFieldOrder.filter {
        externalFields[$0] != nil && trackpadFields[$0] != nil
    }

    let qualityBlockers = summaryQualityBlockers(
        external: external,
        trackpad: trackpad,
        minimumSamples: minimumSamples,
        minimumAbsDelta: minimumAbsDelta
    )

    let candidates: [AttributionCandidate] = sharedFieldNames.compactMap { fieldName -> AttributionCandidate? in
        guard attributionCandidateFields.contains(fieldName) else {
            return nil
        }
        guard let externalField = externalFields[fieldName],
              let trackpadField = trackpadFields[fieldName],
              let externalValue = externalField.stableValue,
              let trackpadValue = trackpadField.stableValue,
              externalValue != trackpadValue else {
            return nil
        }
        return (fieldName, externalValue, trackpadValue)
    }

    let unstableShared = sharedFieldNames.filter { fieldName in
        guard let externalField = externalFields[fieldName],
              let trackpadField = trackpadFields[fieldName] else {
            return false
        }
        return !externalField.isStable || !trackpadField.isStable
    }

    let ignoredStableDifferent: [AttributionCandidate] = sharedFieldNames.compactMap { fieldName -> AttributionCandidate? in
        guard !attributionCandidateFields.contains(fieldName),
              let externalField = externalFields[fieldName],
              let trackpadField = trackpadFields[fieldName],
              let externalValue = externalField.stableValue,
              let trackpadValue = trackpadField.stableValue,
              externalValue != trackpadValue else {
            return nil
        }
        return (fieldName, externalValue, trackpadValue)
    }

    let result: String
    let reasons: [String]
    let next: String?
    if !qualityBlockers.isEmpty {
        result = "blocker"
        reasons = qualityBlockers
        next = nil
    } else if candidates.isEmpty {
        result = "blocker"
        reasons = ["no shared CGEvent field is stable within both runs and different between external mouse and trackpad"]
        next = nil
    } else {
        result = "candidate-fields-found"
        reasons = []
        next = "verify the same fields across repeated runs before enabling any real pointer interception"
    }

    if outputJSON {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "kind": "summary-comparison-result",
            "mode": "single-pair",
            "qualityGate": qualityGateObject(minimumSamples: minimumSamples, minimumAbsDelta: minimumAbsDelta),
            "runs": [
                "external": summaryRunObject(role: "external", index: nil, path: externalPath, summary: external),
                "trackpad": summaryRunObject(role: "trackpad", index: nil, path: trackpadPath, summary: trackpad),
            ],
            "stableDifferentFieldCount": candidates.count,
            "stableDifferentFields": attributionCandidateObjects(candidates),
            "unstableSharedFields": unstableShared,
            "ignoredStableDifferentFields": attributionCandidateObjects(ignoredStableDifferent),
            "result": result,
            "reasons": reasons,
            "next": jsonValue(next),
        ]
        printFlush(try encodeJSONString(object))
        return
    }

    print("compare-summaries")
    print("external=\(externalPath) tap=\(external.tap) samples=\(external.samples) total-abs-delta=(\(external.totalAbsDx),\(external.totalAbsDy))")
    print("trackpad=\(trackpadPath) tap=\(trackpad.tap) samples=\(trackpad.samples) total-abs-delta=(\(trackpad.totalAbsDx),\(trackpad.totalAbsDy))")
    print("quality-gate=min-samples:\(minimumSamples) min-abs-delta:\(minimumAbsDelta)")

    if result == "blocker" {
        print("stable-different-fields=0")
        print("result=blocker")
        for reason in reasons {
            print("reason=\(reason)")
        }
    } else {
        print("stable-different-fields=\(candidates.count)")
        for candidate in candidates {
            print("  \(candidate.name): external=\(candidate.external) trackpad=\(candidate.trackpad)")
        }
        print("result=candidate-fields-found")
        if let next {
            print("next=\(next)")
        }
    }

    if !unstableShared.isEmpty {
        print("unstable-shared-fields=\(unstableShared.joined(separator: ","))")
    }

    if !ignoredStableDifferent.isEmpty {
        print("ignored-stable-different-fields=\(candidateListText(ignoredStableDifferent))")
    }
}

private func summaryQualityBlockers(
    external: EventSummary,
    trackpad: EventSummary,
    minimumSamples: Int,
    minimumAbsDelta: Int
) -> [String] {
    var blockers: [String] = []

    if external.tap != trackpad.tap {
        blockers.append("summary taps differ: external=\(external.tap) trackpad=\(trackpad.tap)")
    }
    if external.samples < minimumSamples {
        blockers.append("external samples \(external.samples) below minimum \(minimumSamples)")
    }
    if trackpad.samples < minimumSamples {
        blockers.append("trackpad samples \(trackpad.samples) below minimum \(minimumSamples)")
    }

    let externalDelta = external.totalAbsDx + external.totalAbsDy
    let trackpadDelta = trackpad.totalAbsDx + trackpad.totalAbsDy
    if externalDelta < minimumAbsDelta {
        blockers.append("external total absolute delta \(externalDelta) below minimum \(minimumAbsDelta)")
    }
    if trackpadDelta < minimumAbsDelta {
        blockers.append("trackpad total absolute delta \(trackpadDelta) below minimum \(minimumAbsDelta)")
    }

    return blockers
}

private func compareEventSummarySet(
    externalPaths: [String],
    trackpadPaths: [String],
    minimumSamples: Int,
    minimumAbsDelta: Int,
    outputJSON: Bool
) throws {
    let externalRuns = try externalPaths.enumerated().map { index, path in
        SummaryRun(role: "external", index: index + 1, path: path, summary: try EventSummary.load(path: path))
    }
    let trackpadRuns = try trackpadPaths.enumerated().map { index, path in
        SummaryRun(role: "trackpad", index: index + 1, path: path, summary: try EventSummary.load(path: path))
    }
    let allRuns = externalRuns + trackpadRuns

    let qualityBlockers = summarySetQualityBlockers(
        runs: allRuns,
        minimumSamples: minimumSamples,
        minimumAbsDelta: minimumAbsDelta
    )
    let candidates = repeatedAttributionCandidates(externalRuns: externalRuns, trackpadRuns: trackpadRuns)
    let ignoredStableDifferent = repeatedStableDifferentFields(
        externalRuns: externalRuns,
        trackpadRuns: trackpadRuns,
        fields: EventDebugSnapshot.summaryFieldOrder.filter { !attributionCandidateFields.contains($0) }
    )
    let nonRepeatableCandidateFields = attributionCandidateFieldOrder.filter { fieldName in
        !candidates.contains(where: { $0.name == fieldName })
    }

    let result: String
    let reasons: [String]
    let next: String?
    if !qualityBlockers.isEmpty {
        result = "blocker"
        reasons = qualityBlockers
        next = nil
    } else if candidates.isEmpty {
        result = "blocker"
        reasons = ["no attribution candidate field remained stable across repeated external runs, stable across repeated trackpad runs, and different between device classes"]
        next = nil
    } else {
        result = "repeatable-candidate-fields-found"
        reasons = []
        next = "the CGEvent path has repeatable attribution candidates, but real interception must still prove suppression/reinjection safety before being enabled"
    }

    if outputJSON {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "kind": "summary-set-comparison-result",
            "mode": "repeated-set",
            "qualityGate": qualityGateObject(minimumSamples: minimumSamples, minimumAbsDelta: minimumAbsDelta),
            "runs": allRuns.map { summaryRunObject($0) },
            "repeatableStableDifferentFieldCount": candidates.count,
            "repeatableStableDifferentFields": attributionCandidateObjects(candidates),
            "nonRepeatableCandidateFields": nonRepeatableCandidateFields,
            "ignoredRepeatableStableDifferentFields": attributionCandidateObjects(ignoredStableDifferent),
            "result": result,
            "reasons": reasons,
            "next": jsonValue(next),
        ]
        printFlush(try encodeJSONString(object))
        return
    }

    print("compare-summary-set")
    print("external-count=\(externalRuns.count) trackpad-count=\(trackpadRuns.count)")
    print("quality-gate=min-samples:\(minimumSamples) min-abs-delta:\(minimumAbsDelta)")
    for run in allRuns {
        print("\(run.label)=\(run.path) tap=\(run.summary.tap) samples=\(run.summary.samples) total-abs-delta=(\(run.summary.totalAbsDx),\(run.summary.totalAbsDy))")
    }

    if result == "blocker" {
        print("repeatable-stable-different-fields=0")
        print("result=blocker")
        for reason in reasons {
            print("reason=\(reason)")
        }
    } else {
        print("repeatable-stable-different-fields=\(candidates.count)")
        for candidate in candidates {
            print("  \(candidate.name): external=\(candidate.external) trackpad=\(candidate.trackpad)")
        }
        print("result=repeatable-candidate-fields-found")
        if let next {
            print("next=\(next)")
        }
    }

    if !nonRepeatableCandidateFields.isEmpty {
        print("non-repeatable-candidate-fields=\(nonRepeatableCandidateFields.joined(separator: ","))")
    }
    if !ignoredStableDifferent.isEmpty {
        print("ignored-repeatable-stable-different-fields=\(candidateListText(ignoredStableDifferent))")
    }
}

private func qualityGateObject(minimumSamples: Int, minimumAbsDelta: Int) -> [String: Any] {
    [
        "minimumSamples": minimumSamples,
        "minimumAbsDelta": minimumAbsDelta,
    ]
}

private func summaryRunObject(_ run: SummaryRun) -> [String: Any] {
    summaryRunObject(role: run.role, index: run.index, path: run.path, summary: run.summary)
}

private func summaryRunObject(role: String, index: Int?, path: String, summary: EventSummary) -> [String: Any] {
    var object: [String: Any] = [
        "role": role,
        "path": path,
        "tap": summary.tap,
        "samples": summary.samples,
        "totalAbsDelta": [
            "dx": summary.totalAbsDx,
            "dy": summary.totalAbsDy,
        ],
    ]
    if let index {
        object["index"] = index
    }
    return object
}

private func attributionCandidateObjects(_ candidates: [AttributionCandidate]) -> [[String: Any]] {
    candidates.map { candidate in
        [
            "name": candidate.name,
            "external": candidate.external,
            "trackpad": candidate.trackpad,
        ]
    }
}

private func candidateListText(_ candidates: [AttributionCandidate]) -> String {
    candidates
        .map { "\($0.name)(external=\($0.external),trackpad=\($0.trackpad))" }
        .joined(separator: ",")
}

private func runStage2Gate(
    summarySetPath: String,
    attributionPath: String,
    passThroughPath: String,
    outputJSON: Bool
) throws {
    let summarySet = try loadJSONObject(path: summarySetPath, expectedKind: "summary-set-comparison-result")
    let attribution = try loadJSONObject(path: attributionPath, expectedKind: "attribution-probe-result")
    let passThrough = try loadJSONObject(path: passThroughPath, expectedKind: "pass-through-probe-result")

    var reasons: [String] = []

    if summarySet["result"] as? String != "repeatable-candidate-fields-found" {
        reasons.append("summary-set gate did not report repeatable candidate fields")
        reasons += prefixedReasons(summarySet, prefix: "summary-set")
    }

    let candidates = attributionCandidates(from: summarySet, key: "repeatableStableDifferentFields")
    if candidates.isEmpty {
        reasons.append("summary-set gate did not include any repeatable stable different candidate fields")
    }

    let attributionField = attribution["field"] as? String
    if attribution["result"] as? String != "classified" {
        reasons.append("attribution gate did not report classified")
        reasons += prefixedReasons(attribution, prefix: "attribution")
    }
    if attributionField == nil {
        reasons.append("attribution gate is missing field")
    }

    var selectedCandidate: AttributionCandidate?
    if let attributionField {
        selectedCandidate = candidates.first { $0.name == attributionField }
        if selectedCandidate == nil {
            reasons.append("attribution field \(attributionField) was not present in summary-set candidates")
        }
    }
    if selectedCandidate == nil {
        selectedCandidate = candidates.first
    }

    if let selectedCandidate {
        validateSelectedCandidateForRealRun(candidate: selectedCandidate, reasons: &reasons)
        validateAttributionExpectedValues(
            attribution: attribution,
            candidate: selectedCandidate,
            reasons: &reasons
        )
    }
    validateAttributionClassCounts(attribution: attribution, reasons: &reasons)

    if passThrough["result"] as? String != "pass-through-stable" {
        reasons.append("pass-through gate did not report pass-through-stable")
        reasons += prefixedReasons(passThrough, prefix: "pass-through")
    }
    validatePassThroughCounts(passThrough: passThrough, reasons: &reasons)

    let summaryTap = singleSummaryTap(summarySet, reasons: &reasons)
    let attributionTap = attribution["tap"] as? String
    let passThroughTap = passThrough["tap"] as? String
    validateConsistentTaps(
        summaryTap: summaryTap,
        attributionTap: attributionTap,
        passThroughTap: passThroughTap,
        reasons: &reasons
    )

    let result = reasons.isEmpty ? "ready" : "blocker"
    let next = reasons.isEmpty
        ? "all offline second-stage gates passed; experimental run --real may be tested in the foreground with explicit confirmation and a short sample limit"
        : "resolve blockers, regenerate the JSON inputs, and rerun stage2-gate"
    let candidateObject: Any = selectedCandidate.map {
        [
            "name": $0.name,
            "external": $0.external,
            "trackpad": $0.trackpad,
        ] as [String: Any]
    } ?? NSNull()

    if outputJSON {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "kind": "stage2-gate-result",
            "mode": "offline-json",
            "inputs": [
                "summarySet": summarySetPath,
                "attribution": attributionPath,
                "passThrough": passThroughPath,
            ],
            "tap": jsonValue(summaryTap),
            "candidate": candidateObject,
            "result": result,
            "reasons": reasons,
            "next": next,
        ]
        printFlush(try encodeJSONString(object))
        return
    }

    print("stage2-gate")
    print("mode=offline-json; no HID access, no event tap, no system setting writes")
    print("summary-set=\(summarySetPath)")
    print("attribution=\(attributionPath)")
    print("pass-through=\(passThroughPath)")
    if let summaryTap {
        print("tap=\(summaryTap)")
    }
    if let selectedCandidate {
        print("candidate=\(selectedCandidate.name) external=\(selectedCandidate.external) trackpad=\(selectedCandidate.trackpad)")
    }
    print("result=\(result)")
    for reason in reasons {
        print("reason=\(reason)")
    }
    print("next=\(next)")
}

private func validateSelectedCandidateForRealRun(
    candidate: AttributionCandidate,
    reasons: inout [String]
) {
    if !attributionCandidateFields.contains(candidate.name) {
        reasons.append("selected candidate field \(candidate.name) is not allowed for real run")
    }
    if eventDebugIntegerField(named: candidate.name) == nil {
        reasons.append("selected candidate field \(candidate.name) cannot be read from CGEvent")
    }
    if candidate.external == candidate.trackpad {
        reasons.append("selected candidate external and trackpad values must differ")
    }
    if Int64(candidate.external) == nil || Int64(candidate.trackpad) == nil {
        reasons.append("selected candidate values must be integer CGEvent field values")
    }
}

private func attributionCandidates(from object: [String: Any], key: String) -> [AttributionCandidate] {
    guard let candidateObjects = object[key] as? [[String: Any]] else {
        return []
    }
    return candidateObjects.compactMap { candidateObject in
        guard let name = jsonStringValue(candidateObject["name"]),
              let external = jsonStringValue(candidateObject["external"]),
              let trackpad = jsonStringValue(candidateObject["trackpad"]) else {
            return nil
        }
        return (name, external, trackpad)
    }
}

private func prefixedReasons(_ object: [String: Any], prefix: String) -> [String] {
    if let reasons = object["reasons"] as? [String] {
        return reasons.map { "\(prefix): \($0)" }
    }
    if let reason = jsonStringValue(object["reason"]), reason != "<null>" {
        return ["\(prefix): \(reason)"]
    }
    return []
}

private func validateAttributionExpectedValues(
    attribution: [String: Any],
    candidate: AttributionCandidate,
    reasons: inout [String]
) {
    guard let expectedValues = attribution["expectedValues"] as? [String: Any] else {
        reasons.append("attribution gate is missing expectedValues")
        return
    }

    let expectedExternal = jsonStringValue(expectedValues["external"])
    let expectedTrackpad = jsonStringValue(expectedValues["trackpad"])
    if expectedExternal != candidate.external {
        reasons.append("attribution external value does not match summary-set candidate")
    }
    if expectedTrackpad != candidate.trackpad {
        reasons.append("attribution trackpad value does not match summary-set candidate")
    }
}

private func validateAttributionClassCounts(attribution: [String: Any], reasons: inout [String]) {
    let externalCount = attributionClassCount(attribution, name: "external")
    let trackpadCount = attributionClassCount(attribution, name: "trackpad")
    let unknownCount = attributionClassCount(attribution, name: "unknown")

    if (externalCount ?? 0) <= 0 {
        reasons.append("attribution gate did not observe any external mouse events")
    }
    if (trackpadCount ?? 0) <= 0 {
        reasons.append("attribution gate did not observe any trackpad events")
    }
    if unknownCount != 0 {
        reasons.append("attribution gate observed unknown events")
    }
}

private func attributionClassCount(_ attribution: [String: Any], name: String) -> Int? {
    guard let classes = attribution["classes"] as? [String: Any],
          let classObject = classes[name] as? [String: Any] else {
        return nil
    }
    return jsonIntValue(classObject["count"])
}

private func validatePassThroughCounts(passThrough: [String: Any], reasons: inout [String]) {
    let samples = jsonIntValue(passThrough["samples"])
    let requestedSamples = jsonIntValue(passThrough["requestedSamples"])
    if let samples, let requestedSamples {
        if samples < requestedSamples {
            reasons.append("pass-through gate stopped before collecting requested samples")
        }
    } else {
        reasons.append("pass-through gate is missing sample counts")
    }

    if (jsonIntValue(passThrough["tapDisabledByTimeout"]) ?? 0) != 0 {
        reasons.append("pass-through gate was disabled by timeout")
    }
    if (jsonIntValue(passThrough["tapDisabledByUserInput"]) ?? 0) != 0 {
        reasons.append("pass-through gate was disabled by user input")
    }
}

private func singleSummaryTap(_ summarySet: [String: Any], reasons: inout [String]) -> String? {
    guard let runs = summarySet["runs"] as? [[String: Any]], !runs.isEmpty else {
        reasons.append("summary-set gate is missing run tap data")
        return nil
    }
    let taps = Set(runs.compactMap { $0["tap"] as? String })
    guard taps.count == 1 else {
        reasons.append("summary-set runs do not all use the same tap")
        return nil
    }
    return taps.first
}

private func validateConsistentTaps(
    summaryTap: String?,
    attributionTap: String?,
    passThroughTap: String?,
    reasons: inout [String]
) {
    guard let summaryTap else {
        return
    }
    if attributionTap != summaryTap {
        reasons.append("attribution tap does not match summary-set tap")
    }
    if passThroughTap != summaryTap {
        reasons.append("pass-through tap does not match summary-set tap")
    }
}

private func summarySetQualityBlockers(
    runs: [SummaryRun],
    minimumSamples: Int,
    minimumAbsDelta: Int
) -> [String] {
    var blockers: [String] = []

    let taps = Set(runs.map(\.summary.tap))
    if taps.count > 1 {
        let detail = runs.map { "\($0.label)=\($0.summary.tap)" }.joined(separator: ",")
        blockers.append("summary taps differ across runs: \(detail)")
    }

    let pathCounts = Dictionary(grouping: runs, by: \.path).mapValues(\.count)
    for path in pathCounts.keys.sorted() where (pathCounts[path] ?? 0) > 1 {
        blockers.append("summary file was reused more than once: \(path)")
    }

    for run in runs {
        if run.summary.samples < minimumSamples {
            blockers.append("\(run.label) samples \(run.summary.samples) below minimum \(minimumSamples)")
        }

        let totalDelta = run.summary.totalAbsDx + run.summary.totalAbsDy
        if totalDelta < minimumAbsDelta {
            blockers.append("\(run.label) total absolute delta \(totalDelta) below minimum \(minimumAbsDelta)")
        }
    }

    return blockers
}

private func repeatedAttributionCandidates(
    externalRuns: [SummaryRun],
    trackpadRuns: [SummaryRun]
) -> [(name: String, external: String, trackpad: String)] {
    repeatedStableDifferentFields(
        externalRuns: externalRuns,
        trackpadRuns: trackpadRuns,
        fields: attributionCandidateFieldOrder
    )
}

private func repeatedStableDifferentFields(
    externalRuns: [SummaryRun],
    trackpadRuns: [SummaryRun],
    fields: [String]
) -> [(name: String, external: String, trackpad: String)] {
    fields.compactMap { fieldName in
        guard let externalValue = repeatedStableValue(fieldName: fieldName, runs: externalRuns),
              let trackpadValue = repeatedStableValue(fieldName: fieldName, runs: trackpadRuns),
              externalValue != trackpadValue else {
            return nil
        }
        return (fieldName, externalValue, trackpadValue)
    }
}

private func repeatedStableValue(fieldName: String, runs: [SummaryRun]) -> String? {
    let values = runs.compactMap { run in
        run.summary.fields.first(where: { $0.name == fieldName })?.stableValue
    }
    guard values.count == runs.count,
          let first = values.first,
          values.allSatisfy({ $0 == first }) else {
        return nil
    }
    return first
}

private struct EventDebugSnapshot {
    struct Field {
        let name: String
        let value: String
    }

    static let summaryFieldOrder = [
        "type",
        "eventNo",
        "subtype",
        "button",
        "instant",
        "sourcePID",
        "sourceUser",
        "sourceState",
        "flags",
    ]

    let fields: [Field]
    let locationX: Double
    let locationY: Double

    var description: String {
        let fieldText = fields
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: " ")
        return "\(fieldText) loc=(\(String(format: "%.1f", locationX)),\(String(format: "%.1f", locationY)))"
    }

    func value(named name: String) -> String? {
        fields.first(where: { $0.name == name })?.value
    }
}

private let eventDebugIntegerFields: [(name: String, field: CGEventField)] = [
    ("eventNo", .mouseEventNumber),
    ("subtype", .mouseEventSubtype),
    ("button", .mouseEventButtonNumber),
    ("instant", .mouseEventInstantMouser),
    ("sourcePID", .eventSourceUnixProcessID),
    ("sourceUser", .eventSourceUserData),
    ("sourceState", .eventSourceStateID),
]

private func eventDebugSnapshot(type: CGEventType, event: CGEvent) -> EventDebugSnapshot {
    let location = event.location

    var fields = [EventDebugSnapshot.Field(name: "type", value: String(type.rawValue))]
    fields += eventDebugIntegerFields.map { current in
        EventDebugSnapshot.Field(name: current.name, value: String(event.getIntegerValueField(current.field)))
    }
    fields.append(EventDebugSnapshot.Field(name: "flags", value: String(event.flags.rawValue)))

    return EventDebugSnapshot(fields: fields, locationX: location.x, locationY: location.y)
}

private func eventDebugIntegerField(named name: String) -> CGEventField? {
    eventDebugIntegerFields.first { $0.name == name }?.field
}

private let probeCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let runner = Unmanaged<ProbeRunner>.fromOpaque(refcon).takeUnretainedValue()
    return runner.handle(type: type, event: event)
}

private let attributionProbeCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let runner = Unmanaged<AttributionProbeRunner>.fromOpaque(refcon).takeUnretainedValue()
    return runner.handle(type: type, event: event)
}

private let passThroughProbeCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let runner = Unmanaged<PassThroughProbeRunner>.fromOpaque(refcon).takeUnretainedValue()
    return runner.handle(type: type, event: event)
}

private let realRunCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let runner = Unmanaged<RealRunRunner>.fromOpaque(refcon).takeUnretainedValue()
    return runner.handle(type: type, event: event)
}

private let doctorEventTapCallback: CGEventTapCallBack = { _, _, event, _ in
    Unmanaged.passUnretained(event)
}

private let hidValueCallback: IOHIDValueCallback = { context, _, _, value in
    guard let context else {
        return
    }
    let runner = Unmanaged<HIDRawProbeRunner>.fromOpaque(context).takeUnretainedValue()
    runner.handle(value: value)
}

private let hidOverlayValueCallback: IOHIDValueCallback = { context, _, _, value in
    guard let context else {
        return
    }
    let runner = Unmanaged<HIDOverlayRealRunRunner>.fromOpaque(context).takeUnretainedValue()
    runner.handle(value: value)
}

private let hidOverlayEventCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let runner = Unmanaged<HIDOverlayRealRunRunner>.fromOpaque(refcon).takeUnretainedValue()
    return runner.handle(type: type, event: event)
}

private func printFlush(_ message: String) {
    print(message)
    fflush(stdout)
}
