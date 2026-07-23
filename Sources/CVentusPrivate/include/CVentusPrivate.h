#ifndef CVENTUS_PRIVATE_H
#define CVENTUS_PRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - IOHIDEventSystem (private but stable)

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);

CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
void IOHIDEventSystemClientScheduleWithRunLoop(
    IOHIDEventSystemClientRef client,
    CFRunLoopRef runLoop,
    CFStringRef mode
);
void IOHIDEventSystemClientUnscheduleFromRunLoop(
    IOHIDEventSystemClientRef client,
    CFRunLoopRef runLoop,
    CFStringRef mode
);

typedef void (*IOHIDServiceClientEventCallback)(
    void *target,
    void *refcon,
    void *sender,
    IOHIDEventRef event
);

void IOHIDServiceClientRegisterEventCallback(
    IOHIDServiceClientRef service,
    IOHIDServiceClientEventCallback callback,
    void *target,
    void *refcon
);

struct __IOHIDEvent {
    uint32_t type;
    uint64_t timestamp;
    uint32_t senderID;
    int32_t latency;
    float quality;
    uint8_t reserved[4];
    // followed by field data
};
typedef struct __IOHIDEvent *IOHIDEventRef;

IOHIDEventRef IOHIDServiceClientCopyEvent(
    IOHIDServiceClientRef service,
    int32_t eventType,
    IOHIDEventRef event,
    IOOptionBits options
);

CFStringRef IOHIDServiceClientCopyProperty(
    IOHIDServiceClientRef service,
    CFStringRef property
);

// Event field indices
#define kIOHIDEventTypeTemperature 15
#define kIOHIDEventFieldTemperatureLevel (15 << 16 | 0)

// MARK: - IOReport (private but stable energy model)

typedef struct __IOReportSubscription *IOReportSubscriptionRef;

IOReportSubscriptionRef IOReportCreateSubscription(
    void *a,
    CFMutableDictionaryRef channels,
    CFMutableDictionaryRef *out,
    uint64_t desiredChannels
);

int IOReportIterate(
    IOReportSubscriptionRef subscription,
    int(^block)(IOReportSampleRef ch)
);

uint64_t IOReportChannelGetChannelID(IOReportSampleRef ch);
uint64_t IOReportChannelGetFormat(IOReportSampleRef ch);
uint64_t IOReportArrayGetValueAtIndex(IOReportSampleRef ch, size_t index);
CFStringRef IOReportChannelGetChannelName(IOReportSampleRef ch);
CFStringRef IOReportChannelGetGroup(IOReportSampleRef ch);
CFStringRef IOReportChannelGetSubGroup(IOReportSampleRef ch);
CFStringRef IOReportChannelGetUnit(IOReportSampleRef ch);

CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group);

int IOReportGetDimensionality(uint64_t format);

void IOReportRelease(IOReportSubscriptionRef subscription);

// Thermal state notification
extern CFStringRef kIOPMThermalLevelNotification;

#ifdef __cplusplus
}
#endif

#endif // CVENTUS_PRIVATE_H
