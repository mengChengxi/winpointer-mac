#include "WinPointerHIDShim.h"

IOHIDEventSystemClientRef WPHIDCreateEventSystemClient(void) {
    return IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
}

CFArrayRef WPHIDCopyServices(IOHIDEventSystemClientRef client) {
    return IOHIDEventSystemClientCopyServices(client);
}

CFTypeRef WPHIDServiceCopyProperty(IOHIDServiceClientRef service, CFStringRef key) {
    return IOHIDServiceClientCopyProperty(service, key);
}

Boolean WPHIDServiceSetProperty(IOHIDServiceClientRef service, CFStringRef key, CFTypeRef property) {
    return IOHIDServiceClientSetProperty(service, key, property);
}

CFTypeRef WPHIDServiceGetRegistryID(IOHIDServiceClientRef service) {
    return IOHIDServiceClientGetRegistryID(service);
}

Boolean WPHIDServiceConformsTo(IOHIDServiceClientRef service, uint32_t usagePage, uint32_t usage) {
    return IOHIDServiceClientConformsTo(service, usagePage, usage);
}
