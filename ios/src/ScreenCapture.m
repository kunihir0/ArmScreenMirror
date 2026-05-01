#import "ScreenCapture.h"
#import "PrivateHeaders.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <dlfcn.h>

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

/// Decide si gastamos energía emitiendo este frame. Actualiza el contador
/// de frames estáticos y el modo idle.
- (BOOL)_shouldEmitFrame:(BOOL)unchanged {
    if (unchanged) {
        _staticFrameStreak++;
        // Tras ~2s sin cambios, bajamos el rate del timer al idleFps.
        if (!_inIdleMode && _staticFrameStreak > (NSUInteger)(_activeFps * 2)) {
            _inIdleMode = YES;
            [self _applyTimerInterval];
        }
        return NO;
    }
    if (_inIdleMode) {
        _inIdleMode = NO;
        [self _applyTimerInterval];
    }
    _staticFrameStreak = 0;
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

    if (_backend == BackendCAR) {
        kern_return_t kr = _fnRenderDisplay(0, NULL, _surface, 0, 0);
        if (kr == KERN_SUCCESS) {
            IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
            BOOL black = (_consecutiveBlack < 30) && surface_is_black(_surface);
            BOOL unchanged = !black && bytes_unchanged(
                IOSurfaceGetBaseAddress(_surface),
                IOSurfaceGetBytesPerRow(_surface),
                IOSurfaceGetWidth(_surface),
                IOSurfaceGetHeight(_surface),
                _lastSamples, &_haveLastSamples);
            IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);

            if (black) {
                _framesBlack++;
                if (++_consecutiveBlack >= 30 && _fnUICreateScreen) {
                    NSLog(@"[ScreenCapture] CAR negro 30 frames, fallback UIPRIV");
                    _backend = BackendUIPRIV;
                    _busy = NO;
                    [self _tick];
                    return;
                }
                _busy = NO; return;
            }
            _consecutiveBlack = 0;
            if (![self _shouldEmitFrame:unchanged]) { _busy = NO; return; }

            _framesCaptured++;
            uint64_t ptsUs = (uint64_t)((CFAbsoluteTimeGetCurrent() - _startTime) * 1e6);
            [self.delegate screenCapture:self didCaptureBuffer:_wrappedPB pts:ptsUs];
        } else {
            _lastError = [NSString stringWithFormat:@"CARenderDisplay kr=%d", kr];
        }
    } else if (_backend == BackendUIPRIV) {
        // bridge_transfer toma la +1 del Create y la pasa a ARC
        UIImage *ui = (__bridge_transfer UIImage *)_fnUICreateScreen();
        if (ui && ui.CGImage) {
            CGImageRef img = ui.CGImage;
            size_t w = CGImageGetWidth(img);
            size_t h = CGImageGetHeight(img);
            if (!_pool) {
                NSDictionary *pa = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (id)kCVPixelBufferWidthKey:           @(w),
                    (id)kCVPixelBufferHeightKey:          @(h),
                };
                CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                        (__bridge CFDictionaryRef)pa, &_pool);
            }
            CVPixelBufferRef pb = NULL;
            if (_pool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &pb);
            if (pb) {
                CVPixelBufferLockBaseAddress(pb, 0);
                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                CGContextRef ctx = CGBitmapContextCreate(
                    CVPixelBufferGetBaseAddress(pb), w, h, 8,
                    CVPixelBufferGetBytesPerRow(pb), cs,
                    kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
                CGColorSpaceRelease(cs);
                if (ctx) {
                    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
                    CGContextRelease(ctx);
                }
                BOOL unchanged = bytes_unchanged(
                    CVPixelBufferGetBaseAddress(pb),
                    CVPixelBufferGetBytesPerRow(pb),
                    w, h, _lastSamples, &_haveLastSamples);
                CVPixelBufferUnlockBaseAddress(pb, 0);
                if ([self _shouldEmitFrame:unchanged]) {
                    _framesCaptured++;
                    uint64_t ptsUs = (uint64_t)((CFAbsoluteTimeGetCurrent() - _startTime) * 1e6);
                    [self.delegate screenCapture:self didCaptureBuffer:pb pts:ptsUs];
                }
                CVPixelBufferRelease(pb);
            }
        } else {
            _lastError = @"UIPRIV nil";
        }
    }

    _busy = NO;
}

@end
