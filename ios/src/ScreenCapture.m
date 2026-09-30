#import "ScreenCapture.h"
#import "PrivateHeaders.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Accelerate/Accelerate.h>
#import <dlfcn.h>

typedef IOSurfaceRef (*CGImageGetIOSurfaceFn)(CGImageRef);

typedef kern_return_t (*RenderDisplayFn)(mach_port_t, CFStringRef, IOSurfaceRef, int, int);
// _UICreateScreenUIImage usa convención "Create" → devuelve +1 retained.
// Tipamos como CFTypeRef para usar __bridge_transfer y evitar leak.
typedef CFTypeRef     (*UICreateImgFn)(void);

typedef enum { BackendNone, BackendCAR, BackendUIPRIV } CaptureBackend;

@implementation ScreenCapture {
    dispatch_source_t _timer;
    dispatch_queue_t  _queue;
    IOSurfaceRef      _surface;
    CVPixelBufferRef  _wrappedPB;
    CFAbsoluteTime    _startTime;
    RenderDisplayFn   _fnRenderDisplay;
    UICreateImgFn     _fnUICreateScreen;
    CVPixelBufferPoolRef _pool;
    BOOL              _busy;
    CaptureBackend    _backend;
    NSUInteger        _consecutiveBlack;

    // Detección de frame estático: 16x16 muestras del canal B + memcmp.
    uint8_t           _lastSamples[256];
    BOOL              _haveLastSamples;
    NSUInteger        _staticFrameStreak;
    BOOL              _inIdleMode;
    NSInteger         _activeFps;       // fps actual aplicado al timer
    NSInteger         _idleFps;         // fps cuando la pantalla no cambia

    double            _intervalCaptureTimeSum;
    NSUInteger        _intervalCaptureCount;
    double            _intervalMaxCaptureTimeMs;
    size_t            _poolW;
    size_t            _poolH;
}

- (double)avgCaptureTimeMs {
    return _intervalCaptureCount > 0 ? (_intervalCaptureTimeSum / _intervalCaptureCount) : 0.0;
}

- (double)maxCaptureTimeMs {
    return _intervalMaxCaptureTimeMs;
}

- (void)resetIntervalTiming {
    _intervalCaptureTimeSum = 0;
    _intervalCaptureCount = 0;
    _intervalMaxCaptureTimeMs = 0;
}

- (instancetype)init {
    if ((self = [super init])) {
        _fps           = 15;
        _idleFps       = 4;
        _activeFps     = (NSInteger)_fps;
        _captureScale  = 0.4;   // por defecto medium

        UIScreen *s = [UIScreen mainScreen];
        _displayScale = s.scale;
        _pointSize    = s.bounds.size;
        [self _recomputeDisplaySize];

        [self _resolveSymbols];
    }
    return self;
}

- (void)_recomputeDisplaySize {
    // captureScale opera sobre la resolución NATIVA en píxeles. Equivalente
    // a multiplicar pointSize × displayScale × captureScale.
    CGFloat factor = MAX(0.1, _captureScale) * _displayScale;
    _displaySize = CGSizeMake(round(_pointSize.width  * factor),
                              round(_pointSize.height * factor));
}

- (void)setFps:(NSInteger)fps {
    _fps = fps;
    _activeFps = fps;
    [self _applyTimerInterval];
}

- (void)setCaptureScale:(CGFloat)captureScale {
    _captureScale = captureScale;
    [self _recomputeDisplaySize];
}

- (void)_resolveSymbols {
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    if (qc) _fnRenderDisplay = dlsym(qc, "CARenderServerRenderDisplay");
    _fnUICreateScreen = dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
}

- (void)dealloc {
    [self stop];
    if (_wrappedPB) CVPixelBufferRelease(_wrappedPB);
    if (_surface)   CFRelease(_surface);
    if (_pool)      CFRelease(_pool);
}

- (NSString *)backendName {
    return _backend == BackendUIPRIV ? @"_UICreateScreenUIImage" : @"CARenderServer";
}

- (BOOL)_alloc {
    if (_surface) return YES;
    size_t w = (size_t)_displaySize.width;
    size_t h = (size_t)_displaySize.height;
    size_t bpe = 4;
    size_t bpr = ((w * bpe) + 63) & ~((size_t)63);
    NSDictionary *props = @{
        (id)kIOSurfaceWidth:           @(w),
        (id)kIOSurfaceHeight:          @(h),
        (id)kIOSurfacePixelFormat:     @((unsigned int)kCVPixelFormatType_32BGRA),
        (id)kIOSurfaceBytesPerElement: @(bpe),
        (id)kIOSurfaceBytesPerRow:     @(bpr),
        (id)kIOSurfaceAllocSize:       @(bpr * h),
    };
    _surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!_surface) {
        _lastError = @"IOSurfaceCreate falló";
        return NO;
    }
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVReturn r = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, _surface,
                                                  (__bridge CFDictionaryRef)attrs, &_wrappedPB);
    if (r != kCVReturnSuccess || !_wrappedPB) {
        _lastError = [NSString stringWithFormat:@"CVPB wrap r=%d", r];
        return NO;
    }
    NSLog(@"[ScreenCapture] surface=%p pb=%p (%zux%zu, %zu bpr)", _surface, _wrappedPB, w, h, bpr);
    return YES;
}

- (BOOL)start {
    if (_timer) return YES;
    if (!_fnRenderDisplay && !_fnUICreateScreen) {
        _lastError = @"sin backend de captura";
        return NO;
    }
    if (_fnRenderDisplay && [self _alloc]) {
        _backend = BackendCAR;
    } else if (_fnUICreateScreen) {
        _backend = BackendUIPRIV;
    } else {
        _lastError = @"falló alloc inicial";
        return NO;
    }
    NSLog(@"[ScreenCapture] backend inicial=%@", self.backendName);

    _startTime = CFAbsoluteTimeGetCurrent();
    _queue = dispatch_get_main_queue();
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    __weak ScreenCapture *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf _tick]; });
    [self _applyTimerInterval];
    dispatch_resume(_timer);
    return YES;
}

- (void)_applyTimerInterval {
    if (!_timer) return;
    NSInteger fps = _inIdleMode ? _idleFps : _activeFps;
    if (fps < 1) fps = 1;
    uint64_t interval = (uint64_t)((1.0 / (double)fps) * NSEC_PER_SEC);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, interval, interval / 4);
}

__attribute__((unused))
static BOOL surface_is_black(IOSurfaceRef s) {
    void *base = IOSurfaceGetBaseAddress(s);
    if (!base) return YES;
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    size_t w   = IOSurfaceGetWidth(s);
    size_t h   = IOSurfaceGetHeight(s);
    if (w < 8 || h < 8) return NO;
    const uint8_t *row = (const uint8_t *)base + (h / 2) * bpr;
    uint32_t acc = 0;
    for (int i = 0; i < 16; i++) {
        const uint8_t *p = row + (w / 16) * i * 4;
        acc |= p[0] | p[1] | p[2];
    }
    return acc == 0;
}

/// Muestrea 16x16 píxeles del frame (BGRA). Si coincide con el anterior,
/// es un frame estático y podemos skipearlo.
__attribute__((unused))
static BOOL bytes_unchanged(const void *base, size_t bpr, size_t w, size_t h,
                            uint8_t lastSamples[256], BOOL *haveLast) {
    if (!base || w < 32 || h < 32) return NO;
    uint8_t cur[256];
    for (int row = 0; row < 16; row++) {
        size_t y = (size_t)row * h / 16 + h / 32;
        const uint8_t *rowPtr = (const uint8_t *)base + y * bpr;
        for (int col = 0; col < 16; col++) {
            size_t x = (size_t)col * w / 16 + w / 32;
            cur[row * 16 + col] = rowPtr[x * 4];   // canal B
        }
    }
    BOOL same = *haveLast && memcmp(cur, lastSamples, 256) == 0;
    memcpy(lastSamples, cur, 256);
    *haveLast = YES;
    return same;
}

/// Decide si gastamos energía emitiendo este frame.
- (BOOL)_shouldEmitFrame:(BOOL)unchanged {
    // Phase 3: Disable static-frame throttling entirely for smooth, continuous mirroring.
    return YES;
}

- (void)stop {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = NULL;
    }
}

- (void)_tick {
    if (_busy) return;
    _busy = YES;
    CFAbsoluteTime tickStart = CFAbsoluteTimeGetCurrent();

    if (_backend == BackendCAR) {
        kern_return_t kr = _fnRenderDisplay(0, CFSTR("LCD"), _surface, 0, 0);
        if (kr != KERN_SUCCESS) {
            kr = _fnRenderDisplay(0, NULL, _surface, 0, 0);
        }
        if (kr == KERN_SUCCESS) {
            _framesCaptured++;
            uint64_t ptsUs = (uint64_t)((CFAbsoluteTimeGetCurrent() - _startTime) * 1e6);
            [self.delegate screenCapture:self didCaptureBuffer:_wrappedPB pts:ptsUs];
        } else {
            _lastError = [NSString stringWithFormat:@"CARenderDisplay kr=%d", kr];
            if (_fnUICreateScreen) {
                NSLog(@"[ScreenCapture] CARenderDisplay failed (kr=%d), falling back to UIPRIV", kr);
                _backend = BackendUIPRIV;
            }
        }
    } else if (_backend == BackendUIPRIV) {
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        UIImage *ui = (__bridge_transfer UIImage *)_fnUICreateScreen();
        CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
        if (ui && ui.CGImage) {
            CGImageRef img = ui.CGImage;
            size_t targetW = (size_t)_displaySize.width;
            size_t targetH = (size_t)_displaySize.height;
            if (!_pool || _poolW != targetW || _poolH != targetH) {
                if (_pool) { CFRelease(_pool); _pool = NULL; }
                _poolW = targetW;
                _poolH = targetH;
                NSDictionary *pa = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (id)kCVPixelBufferWidthKey:           @(targetW),
                    (id)kCVPixelBufferHeightKey:          @(targetH),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                };
                CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                        (__bridge CFDictionaryRef)pa, &_pool);
            }
            CVPixelBufferRef pb = NULL;
            if (_pool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &pb);
            if (pb) {
                CVPixelBufferLockBaseAddress(pb, 0);
                static CGImageGetIOSurfaceFn fnGetSurface = NULL;
                static dispatch_once_t onceToken;
                dispatch_once(&onceToken, ^{
                    fnGetSurface = (CGImageGetIOSurfaceFn)dlsym(RTLD_DEFAULT, "CGImageGetIOSurface");
                });
                IOSurfaceRef surf = fnGetSurface ? fnGetSurface(img) : NULL;
                void *srcData = NULL;
                CFDataRef rawData = NULL;
                size_t srcRowBytes = 0;
                if (surf) {
                    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
                    srcData = IOSurfaceGetBaseAddress(surf);
                    srcRowBytes = IOSurfaceGetBytesPerRow(surf);
                } else {
                    CGDataProviderRef dp = CGImageGetDataProvider(img);
                    rawData = dp ? CGDataProviderCopyData(dp) : NULL;
                    srcData = rawData ? (void *)CFDataGetBytePtr(rawData) : NULL;
                    srcRowBytes = CGImageGetBytesPerRow(img);
                }

                if (srcData) {
                    vImage_Buffer srcBuf = {
                        .data = srcData,
                        .height = (vImagePixelCount)CGImageGetHeight(img),
                        .width = (vImagePixelCount)CGImageGetWidth(img),
                        .rowBytes = srcRowBytes
                    };
                    vImage_Buffer dstBuf = {
                        .data = CVPixelBufferGetBaseAddress(pb),
                        .height = (vImagePixelCount)targetH,
                        .width = (vImagePixelCount)targetW,
                        .rowBytes = CVPixelBufferGetBytesPerRow(pb)
                    };
                    vImageScale_ARGB8888(&srcBuf, &dstBuf, NULL, kvImageDoNotTile);
                }

                if (surf) {
                    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
                } else if (rawData) {
                    CFRelease(rawData);
                }
                CVPixelBufferUnlockBaseAddress(pb, 0);
                CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
                _framesCaptured++;
                uint64_t ptsUs = (uint64_t)((CFAbsoluteTimeGetCurrent() - _startTime) * 1e6);
                [self.delegate screenCapture:self didCaptureBuffer:pb pts:ptsUs];
                CFAbsoluteTime t3 = CFAbsoluteTimeGetCurrent();
                CVPixelBufferRelease(pb);

                static int uiprivCount = 0;
                if (++uiprivCount % 30 == 1) {
                    NSLog(@"[UIPRIV Timing] snap=%.2fms draw=%.2fms enc+tx=%.2fms total=%.2fms",
                          (t1 - t0) * 1000.0, (t2 - t1) * 1000.0, (t3 - t2) * 1000.0, (t3 - t0) * 1000.0);
                }
            }
        } else {
            _lastError = @"UIPRIV nil";
        }
    }

    double elapsedMs = (CFAbsoluteTimeGetCurrent() - tickStart) * 1000.0;
    _intervalCaptureTimeSum += elapsedMs;
    _intervalCaptureCount++;
    if (elapsedMs > _intervalMaxCaptureTimeMs) _intervalMaxCaptureTimeMs = elapsedMs;

    _busy = NO;
}

@end
