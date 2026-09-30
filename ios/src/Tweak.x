#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <notify.h>
#import "Protocol.h"
#import "ScreenCapture.h"
#import "VideoEncoder.h"
#import "NetworkClient.h"
#import "TouchInjector.h"

#define SMIR_PREFS_PATH    @"/var/mobile/Library/Preferences/com.example.screenmirror.plist"
#define SMIR_STATUS_PATH   @"/var/mobile/Library/Preferences/com.example.screenmirror.status.plist"
#define SMIR_NOTIF_RELOAD  "com.example.screenmirror.reload"

@interface SMIRController : NSObject
    <ScreenCaptureDelegate, VideoEncoderDelegate, NetworkClientDelegate>
@end

@implementation SMIRController {
    NetworkClient *_net;
    ScreenCapture *_cap;
    VideoEncoder  *_enc;
    TouchInjector *_inj;
    BOOL _connecting;
    NSString *_host;
    float _savedVolumeBeforeMute;  // volume level remembered for unmute
    NSUInteger _framesEncoded;
    NSUInteger _lastReportedCapFrames;
    NSUInteger _lastReportedEncFrames;
}

+ (instancetype)shared {
    static SMIRController *s;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[self alloc] init]; });
    return s;
}

/// Lee una clave del plist gestionado por la app de control. Si el plist
/// no existe o falta la clave, cae al .conf antiguo (compat con instalaciones
/// que no tengan la app instalada todavía).
- (id)_readPrefsKey:(NSString *)key {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:SMIR_PREFS_PATH];
    if (prefs[key]) return prefs[key];

    NSString *prefix = [key stringByAppendingString:@"="];
    for (NSString *path in @[
        @"/var/jb/etc/screenmirror.conf",
        @"/tmp/screenmirror.conf",
    ]) {
        NSString *cfg = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [cfg componentsSeparatedByString:@"\n"]) {
            NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([t hasPrefix:prefix]) return [t substringFromIndex:prefix.length];
        }
    }
    return nil;
}

- (NSString *)_readHost     { id v = [self _readPrefsKey:@"host"];     return [v isKindOfClass:NSString.class] ? v : nil; }
- (NSString *)_readPassword { id v = [self _readPrefsKey:@"password"]; return [v isKindOfClass:NSString.class] ? v : nil; }
- (BOOL)     _readEnabled   {
    id v = [self _readPrefsKey:@"enabled"];
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return YES;  // por defecto activo si el usuario no lo ha tocado
}

- (void)_writeStatus:(NSString *)state extra:(NSDictionary *)extra {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"state"]   = state;
    d[@"updated"] = @([NSDate timeIntervalSinceReferenceDate]);
    if (extra) [d addEntriesFromDictionary:extra];
    [d writeToFile:SMIR_STATUS_PATH atomically:YES];
}

- (void)start {
    _net = [[NetworkClient alloc] init];
    _net.delegate = self;

    // Suscripción al toque del botón "Aplicar" en la app de control.
    int token = 0;
    notify_register_dispatch(SMIR_NOTIF_RELOAD, &token, dispatch_get_main_queue(), ^(int t) {
        NSLog(@"[SMIR] Darwin notify reload — releyendo config");
        [self _reloadAndApply];
    });

    [self _writeStatus:@"idle" extra:nil];
    [self _attemptConnect];

    // Reintenta cada 5s si no hay conexión y el toggle está activo.
    NSTimer *t = [NSTimer timerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
        if (![self _readEnabled]) return;
        if (!self->_net.connected && !self->_connecting) [self _attemptConnect];
    }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];

    // Telemetría periódica una vez por segundo.
    NSTimer *telemetry = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        if (!self->_net.connected || !self->_cap) return;
        [self _logTelemetry];
    }];
    [[NSRunLoop mainRunLoop] addTimer:telemetry forMode:NSRunLoopCommonModes];
}

- (void)_logTelemetry {
    NSUInteger currentCap = _cap.framesCaptured;
    NSUInteger capFps = currentCap >= _lastReportedCapFrames ? (currentCap - _lastReportedCapFrames) : currentCap;
    _lastReportedCapFrames = currentCap;

    NSUInteger currentEnc = _framesEncoded;
    NSUInteger encFps = currentEnc >= _lastReportedEncFrames ? (currentEnc - _lastReportedEncFrames) : currentEnc;
    _lastReportedEncFrames = currentEnc;

    NSUInteger txBytes = _net.bytesTransmittedInSec;
    _net.bytesTransmittedInSec = 0;

    NSUInteger dropped = _net.droppedInLastSec;
    _net.droppedInLastSec = 0;

    double avgCapMs = _cap.avgCaptureTimeMs;
    double maxCapMs = _cap.maxCaptureTimeMs;
    [_cap resetIntervalTiming];

    NSLog(@"[SMIR Telemetry] backend=%@ reqFps=%ld capFps=%lu encFps=%lu skipped=0 capAvg=%.2fms capMax=%.2fms txKbps=%lu queueBytes=%lu droppedFrames=%lu",
          _cap.backendName, (long)_cap.fps, (unsigned long)capFps, (unsigned long)encFps,
          avgCapMs, maxCapMs, (unsigned long)(txBytes * 8 / 1000), (unsigned long)_net.writeQueueBytes, (unsigned long)dropped);
}

- (void)_reloadAndApply {
    BOOL enabled = [self _readEnabled];
    if (!enabled) {
        // Usuario apagó el toggle: desconectamos.
        if (_net.connected || _connecting) [_net disconnect];
        [self _writeStatus:@"disconnected" extra:@{@"error":@"Desactivado por el usuario"}];
        return;
    }
    // Si los datos cambiaron, desconectamos para que el siguiente
    // attempt use el host/password nuevos.
    if (_net.connected || _connecting) [_net disconnect];
    [self _attemptConnect];
}

- (void)_attemptConnect {
    if (![self _readEnabled]) {
        [self _writeStatus:@"disconnected" extra:@{@"error":@"Desactivado por el usuario"}];
        return;
    }
    NSString *h = [self _readHost];
    NSString *pwd = [self _readPassword];
    if (!h.length || !pwd.length) {
        [self _writeStatus:@"idle" extra:@{@"error":@"Falta host o contraseña — usa la app ScreenMirror"}];
        return;
    }
    _host = h;
    _connecting = YES;
    _net.password = pwd;
    [self _writeStatus:@"auth" extra:@{@"peer": [NSString stringWithFormat:@"%@:4878", h]}];
    NSLog(@"[SMIR] conectando a %@:4878", h);
    [_net connectToHost:h port:4878];
}

- (NSString *)_deviceName {
    struct utsname u; uname(&u);
    return [NSString stringWithUTF8String:u.machine];
}

#pragma mark - NetworkClientDelegate

- (void)networkClientDidConnect:(NetworkClient *)c {
    _connecting = NO;
    NSLog(@"[SMIR] conectado, iniciando captura desde SpringBoard");

    _inj = [[TouchInjector alloc] initWithPointSize:[UIScreen mainScreen].bounds.size];

    __weak typeof(self) weakSelf = self;
    _net.onVideoFrameDropped = ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) [strongSelf->_enc forceKeyframe];
    };

    [self _startPipelineWithScale:0.40 fps:30 idleFps:30 bitrate:1500000 quality:0.50];

    struct utsname u; uname(&u);
    NSString *device = [NSString stringWithUTF8String:u.machine];
    [self _writeStatus:@"connected" extra:@{
        @"peer":    [NSString stringWithFormat:@"%@:4878", _host ?: @""],
        @"device":  device,
        @"backend": @"AES-256-GCM • X25519 ephemeral"
    }];

    SMIRHandshake hs = {0};
    hs.width  = CFSwapInt32HostToBig((uint32_t)_cap.pointSize.width);
    hs.height = CFSwapInt32HostToBig((uint32_t)_cap.pointSize.height);
    float scale = 1.0f;
    uint32_t scaleBits; memcpy(&scaleBits, &scale, 4);
    scaleBits = CFSwapInt32HostToBig(scaleBits);
    memcpy(&hs.scale, &scaleBits, 4);
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    hs.ios_major = (uint8_t)v.majorVersion;
    hs.ios_minor = (uint8_t)v.minorVersion;
    hs.orientation = 1;
    NSString *name = [self _deviceName];
    strncpy(hs.device_name, name.UTF8String, sizeof(hs.device_name) - 1);
    [_net sendType:SMIR_HANDSHAKE payload:[NSData dataWithBytes:&hs length:sizeof(hs)]];
}

- (void)_startPipelineWithScale:(CGFloat)scale
                            fps:(NSInteger)fps
                        idleFps:(NSInteger)idleFps
                        bitrate:(NSInteger)bitrate
                        quality:(float)quality
{
    [_cap stop]; _cap = nil;
    [_enc stop]; _enc = nil;
    _lastReportedCapFrames = 0;
    _lastReportedEncFrames = 0;
    _framesEncoded = 0;

    _cap = [[ScreenCapture alloc] init];
    _cap.captureScale = scale;
    _cap.fps          = fps;
    _cap.idleFps      = idleFps;
    _cap.delegate     = self;

    _enc = [[VideoEncoder alloc] init];
    _enc.bitrate  = bitrate;
    _enc.quality  = quality;
    _enc.delegate = self;
    BOOL encOK = [_enc startWithWidth:(int)_cap.displaySize.width
                               height:(int)_cap.displaySize.height
                                  fps:fps];
    if (!encOK) NSLog(@"[SMIR] encoder no pudo arrancar");

    if (![_cap start]) {
        NSLog(@"[SMIR] captura falló: %@", _cap.lastError);
        [_net disconnect];
        return;
    }
    NSLog(@"[SMIR] pipeline activo: %.0fx%.0f @ %ld fps (idle %ld) bitrate=%ld q=%.2f",
          _cap.displaySize.width, _cap.displaySize.height,
          (long)fps, (long)idleFps, (long)bitrate, quality);
}

- (void)networkClient:(NetworkClient *)c didDisconnectWithError:(NSError *)err {
    _connecting = NO;
    NSLog(@"[SMIR] desconectado: %@", err.localizedDescription ?: @"(ok)");
    [_cap stop]; [_enc stop]; _cap = nil; _enc = nil;
    [self _writeStatus:@"disconnected" extra:err.localizedDescription
        ? @{@"error": err.localizedDescription} : @{}];
}

/// Toggle media-volume mute via the private `AVSystemController`. We talk to
/// it through dlsym'd selectors so the binary still loads on devices where
/// the framework has been renamed or stripped. State alternates: the first
/// tap saves the current volume and drops it to 0, the second tap restores
/// the saved level. The volume HUD appears for free.
- (void)_toggleAudioMute {
    Class avsClass = NSClassFromString(@"AVSystemController");
    if (!avsClass) { NSLog(@"[SMIR] mute: AVSystemController no disponible"); return; }
    SEL sharedSel = NSSelectorFromString(@"sharedAVSystemController");
    if (![avsClass respondsToSelector:sharedSel]) {
        NSLog(@"[SMIR] mute: sharedAVSystemController missing"); return;
    }
    typedef id (*SharedFn)(Class, SEL);
    SharedFn shared = (SharedFn)[avsClass methodForSelector:sharedSel];
    id avs = shared(avsClass, sharedSel);
    if (!avs) { NSLog(@"[SMIR] mute: sharedAVSystemController = nil"); return; }

    NSString *category = @"Audio/Video";
    SEL getSel = NSSelectorFromString(@"getVolume:forCategory:");
    SEL setSel = NSSelectorFromString(@"setVolumeTo:forCategory:");
    if (![avs respondsToSelector:getSel] || ![avs respondsToSelector:setSel]) {
        NSLog(@"[SMIR] mute: AVSystemController API ausente");
        return;
    }

    typedef BOOL (*GetVolFn)(id, SEL, float *, NSString *);
    typedef BOOL (*SetVolFn)(id, SEL, float, NSString *);
    GetVolFn getVol = (GetVolFn)[avs methodForSelector:getSel];
    SetVolFn setVol = (SetVolFn)[avs methodForSelector:setSel];

    float current = 0;
    if (!getVol(avs, getSel, &current, category)) {
        NSLog(@"[SMIR] mute: getVolume falló");
        return;
    }
    if (current > 0.001f) {
        _savedVolumeBeforeMute = current;
        setVol(avs, setSel, 0.0f, category);
        NSLog(@"[SMIR] mute ON (vol guardado %.2f)", current);
    } else {
        float restore = (_savedVolumeBeforeMute > 0.05f) ? _savedVolumeBeforeMute : 0.5f;
        setVol(avs, setSel, restore, category);
        NSLog(@"[SMIR] mute OFF → vol %.2f", restore);
    }
}

- (void)networkClient:(NetworkClient *)c didReceiveType:(SMIRType)type payload:(NSData *)payload {
    switch (type) {
        case SMIR_TOUCH_DOWN: case SMIR_TOUCH_MOVE: case SMIR_TOUCH_UP: {
            if (payload.length < sizeof(SMIRTouch)) return;
            SMIRTouch t; memcpy(&t, payload.bytes, sizeof(t));
            uint32_t xb, yb;
            memcpy(&xb, &t.x_norm, 4); xb = CFSwapInt32BigToHost(xb);
            memcpy(&yb, &t.y_norm, 4); yb = CFSwapInt32BigToHost(yb);
            float x, y; memcpy(&x, &xb, 4); memcpy(&y, &yb, 4);
            CGPoint p = CGPointMake(x, y);
            if (type == SMIR_TOUCH_DOWN) [_inj touchDownFinger:t.finger_id atNorm:p];
            else if (type == SMIR_TOUCH_MOVE) [_inj touchMoveFinger:t.finger_id atNorm:p];
            else [_inj touchUpFinger:t.finger_id atNorm:p];
            break;
        }
        case SMIR_SWIPE: {
            if (payload.length < sizeof(SMIRSwipe)) return;
            SMIRSwipe s; memcpy(&s, payload.bytes, sizeof(s));
            float coords[4]; uint32_t bits;
            float *flds[4] = { &s.x1, &s.y1, &s.x2, &s.y2 };
            for (int i = 0; i < 4; i++) {
                memcpy(&bits, flds[i], 4); bits = CFSwapInt32BigToHost(bits);
                memcpy(&coords[i], &bits, 4);
            }
            uint32_t durMs = CFSwapInt32BigToHost(s.duration_ms);
            NSLog(@"[SMIR] swipe (%.2f,%.2f)->(%.2f,%.2f) %ums", coords[0], coords[1], coords[2], coords[3], durMs);
            [_inj performSwipeFromNorm:CGPointMake(coords[0], coords[1])
                                toNorm:CGPointMake(coords[2], coords[3])
                            durationMs:durMs];
            break;
        }
        case SMIR_KEY_EVENT: {
            if (payload.length < sizeof(SMIRKey)) return;
            SMIRKey k; memcpy(&k, payload.bytes, sizeof(k));
            uint16_t code = CFSwapInt16BigToHost(k.hid_keycode);
            if (k.down) [_inj keyDown:code]; else [_inj keyUp:code];
            break;
        }
        case SMIR_TEXT_INPUT: {
            if (payload.length < 4) return;
            uint32_t len; memcpy(&len, payload.bytes, 4); len = CFSwapInt32BigToHost(len);
            if (payload.length < 4 + len) return;
            NSString *s = [[NSString alloc] initWithBytes:(const uint8_t *)payload.bytes + 4
                                                   length:len encoding:NSUTF8StringEncoding];
            if (s) [_inj typeText:s];
            break;
        }
        case SMIR_BUTTON_EVENT: {
            if (payload.length < sizeof(SMIRButton)) return;
            SMIRButton b; memcpy(&b, payload.bytes, sizeof(b));
            // Mute is special: there's no software-emulatable hardware ringer
            // switch on iPhone, and HID consumer-page Mute (0xE2) doesn't
            // actually mute media on iOS. Toggle the active audio category's
            // volume between 0 and the saved level via AVSystemController —
            // this is what apps actually respond to and shows the volume HUD.
            if (b.button_id == SMIR_BTN_MUTE) {
                if (b.down) [self _toggleAudioMute];
                break;
            }
            [_inj pressButton:b.button_id down:b.down ? YES : NO];
            break;
        }
        case SMIR_QUALITY: {
            if (payload.length < 1) return;
            uint8_t preset = ((const uint8_t *)payload.bytes)[0];
            CGFloat scale; NSInteger fps, idleFps, bitrate; float q;
            switch (preset) {
                case 0:  scale = 0.30; fps = 30; idleFps = 30; bitrate =  800000; q = 0.40; break;
                case 2:  scale = 0.45; fps = 30; idleFps = 30; bitrate = 2200000; q = 0.55; break;
                default: scale = 0.40; fps = 30; idleFps = 30; bitrate = 1500000; q = 0.50; break;
            }
            NSLog(@"[SMIR] cambio de calidad → preset=%u scale=%.2f fps=%ld bitrate=%ld", preset, scale, (long)fps, (long)bitrate);
            [self _startPipelineWithScale:scale fps:fps idleFps:idleFps
                                  bitrate:bitrate quality:q];
            // Reenvía handshake (por si el orientation cambió, etc.)
            SMIRHandshake hs = {0};
            hs.width  = CFSwapInt32HostToBig((uint32_t)_cap.pointSize.width);
            hs.height = CFSwapInt32HostToBig((uint32_t)_cap.pointSize.height);
            float s = 1.0f;
            uint32_t sb; memcpy(&sb, &s, 4); sb = CFSwapInt32HostToBig(sb);
            memcpy(&hs.scale, &sb, 4);
            NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
            hs.ios_major = (uint8_t)v.majorVersion;
            hs.ios_minor = (uint8_t)v.minorVersion;
            hs.orientation = 1;
            strncpy(hs.device_name, [self _deviceName].UTF8String, sizeof(hs.device_name) - 1);
            [_net sendType:SMIR_HANDSHAKE payload:[NSData dataWithBytes:&hs length:sizeof(hs)]];
            break;
        }
        case SMIR_PING: [_net sendType:SMIR_PONG payload:payload]; break;
        default: break;
    }
}

#pragma mark - ScreenCaptureDelegate

- (void)screenCapture:(ScreenCapture *)cap didCaptureBuffer:(CVPixelBufferRef)pb pts:(uint64_t)ptsUs {
    [_enc encodePixelBuffer:pb pts:ptsUs];
}

#pragma mark - VideoEncoderDelegate

- (void)videoEncoder:(VideoEncoder *)enc didProduceConfigSPS:(NSData *)sps PPS:(NSData *)pps {
    NSMutableData *d = [NSMutableData data];
    uint32_t sl = CFSwapInt32HostToBig((uint32_t)sps.length);
    [d appendBytes:&sl length:4]; [d appendData:sps];
    uint32_t pl = CFSwapInt32HostToBig((uint32_t)pps.length);
    [d appendBytes:&pl length:4]; [d appendData:pps];
    [_net sendType:SMIR_VIDEO_CONFIG payload:d];
}

- (void)videoEncoder:(VideoEncoder *)enc didProduceFrame:(NSData *)annexB keyframe:(BOOL)keyframe pts:(uint64_t)ptsUs {
    _framesEncoded++;
    NSMutableData *d = [NSMutableData dataWithCapacity:annexB.length + 12];
    uint8_t hdr[4] = { keyframe ? 1 : 0, 0, 0, 0 };
    [d appendBytes:hdr length:4];
    uint64_t pts = CFSwapInt64HostToBig(ptsUs);
    [d appendBytes:&pts length:8];
    [d appendData:annexB];
    [_net sendType:SMIR_VIDEO_FRAME payload:d];
}

@end

static void smir_log_redirect(void) {
    FILE *f = fopen("/tmp/screenmirror.log", "a");
    if (!f) return;
    setvbuf(f, NULL, _IOLBF, 0);
    dup2(fileno(f), STDOUT_FILENO);
    dup2(fileno(f), STDERR_FILENO);
    NSLog(@"---- SMIR tweak loaded %@ in pid=%d ----", [NSDate date], getpid());
}

%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    if (![proc isEqualToString:@"SpringBoard"]) return;
    smir_log_redirect();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[SMIRController shared] start];
    });
}
