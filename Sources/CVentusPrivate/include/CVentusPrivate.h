#ifndef CVENTUS_PRIVATE_H
#define CVENTUS_PRIVATE_H

// Private-but-stable Apple interfaces used for Apple Silicon telemetry.
// Same surface used by Stats, macmon, and smcFanControl derivatives.
// All types are opaque; never define their layouts.

#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - IOHIDEventSystem (temperature sensors)

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type,
                                          int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kVentusHIDEventTypeTemperature 15
#define kVentusHIDFieldTemperatureLevel (15 << 16)
#define kVentusHIDUsagePageAppleVendor 0xff00
#define kVentusHIDUsageAppleVendorTemperatureSensor 5

// MARK: - IOReport (package power / energy model)

typedef CFDictionaryRef IOReportSampleRef;
typedef struct __IOReportSubscription *IOReportSubscriptionRef;

CF_RETURNS_RETAINED
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup,
                                                   uint64_t a, uint64_t b, uint64_t c);
IOReportSubscriptionRef IOReportCreateSubscription(void *allocator, CFMutableDictionaryRef channels,
                                                   CFMutableDictionaryRef *subbedChannels,
                                                   uint64_t channelId, CFTypeRef b);
CF_RETURNS_RETAINED
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef subscription,
                                      CFMutableDictionaryRef channels, CFTypeRef a);
CF_RETURNS_RETAINED
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef current, CFTypeRef a);
int IOReportIterate(CFDictionaryRef samples, int (^block)(IOReportSampleRef ch));
CFStringRef IOReportChannelGetChannelName(IOReportSampleRef ch);
CFStringRef IOReportChannelGetGroup(IOReportSampleRef ch);
CFStringRef IOReportChannelGetUnitLabel(IOReportSampleRef ch);
int64_t IOReportSimpleGetIntegerValue(IOReportSampleRef ch, int32_t idx);

#ifdef __cplusplus
}
#endif

#endif // CVENTUS_PRIVATE_H
