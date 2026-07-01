#ifndef WinPointerHIDShim_h
#define WinPointerHIDShim_h

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

IOHIDEventSystemClientRef WPHIDCreateEventSystemClient(void);
CFArrayRef WPHIDCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef WPHIDServiceCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
Boolean WPHIDServiceSetProperty(IOHIDServiceClientRef service, CFStringRef key, CFTypeRef property);
CFTypeRef WPHIDServiceGetRegistryID(IOHIDServiceClientRef service);
Boolean WPHIDServiceConformsTo(IOHIDServiceClientRef service, uint32_t usagePage, uint32_t usage);

#endif
