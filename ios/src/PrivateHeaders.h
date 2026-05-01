#ifndef SMIR_PRIVATE_HEADERS_H
#define SMIR_PRIVATE_HEADERS_H

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef double IOHIDFloat;
typedef UInt32 IOOptionBits;

// ---- CARenderServer (QuartzCore privado) ---------------------------------
// Renderiza la pantalla principal (o una pantalla nombrada) en un IOSurface.
// Disponible desde iOS 5; signature estable hasta iOS 17+.
extern kern_return_t CARenderServerRenderDisplay(
    mach_port_t server_port,
    CFStringRef display_name,
    IOSurfaceRef surface,
    int x,
    int y
);

// Variante moderna (iOS 11+) — no la usamos directamente pero la dejamos por si
// CARenderServerRenderDisplay falla en futuras versiones.
extern kern_return_t CARenderServerRenderDisplayWithOptions(
    mach_port_t server_port,
    CFStringRef display_name,
    IOSurfaceRef surface,
    CFDictionaryRef options
);

// ---- IOMobileFramebuffer (fallback) --------------------------------------
typedef CFTypeRef IOMobileFramebufferRef;
extern kern_return_t IOMobileFramebufferGetMainDisplay(IOMobileFramebufferRef *fb);
extern kern_return_t IOMobileFramebufferGetDisplaySize(IOMobileFramebufferRef fb, CGSize *size);
extern kern_return_t IOMobileFramebufferCopyLayer(IOMobileFramebufferRef fb, IOSurfaceRef *surface, int layer);

// ---- IOHIDEventSystemClient (inyección de toques y teclas) ---------------
typedef struct __IOHIDEvent       *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    uint32_t transducerType,
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,
    uint32_t buttonMask,
    IOHIDFloat x,
    IOHIDFloat y,
    IOHIDFloat z,
    IOHIDFloat tipPressure,
    IOHIDFloat barrelPressure,
    Boolean range,
    Boolean touch,
    IOOptionBits options
);

extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,
    IOHIDFloat x,
    IOHIDFloat y,
    IOHIDFloat z,
    IOHIDFloat tipPressure,
    IOHIDFloat twist,
    Boolean range,
    Boolean touch,
    IOOptionBits options
);

extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    uint32_t usagePage,
    uint32_t usage,
    Boolean down,
    IOOptionBits options
);

extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, IOOptionBits options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int value);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t sender);

#define kIOHIDDigitizerEventRange       0x00000001
#define kIOHIDDigitizerEventTouch       0x00000002
#define kIOHIDDigitizerEventPosition    0x00000004
#define kIOHIDDigitizerEventIdentity    0x00000020
#define kIOHIDDigitizerTransducerTypeFinger 2

#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0x000B0019

#ifdef __cplusplus
}
#endif

#endif
