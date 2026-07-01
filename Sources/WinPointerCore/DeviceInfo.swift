import Foundation
import IOKit.hid

public struct DeviceInfo: Equatable, Sendable {
    public let id: String
    public let productName: String
    public let manufacturer: String
    public let transport: String
    public let vendorID: Int?
    public let productID: Int?
    public let locationID: Int?
    public let primaryUsagePage: Int?
    public let primaryUsage: Int?
    public let isCandidate: Bool
    public let isProtected: Bool
    public let reason: String

    public var usageDescription: String {
        guard let primaryUsagePage, let primaryUsage else {
            return "-"
        }
        return String(format: "0x%02X/0x%02X", primaryUsagePage, primaryUsage)
    }
}

public enum DeviceClassifier {
    public struct Result: Equatable, Sendable {
        public let isCandidate: Bool
        public let isProtected: Bool
        public let reason: String
    }

    public static func classify(
        productName: String,
        manufacturer: String,
        transport: String,
        usagePage: Int?,
        usage: Int?
    ) -> Result {
        if let protectionReason = protectedReason(
            productName: productName,
            manufacturer: manufacturer,
            transport: transport,
            usagePage: usagePage,
            usage: usage
        ) {
            return Result(isCandidate: false, isProtected: true, reason: protectionReason)
        }

        let isCandidate = isExternalMouse(
            productName: productName,
            manufacturer: manufacturer,
            transport: transport,
            usagePage: usagePage,
            usage: usage
        )

        return Result(
            isCandidate: isCandidate,
            isProtected: false,
            reason: isCandidate ? "external HID mouse candidate" : "not selected"
        )
    }

    public static func isPointingUsage(_ usagePage: Int?, _ usage: Int?) -> Bool {
        guard let usagePage, let usage else {
            return false
        }

        if usagePage == 0x01, usage == 0x01 || usage == 0x02 {
            return true
        }

        return usagePage == 0x0D
    }

    private static func protectedReason(
        productName: String,
        manufacturer: String,
        transport: String,
        usagePage: Int?,
        usage: Int?
    ) -> String? {
        let text = [productName, manufacturer, transport]
            .joined(separator: " ")
            .lowercased()

        if usagePage == 0x0D {
            return "protected digitizer or touch device"
        }

        let protectedKeywords = [
            "trackpad",
            "multi-touch",
            "multitouch",
            "touchpad",
            "digitizer",
            "tablet",
            "touch screen",
            "touchscreen",
            "apple internal keyboard",
        ]

        if let keyword = protectedKeywords.first(where: { text.contains($0) }) {
            return "protected \(keyword)"
        }

        if text.contains("apple") && text.contains("internal") {
            return "protected Apple internal device"
        }

        if usagePage == 0x01, usage == 0x02, text.contains("magic trackpad") {
            return "protected Magic Trackpad"
        }

        return nil
    }

    private static func isExternalMouse(
        productName: String,
        manufacturer: String,
        transport: String,
        usagePage: Int?,
        usage: Int?
    ) -> Bool {
        guard usagePage == 0x01, usage == 0x02 else {
            return false
        }

        let text = [productName, manufacturer, transport]
            .joined(separator: " ")
            .lowercased()

        return !text.contains("internal")
    }
}

public enum DeviceEnumerator {
    public static func listDevices() -> [DeviceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        guard let rawDevices = IOHIDManagerCopyDevices(manager) else {
            return []
        }

        let devices = rawDevices as NSSet
        return devices.allObjects
            .compactMap { $0 as! IOHIDDevice? }
            .map(deviceInfo)
            .filter { info in
                info.isCandidate || info.isProtected || DeviceClassifier.isPointingUsage(info.primaryUsagePage, info.primaryUsage)
            }
            .sorted { lhs, rhs in
                lhs.productName.localizedCaseInsensitiveCompare(rhs.productName) == .orderedAscending
            }
    }

    private static func deviceInfo(_ device: IOHIDDevice) -> DeviceInfo {
        let productName = stringProperty(device, kIOHIDProductKey) ?? "Unknown Device"
        let manufacturer = stringProperty(device, kIOHIDManufacturerKey) ?? "-"
        let transport = stringProperty(device, kIOHIDTransportKey) ?? "-"
        let vendorID = intProperty(device, kIOHIDVendorIDKey)
        let productID = intProperty(device, kIOHIDProductIDKey)
        let locationID = intProperty(device, kIOHIDLocationIDKey)
        let usagePage = intProperty(device, kIOHIDPrimaryUsagePageKey)
        let usage = intProperty(device, kIOHIDPrimaryUsageKey)
        let vendorPart = vendorID.map(String.init) ?? "unknown"
        let productPart = productID.map(String.init) ?? "unknown"
        let locationPart = locationID.map(String.init) ?? "unknown"
        let id = "\(vendorPart):\(productPart):\(locationPart)"

        let classification = DeviceClassifier.classify(
            productName: productName,
            manufacturer: manufacturer,
            transport: transport,
            usagePage: usagePage,
            usage: usage
        )

        return DeviceInfo(
            id: id,
            productName: productName,
            manufacturer: manufacturer,
            transport: transport,
            vendorID: vendorID,
            productID: productID,
            locationID: locationID,
            primaryUsagePage: usagePage,
            primaryUsage: usage,
            isCandidate: classification.isCandidate,
            isProtected: classification.isProtected,
            reason: classification.reason
        )
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, (key as NSString) as CFString) as? String
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        if let number = IOHIDDeviceGetProperty(device, (key as NSString) as CFString) as? NSNumber {
            return number.intValue
        }
        return nil
    }
}
