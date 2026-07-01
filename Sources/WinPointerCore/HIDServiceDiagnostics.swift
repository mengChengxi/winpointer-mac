import Foundation
import WinPointerHIDShim

public struct HIDServiceInfo: Equatable, Sendable {
    public let registryID: String
    public let productName: String
    public let manufacturer: String
    public let transport: String
    public let vendorID: Int?
    public let productID: Int?
    public let locationID: Int?
    public let primaryUsagePage: Int?
    public let primaryUsage: Int?
    public let conformsToMouse: Bool
    public let conformsToPointer: Bool
    public let isCandidate: Bool
    public let isProtected: Bool
    public let reason: String
    public let accelerationProperties: [HIDServiceProperty]

    public var usageDescription: String {
        guard let primaryUsagePage, let primaryUsage else {
            return "-"
        }
        return String(format: "0x%02X/0x%02X", primaryUsagePage, primaryUsage)
    }
}

public struct HIDServiceProperty: Equatable, Sendable {
    public let key: String
    public let valueDescription: String

    public init(key: String, valueDescription: String) {
        self.key = key
        self.valueDescription = valueDescription
    }
}

public struct HIDWriteRestoreResult: Equatable, Sendable {
    public let registryID: String
    public let key: String
    public let originalValue: String
    public let temporaryValue: String
    public let valueAfterWrite: String
    public let valueAfterRestore: String
}

public enum HIDWriteRestoreError: Error, CustomStringConvertible {
    case serviceNotFound(String)
    case targetIsProtected(String)
    case propertyMissing(String)
    case propertyNotNumeric(String, String)
    case setTemporaryFailed(String)
    case setRestoreFailed(String)
    case restoreVerificationFailed(expected: String, actual: String)

    public var description: String {
        switch self {
        case .serviceNotFound(let registryID):
            return "HID service registry \(registryID) was not found"
        case .targetIsProtected(let registryID):
            return "HID service registry \(registryID) is protected and cannot be used for write tests"
        case .propertyMissing(let key):
            return "property \(key) is not visible on the target service"
        case .propertyNotNumeric(let key, let value):
            return "property \(key) is not numeric; current value is \(value)"
        case .setTemporaryFailed(let key):
            return "failed to set temporary value for \(key)"
        case .setRestoreFailed(let key):
            return "failed to restore original value for \(key)"
        case .restoreVerificationFailed(let expected, let actual):
            return "restore verification failed; expected \(expected), got \(actual)"
        }
    }
}

public enum HIDServiceDiagnostics {
    private static let accelerationKeys = [
        "HIDPointerAcceleration",
        "HIDMouseAcceleration",
        "HIDPointerAccelerationType",
        "HIDPointerAccelerationAlgorithm",
        "HIDPointerAccelerationMinimum",
        "HIDPointerAccelerationMultiplier",
        "HIDPointerReportRate",
        "HIDAccelCurves",
        "HIDAccelCurvesDebug",
        "HIDTrackingAccelCurves",
        "HIDSupportsPointerAcceleration",
        "HIDUseLinearScalingMouseAcceleration",
        "IOHIDSetAcceleration",
        "HIDScrollAcceleration",
        "HIDMouseScrollAcceleration",
        "HIDScrollAccelCurves",
        "HIDScrollAccelCurvesDebug",
    ]

    public static func listServices() -> [HIDServiceInfo] {
        withServices { services in
            services
                .map(serviceInfo)
                .filter { info in
                    info.isCandidate || info.isProtected || DeviceClassifier.isPointingUsage(info.primaryUsagePage, info.primaryUsage)
                }
                .sorted { lhs, rhs in
                    lhs.productName.localizedCaseInsensitiveCompare(rhs.productName) == .orderedAscending
                }
        } ?? []
    }

    public static func writeNumberThenRestore(
        registryID: String,
        key: String,
        temporaryValue: Double
    ) throws -> HIDWriteRestoreResult {
        try withServices { services -> HIDWriteRestoreResult in
            for service in services {
                let info = serviceInfo(service)
                guard info.registryID == registryID else {
                    continue
                }

                if info.isProtected {
                    throw HIDWriteRestoreError.targetIsProtected(registryID)
                }

                guard let original = copyProperty(service, key) else {
                    throw HIDWriteRestoreError.propertyMissing(key)
                }

                guard let originalNumber = original as? NSNumber else {
                    throw HIDWriteRestoreError.propertyNotNumeric(key, describeCFValue(original))
                }

                let temporaryNumber = NSNumber(value: temporaryValue)
                let setTemporaryOK = WPHIDServiceSetProperty(
                    service,
                    (key as NSString) as CFString,
                    temporaryNumber
                )
                guard setTemporaryOK else {
                    throw HIDWriteRestoreError.setTemporaryFailed(key)
                }

                let afterWrite = copyProperty(service, key).map(describeCFValue) ?? "<missing>"

                let setRestoreOK = WPHIDServiceSetProperty(
                    service,
                    (key as NSString) as CFString,
                    originalNumber
                )
                guard setRestoreOK else {
                    throw HIDWriteRestoreError.setRestoreFailed(key)
                }

                let afterRestore = copyProperty(service, key).map(describeCFValue) ?? "<missing>"
                let originalDescription = describeCFValue(originalNumber)
                guard afterRestore == originalDescription else {
                    throw HIDWriteRestoreError.restoreVerificationFailed(
                        expected: originalDescription,
                        actual: afterRestore
                    )
                }

                return HIDWriteRestoreResult(
                    registryID: registryID,
                    key: key,
                    originalValue: originalDescription,
                    temporaryValue: describeCFValue(temporaryNumber),
                    valueAfterWrite: afterWrite,
                    valueAfterRestore: afterRestore
                )
            }

            throw HIDWriteRestoreError.serviceNotFound(registryID)
        } ?? {
            throw HIDWriteRestoreError.serviceNotFound(registryID)
        }()
    }

    private static func withServices<T>(_ body: ([IOHIDServiceClient]) throws -> T) rethrows -> T? {
        guard let unmanagedClient = WPHIDCreateEventSystemClient() else {
            return nil
        }
        let client = unmanagedClient.takeRetainedValue()

        guard let unmanagedServices = WPHIDCopyServices(client) else {
            return nil
        }
        let rawServices = unmanagedServices.takeRetainedValue()
        let services = rawServices as NSArray
        return try body(services.map { $0 as! IOHIDServiceClient })
    }

    private static func serviceInfo(_ service: IOHIDServiceClient) -> HIDServiceInfo {
        let productName = stringProperty(service, "Product") ?? "Unknown Service"
        let manufacturer = stringProperty(service, "Manufacturer") ?? "-"
        let transport = stringProperty(service, "Transport") ?? "-"
        let vendorID = intProperty(service, "VendorID")
        let productID = intProperty(service, "ProductID")
        let locationID = intProperty(service, "LocationID")
        let primaryUsagePage = intProperty(service, "PrimaryUsagePage")
        let primaryUsage = intProperty(service, "PrimaryUsage")
        let conformsToMouse = WPHIDServiceConformsTo(service, 0x01, 0x02)
        let conformsToPointer = WPHIDServiceConformsTo(service, 0x01, 0x01)
        let classification = classifyService(
            productName: productName,
            manufacturer: manufacturer,
            transport: transport,
            usagePage: primaryUsagePage,
            usage: primaryUsage,
            conformsToMouse: conformsToMouse
        )

        let registryID = registryID(service)
        let properties = accelerationKeys.compactMap { key -> HIDServiceProperty? in
            guard let value = copyProperty(service, key) else {
                return nil
            }
            return HIDServiceProperty(key: key, valueDescription: describeCFValue(value))
        }

        return HIDServiceInfo(
            registryID: registryID,
            productName: productName,
            manufacturer: manufacturer,
            transport: transport,
            vendorID: vendorID,
            productID: productID,
            locationID: locationID,
            primaryUsagePage: primaryUsagePage,
            primaryUsage: primaryUsage,
            conformsToMouse: conformsToMouse,
            conformsToPointer: conformsToPointer,
            isCandidate: classification.isCandidate,
            isProtected: classification.isProtected,
            reason: classification.reason,
            accelerationProperties: properties
        )
    }

    private static func registryID(_ service: IOHIDServiceClient) -> String {
        guard let unmanagedValue = WPHIDServiceGetRegistryID(service) else {
            return "-"
        }
        let value = unmanagedValue.takeUnretainedValue()
        return describeCFValue(value)
    }

    private static func stringProperty(_ service: IOHIDServiceClient, _ key: String) -> String? {
        copyProperty(service, key) as? String
    }

    private static func intProperty(_ service: IOHIDServiceClient, _ key: String) -> Int? {
        if let number = copyProperty(service, key) as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func copyProperty(_ service: IOHIDServiceClient, _ key: String) -> CFTypeRef? {
        WPHIDServiceCopyProperty(service, (key as NSString) as CFString)?.takeRetainedValue()
    }

    private static func describeCFValue(_ value: CFTypeRef) -> String {
        if let number = value as? NSNumber {
            return number.stringValue
        }

        if let string = value as? String {
            return string
        }

        if let data = value as? Data {
            return "Data(\(data.count) bytes)"
        }

        if let array = value as? [Any] {
            return "Array(\(array.count) items)"
        }

        if let dictionary = value as? [AnyHashable: Any] {
            let keys = dictionary.keys.map { "\($0)" }.sorted().joined(separator: ",")
            return "Dictionary(\(dictionary.count) keys: \(keys))"
        }

        return String(describing: value)
    }

    private static func classifyService(
        productName: String,
        manufacturer: String,
        transport: String,
        usagePage: Int?,
        usage: Int?,
        conformsToMouse: Bool
    ) -> DeviceClassifier.Result {
        let text = [productName, manufacturer, transport]
            .joined(separator: " ")
            .lowercased()

        if text.contains("trackpad")
            || text.contains("multi-touch")
            || text.contains("multitouch")
            || text.contains("touchpad")
            || text.contains("apple internal keyboard")
            || (text.contains("apple") && text.contains("internal")) {
            return DeviceClassifier.Result(isCandidate: false, isProtected: true, reason: "protected trackpad")
        }

        if conformsToMouse && !text.contains("internal") {
            return DeviceClassifier.Result(isCandidate: true, isProtected: false, reason: "external HID mouse service candidate")
        }

        return DeviceClassifier.classify(
            productName: productName,
            manufacturer: manufacturer,
            transport: transport,
            usagePage: usagePage,
            usage: usage
        )
    }
}
