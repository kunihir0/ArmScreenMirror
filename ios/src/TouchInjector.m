#import "TouchInjector.h"
#import "PrivateHeaders.h"
#import "Protocol.h"
#import <mach/mach_time.h>
#import <dlfcn.h>

typedef IOHIDEventSystemClientRef (*HIDClientCreateFn)(CFAllocatorRef);
typedef void (*HIDClientDispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*HIDFingerEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                          IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                          Boolean, Boolean, IOOptionBits);
typedef IOHIDEventRef (*HIDDigitizerEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                             uint32_t, uint32_t,
                                             IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                             IOHIDFloat, IOHIDFloat,
                                             Boolean, Boolean, IOOptionBits);
typedef IOHIDEventRef (*HIDKeyboardEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, IOOptionBits);
typedef void (*HIDAppendFn)(IOHIDEventRef, IOHIDEventRef, IOOptionBits);
typedef void (*HIDSetIntFn)(IOHIDEventRef, uint32_t, int);
typedef void (*HIDSetSenderFn)(IOHIDEventRef, uint64_t);

@implementation TouchInjector {
    IOHIDEventSystemClientRef _client;
    HIDClientDispatchFn   _fnDispatch;
    HIDFingerEventFn      _fnFinger;
    HIDDigitizerEventFn   _fnDigitizer;
    HIDKeyboardEventFn    _fnKeyboard;
    HIDAppendFn           _fnAppend;
    HIDSetIntFn           _fnSetInt;
    HIDSetSenderFn        _fnSetSender;

    // Estado por dedo para evitar repetir down/up.
    BOOL _fingerDown[10];
}

- (instancetype)initWithPointSize:(CGSize)size {
    if ((self = [super init])) {
        _pointSize = size;

        const char *paths[] = {
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            "/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
            NULL
        };
        void *h = NULL;
        for (int i = 0; paths[i] && !h; i++) h = dlopen(paths[i], RTLD_NOW);

        HIDClientCreateFn create = h ? dlsym(h, "IOHIDEventSystemClientCreate") : NULL;
        if (!create) create = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        _fnDispatch  = (h ? dlsym(h, "IOHIDEventSystemClientDispatchEvent") : NULL)
                         ?: dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        _fnFinger    = (h ? dlsym(h, "IOHIDEventCreateDigitizerFingerEvent") : NULL)
                         ?: dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        _fnDigitizer = (h ? dlsym(h, "IOHIDEventCreateDigitizerEvent") : NULL)
                         ?: dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        _fnKeyboard  = (h ? dlsym(h, "IOHIDEventCreateKeyboardEvent") : NULL)
                         ?: dlsym(RTLD_DEFAULT, "IOHIDEventCreateKeyboardEvent");
        _fnAppend    = (h ? dlsym(h, "IOHIDEventAppendEvent") : NULL)
                         ?: dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        _fnSetInt    = (h ? dlsym(h, "IOHIDEventSetIntegerValue") : NULL)
                         ?: dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        _fnSetSender = (h ? dlsym(h, "IOHIDEventSetSenderID") : NULL)
                         ?: dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");

        if (create) _client = create(kCFAllocatorDefault);
        NSLog(@"[TouchInjector] client=%p disp=%p finger=%p dig=%p kbd=%p app=%p setInt=%p setSender=%p",
              _client, _fnDispatch, _fnFinger, _fnDigitizer, _fnKeyboard, _fnAppend, _fnSetInt, _fnSetSender);
    }
    return self;
}

- (void)dealloc {
    if (_client) CFRelease(_client);
}

static inline IOHIDFloat CLAMP01(IOHIDFloat v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

// phase: 0=down, 1=move, 2=up
- (void)_dispatchTouch:(uint8_t)fid pos:(CGPoint)p phase:(int)phase {
    if (!_client || !_fnFinger || !_fnDigitizer || !_fnDispatch || !_fnAppend) return;
    if (fid >= 10) fid = 0;

    BOOL down = (phase != 2);
    BOOL transition = (phase == 0) || (phase == 2);

    // Filtrar duplicados que pueden romper el estado del IOHID.
    if (phase == 0 && _fingerDown[fid]) phase = 1;
    if (phase == 2 && !_fingerDown[fid]) return;

    uint32_t mask = kIOHIDDigitizerEventPosition;
    if (transition) mask |= kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;

    IOHIDFloat x = CLAMP01(p.x), y = CLAMP01(p.y);
    uint64_t now = mach_absolute_time();

    // Padre: digitizer "Hand" (transducer tipo 3) — convención Veency/Activator
    // que produce eventos que sí se entregan a la UI desde SpringBoard.
    IOHIDEventRef parent = _fnDigitizer(NULL, now,
        3,                     // kIOHIDDigitizerTransducerTypeHand
        0, 0,
        mask, 0,
        x, y, 0, 0, 0,
        down, down, 0);
    if (!parent) return;

    if (_fnSetInt) _fnSetInt(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    if (_fnSetSender) _fnSetSender(parent, 0x8000000817319372ULL);

    // Hijo: dedo individual.
    IOHIDEventRef child = _fnFinger(NULL, now,
        (uint32_t)(fid + 1),
        (uint32_t)(fid + 2),
        mask,
        x, y, 0, 0, 0,
        down, down, 0);
    if (child) {
        if (_fnSetInt) _fnSetInt(child, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        if (_fnSetSender) _fnSetSender(child, 0x8000000817319372ULL);
        _fnAppend(parent, child, 0);
        CFRelease(child);
    }

    _fnDispatch(_client, parent);
    CFRelease(parent);

    if (phase == 0) _fingerDown[fid] = YES;
    else if (phase == 2) _fingerDown[fid] = NO;
}

- (void)touchDownFinger:(uint8_t)fid atNorm:(CGPoint)p { [self _dispatchTouch:fid pos:p phase:0]; }
- (void)touchMoveFinger:(uint8_t)fid atNorm:(CGPoint)p { [self _dispatchTouch:fid pos:p phase:1]; }
- (void)touchUpFinger:(uint8_t)fid atNorm:(CGPoint)p   { [self _dispatchTouch:fid pos:p phase:2]; }

- (void)performSwipeFromNorm:(CGPoint)from
                      toNorm:(CGPoint)to
                  durationMs:(uint32_t)durationMs
{
    if (durationMs < 50)   durationMs = 50;
    if (durationMs > 5000) durationMs = 5000;

    // System edge gestures (Control Center on home-button iPhones starts
    // from y≈1.0 going up; Notification Center starts from y≈0 going down)
    // need an initial dwell at the start position so SpringBoard's
    // edge-gesture recognizer has time to qualify the touch as an edge swipe
    // before motion begins. Real fingers always pause briefly. Without this
    // the gesture is misread as a regular tap-and-drag and Control Center
    // never opens.
    BOOL bottomEdge = (from.y >= 0.96 && to.y < from.y - 0.10);
    BOOL topEdge    = (from.y <= 0.04 && to.y > from.y + 0.10);
    BOOL isEdgeSwipe = bottomEdge || topEdge;
    NSTimeInterval startDwell = isEdgeSwipe ? 0.080 : 0.0;
    NSTimeInterval endDwell   = isEdgeSwipe ? 0.120 : 0.004;
    BOOL useLinearEasing = isEdgeSwipe;  // edge gesture recognizers expect steady motion

    static const NSTimeInterval kRateHz = 120.0;
    NSInteger steps = MAX(2, (NSInteger)((durationMs / 1000.0) * kRateHz));
    NSTimeInterval interval = (durationMs / 1000.0) / (NSTimeInterval)steps;

    __block CGPoint cFrom = from;
    __block CGPoint cTo   = to;
    __block NSInteger i = 0;
    __weak TouchInjector *weakSelf = self;

    [self touchDownFinger:0 atNorm:cFrom];

    dispatch_queue_t q = dispatch_get_main_queue();

    void (^startMotion)(void) = ^{
        TouchInjector *strong = weakSelf;
        if (!strong) return;
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        uint64_t ns = (uint64_t)(interval * NSEC_PER_SEC);
        dispatch_source_set_timer(src,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)ns),
                                  ns,
                                  ns / 4);
        dispatch_source_set_event_handler(src, ^{
            TouchInjector *s = weakSelf;
            if (!s) { dispatch_source_cancel(src); return; }
            i++;
            if (i >= steps) {
                [s touchMoveFinger:0 atNorm:cTo];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(endDwell * NSEC_PER_SEC)), q, ^{
                    [s touchUpFinger:0 atNorm:cTo];
                });
                dispatch_source_cancel(src);
                return;
            }
            CGFloat t = (CGFloat)i / (CGFloat)steps;
            // Linear for edge gestures (steady, predictable motion); easeOutQuad
            // for normal swipes (snaps to a momentum scroll).
            CGFloat e = useLinearEasing ? t : (1.0 - (1.0 - t) * (1.0 - t));
            CGPoint p = CGPointMake(cFrom.x + (cTo.x - cFrom.x) * e,
                                    cFrom.y + (cTo.y - cFrom.y) * e);
            [s touchMoveFinger:0 atNorm:p];
        });
        dispatch_resume(src);
    };

    if (startDwell > 0) {
        // Hold the start position so iOS qualifies the touch as an edge gesture.
        // Re-emit the start position a couple of times to keep the touch alive
        // on the digitizer during the dwell.
        NSInteger holdFrames = (NSInteger)(startDwell * 60);  // 60 Hz hold pulses
        for (NSInteger k = 1; k < holdFrames; k++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((startDwell * k / holdFrames) * NSEC_PER_SEC)), q, ^{
                TouchInjector *s = weakSelf;
                [s touchMoveFinger:0 atNorm:cFrom];
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(startDwell * NSEC_PER_SEC)), q, startMotion);
    } else {
        startMotion();
    }
}

- (void)_sendKey:(uint16_t)usage page:(uint16_t)page down:(BOOL)d {
    if (!_client || !_fnKeyboard || !_fnDispatch) return;
    IOHIDEventRef e = _fnKeyboard(NULL, mach_absolute_time(), page, usage, d, 0);
    if (!e) return;
    if (_fnSetSender) _fnSetSender(e, 0x8000000817319372ULL);
    _fnDispatch(_client, e);
    CFRelease(e);
}

- (void)keyDown:(uint16_t)hidUsage { [self _sendKey:hidUsage page:0x07 down:YES]; }
- (void)keyUp:(uint16_t)hidUsage   { [self _sendKey:hidUsage page:0x07 down:NO];  }

- (void)typeText:(NSString *)s {
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        uint16_t usage = 0;
        BOOL shift = NO;
        if (c >= 'a' && c <= 'z') usage = 0x04 + (c - 'a');
        else if (c >= 'A' && c <= 'Z') { usage = 0x04 + (c - 'A'); shift = YES; }
        else if (c >= '1' && c <= '9') usage = 0x1e + (c - '1');
        else if (c == '0') usage = 0x27;
        else if (c == ' ') usage = 0x2c;
        else if (c == '\n' || c == '\r') usage = 0x28;
        else if (c == '\t') usage = 0x2b;
        else if (c == 0x7f || c == 0x08) usage = 0x2a;
        if (!usage) continue;
        if (shift) [self _sendKey:0xE1 page:0x07 down:YES];
        [self _sendKey:usage page:0x07 down:YES];
        [self _sendKey:usage page:0x07 down:NO];
        if (shift) [self _sendKey:0xE1 page:0x07 down:NO];
    }
}

- (void)pressButton:(uint8_t)buttonId down:(BOOL)down {
    uint16_t usage = 0, page = 0x0C;
    switch (buttonId) {
        case SMIR_BTN_HOME:     usage = 0x40;  break;  // Menu
        case SMIR_BTN_LOCK:     usage = 0x30;  break;  // Power
        case SMIR_BTN_VOL_UP:   usage = 0xE9;  break;
        case SMIR_BTN_VOL_DOWN: usage = 0xEA;  break;
        case SMIR_BTN_MUTE:     usage = 0xE2;  break;
        case SMIR_BTN_SIRI:     usage = 0x221; break;  // AC Search
        default: return;
    }
    [self _sendKey:usage page:page down:down];
}

@end
