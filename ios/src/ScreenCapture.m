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
    CGSize            _nativeDisplaySize;
    CGSize            _displaySize;
    IOSurfaceRef      _surface;
    CFAbsoluteTime    _startTime;
    RenderDisplayFn   _fnRenderDisplay;
    UICreateImgFn     _fnUICreateScreen;
    CVPixelBufferPoolRef _pool;
    BOOL              _busy;
    CaptureBackend    _backend;
    NSUInteger        _consecutiveBlack;
    NSUInteger        _carFailCount;
    NSUInteger        _carProbeCounter;
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
    double            _carTimeSum;
    NSUInteger        _carTimeCount;
    double            _carMaxMs;
    double            _scaleTimeSum;
    NSUInteger        _scaleTimeCount;
    double            _scaleMaxMs;
    size_t            _poolW;
    size_t            _poolH;
}

@synthesize displaySize = _displaySize;
@synthesize nativeDisplaySize = _nativeDisplaySize;
@synthesize displayScale = _displayScale;
@synthesize pointSize = _pointSize;

- (double)avgCaptureTimeMs {
    return _intervalCaptureCount > 0 ? (_intervalCaptureTimeSum / _intervalCaptureCount) : 0.0;
}

- (double)maxCaptureTimeMs {
    return _intervalMaxCaptureTimeMs;
}

- (double)carAvgMs {
    return _carTimeCount > 0 ? (_carTimeSum / _carTimeCount) : 0.0;
}

- (double)carMaxMs {
    return _carMaxMs;
}

- (double)scaleAvgMs {
    return _scaleTimeCount > 0 ? (_scaleTimeSum / _scaleTimeCount) : 0.0;
}

- (double)scaleMaxMs {
    return _scaleMaxMs;
}

- (void)resetIntervalTiming {
    _intervalCaptureTimeSum = 0;
    _intervalCaptureCount = 0;
    _intervalMaxCaptureTimeMs = 0;
    _carTimeSum = 0;
    _carTimeCount = 0;
    _carMaxMs = 0;
    _scaleTimeSum = 0;
    _scaleTimeCount = 0;
    _scaleMaxMs = 0;
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
    _nativeDisplaySize = CGSizeMake(round(_pointSize.width * _displayScale),
                                    round(_pointSize.height * _displayScale));
    CGFloat factor = MAX(0.1, _captureScale) * _displayScale;
    size_t w = ((size_t)round(_pointSize.width  * factor)) & ~((size_t)1);
    size_t h = ((size_t)round(_pointSize.height * factor)) & ~((size_t)1);
    _displaySize = CGSizeMake(w, h);
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
    if (_surface) CFRelease(_surface);
    if (_pool)    CFRelease(_pool);
}

- (NSString *)backendName {
    return _backend == BackendUIPRIV ? @"_UICreateScreenUIImage" : @"CARenderServer";
}

- (BOOL)_alloc {
    if (_surface) return YES;
    size_t w = (size_t)_nativeDisplaySize.width;
    size_t h = (size_t)_nativeDisplaySize.height;
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
    NSLog(@"[ScreenCapture] native surface=%p (%zux%zu, %zu bpr) -> stream target=%.0fx%.0f",
          _surface, w, h, bpr, _displaySize.width, _displaySize.height);
    return YES;
}

- (CVPixelBufferRef)_scaleSourceBuffer:(const vImage_Buffer *)srcBuf {
    if (!srcBuf || !srcBuf->data) return NULL;

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

    CVPixelBufferRef outPB = NULL;
    if (_pool) {
        CVReturn r = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &outPB);
        if (r != kCVReturnSuccess || !outPB) return NULL;
    } else {
        return NULL;
    }

    CVReturn lockRet = CVPixelBufferLockBaseAddress(outPB, 0);
    if (lockRet != kCVReturnSuccess) {
        CVPixelBufferRelease(outPB);
        return NULL;
    }
    void *dstData = CVPixelBufferGetBaseAddress(outPB);
    if (!dstData) {
        CVPixelBufferUnlockBaseAddress(outPB, 0);
        CVPixelBufferRelease(outPB);
        return NULL;
    }

    vImage_Buffer dstBuf = {
        .data = dstData,
        .height = (vImagePixelCount)targetH,
        .width = (vImagePixelCount)targetW,
        .rowBytes = CVPixelBufferGetBytesPerRow(outPB)
    };

    vImageScale_ARGB8888(srcBuf, &dstBuf, NULL, kvImageDoNotTile);
    CVPixelBufferUnlockBaseAddress(outPB, 0);
    return outPB;
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
        CFAbsoluteTime tCar0 = CFAbsoluteTimeGetCurrent();
        kern_return_t kr = _fnRenderDisplay(0, CFSTR("LCD"), _surface, 0, 0);
        if (kr != KERN_SUCCESS) {
            kr = _fnRenderDisplay(0, NULL, _surface, 0, 0);
        }
        CFAbsoluteTime tCar1 = CFAbsoluteTimeGetCurrent();
        double carMs = (tCar1 - tCar0) * 1000.0;
        _carTimeSum += carMs;
        _carTimeCount++;
        if (carMs > _carMaxMs) _carMaxMs = carMs;

        if (kr == KERN_SUCCESS) {
            _carFailCount = 0;
            IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
            vImage_Buffer srcBuf = {
                .data = IOSurfaceGetBaseAddress(_surface),
                .height = (vImagePixelCount)_nativeDisplaySize.height,
                .width = (vImagePixelCount)_nativeDisplaySize.width,
                .rowBytes = IOSurfaceGetBytesPerRow(_surface)
            };
            CFAbsoluteTime tScale0 = CFAbsoluteTimeGetCurrent();
            CVPixelBufferRef outPB = [self _scaleSourceBuffer:&srcBuf];
            CFAbsoluteTime tScale1 = CFAbsoluteTimeGetCurrent();
            IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);

            double scaleMs = (tScale1 - tScale0) * 1000.0;
            _scaleTimeSum += scaleMs;
            _scaleTimeCount++;
            if (scaleMs > _scaleMaxMs) _scaleMaxMs = scaleMs;

            if (outPB) {
                _framesCaptured++;
                uint64_t ptsUs = (uint64_t)((CFAbsoluteTimeGetCurrent() - _startTime) * 1e6);
                [self.delegate screenCapture:self didCaptureBuffer:outPB pts:ptsUs];
                CVPixelBufferRelease(outPB);
            }
        } else {
            _carFailCount++;
            _lastError = [NSString stringWithFormat:@"CARenderDisplay kr=%d", kr];
            if (_carFailCount >= 3 && _fnUICreateScreen) {
                NSLog(@"[ScreenCapture] CARenderDisplay failed 3 times (kr=%d), temporarily falling back to UIPRIV", kr);
                _backend = BackendUIPRIV;
                _carProbeCounter = 0;
            }
        }
    } else if (_backend == BackendUIPRIV) {
        // Periodically probe CARenderServer every ~60 ticks (~2s at 30fps) to see if hardware capture recovered.
        if (_fnRenderDisplay && _surface && ++_carProbeCounter >= 60) {
            _carProbeCounter = 0;
            kern_return_t probeKr = _fnRenderDisplay(0, CFSTR("LCD"), _surface, 0, 0);
            if (probeKr != KERN_SUCCESS) {
                probeKr = _fnRenderDisplay(0, NULL, _surface, 0, 0);
            }
            if (probeKr == KERN_SUCCESS) {
                NSLog(@"[ScreenCapture] CARenderDisplay probe succeeded, recovering BackendCAR");
                _backend = BackendCAR;
                _carFailCount = 0;
                IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
                vImage_Buffer srcBuf = {
                    .data = IOSurfaceGetBaseAddress(_surface),
                    .height = (vImagePixelCount)_nativeDisplaySize.height,
                    .width = (vImagePixelCount)_nativeDisplaySize.width,
                    .rowBytes = IOSurfaceGetBytesPerRow(_surface)
                };
                CFAbsoluteTime tScale0 = CFAbsoluteTimeGetCurrent();
                CVPixelBufferRef outPB = [self _scaleSourceBuffer:&srcBuf];
                CFAbsoluteTime tScale1 = CFAbsoluteTimeGetCurrent();
                IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);

                double scaleMs = (tScale1 - tScale0) * 1000.0;
                _scaleTimeSum += scaleMs;
                _scaleTimeCount++;
                if (scaleMs > _scaleMaxMs) _scaleMaxMs = scaleMs;

                if (outPB) {
                    _framesCaptured++;
                    uint64_t ptsUs = (uint64_t)((CFAbsoluteTimeGetCurrent() - _startTime) * 1e6);
                    [self.delegate screenCapture:self didCaptureBuffer:outPB pts:ptsUs];
                    CVPixelBufferRelease(outPB);
                }
                double elapsedMs = (CFAbsoluteTimeGetCurrent() - tickStart) * 1000.0;
                _intervalCaptureTimeSum += elapsedMs;
                _intervalCaptureCount++;
                if (elapsedMs > _intervalMaxCaptureTimeMs) _intervalMaxCaptureTimeMs = elapsedMs;
                _busy = NO;
                return;
            }
        }

        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        UIImage *ui = (__bridge_transfer UIImage *)_fnUICreateScreen();
        CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
        if (ui && ui.CGImage) {
            CGImageRef img = ui.CGImage;
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
                CFAbsoluteTime tScale0 = CFAbsoluteTimeGetCurrent();
                CVPixelBufferRef outPB = [self _scaleSourceBuffer:&srcBuf];
                CFAbsoluteTime tScale1 = CFAbsoluteTimeGetCurrent();
                double scaleMs = (tScale1 - tScale0) * 1000.0;
                _scaleTimeSum += scaleMs;
                _scaleTimeCount++;
                if (scaleMs > _scaleMaxMs) _scaleMaxMs = scaleMs;

                if (surf) {
                    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
                } else if (rawData) {
                    CFRelease(rawData);
                }
                if (outPB) {
                    _framesCaptured++;
                    uint64_t ptsUs = (uint64_t)((CFAbsoluteTimeGetCurrent() - _startTime) * 1e6);
                    [self.delegate screenCapture:self didCaptureBuffer:outPB pts:ptsUs];
                    CVPixelBufferRelease(outPB);
                }

                static int uiprivCount = 0;
                if (++uiprivCount % 30 == 1) {
                    NSLog(@"[UIPRIV Timing] snap=%.2fms scale=%.2fms total=%.2fms",
                          (t1 - t0) * 1000.0, scaleMs, (tScale1 - t0) * 1000.0);
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
