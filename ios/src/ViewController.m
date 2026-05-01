#import "ViewController.h"
#import "ScreenCapture.h"
#import "VideoEncoder.h"
#import "NetworkClient.h"
#import "TouchInjector.h"
#import "Protocol.h"

#import <sys/utsname.h>

@interface ViewController () <ScreenCaptureDelegate, VideoEncoderDelegate, NetworkClientDelegate, UITextFieldDelegate, UIPickerViewDelegate, UIPickerViewDataSource>

@property (nonatomic, strong) UITextField *hostField;
@property (nonatomic, strong) UIButton    *connectButton;
@property (nonatomic, strong) UILabel     *statusLabel;
@property (nonatomic, strong) UIPickerView *picker;
@property (nonatomic, strong) NSArray<NSNetService *> *services;

@property (nonatomic, strong) ScreenCapture *capture;
@property (nonatomic, strong) VideoEncoder  *encoder;
@property (nonatomic, strong) NetworkClient *net;
@property (nonatomic, strong) TouchInjector *injector;

@property (nonatomic, strong) NSTimer *statsTimer;
@property (nonatomic, assign) NSUInteger framesEncoded;
@property (nonatomic, assign) NSUInteger keyframes;
@property (nonatomic, assign) uint64_t   bytesSent;
@property (nonatomic, assign) BOOL configSent;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"ScreenMirror";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    self.hostField = [[UITextField alloc] init];
    self.hostField.placeholder = @"IP del Mac (auto)";
    self.hostField.borderStyle = UITextBorderStyleRoundedRect;
    self.hostField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.hostField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.hostField.delegate = self;
    self.hostField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.hostField];

    self.picker = [[UIPickerView alloc] init];
    self.picker.dataSource = self;
    self.picker.delegate   = self;
    self.picker.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.picker];

    self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.connectButton setTitle:@"Connect" forState:UIControlStateNormal];
    self.connectButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [self.connectButton addTarget:self action:@selector(toggleConnect) forControlEvents:UIControlEventTouchUpInside];
    self.connectButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.connectButton];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"Idle";
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textColor = [UIColor darkGrayColor];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor      constraintEqualToAnchor:g.topAnchor constant:24],
        [title.leadingAnchor  constraintEqualToAnchor:g.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [self.hostField.topAnchor      constraintEqualToAnchor:title.bottomAnchor constant:24],
        [self.hostField.leadingAnchor  constraintEqualToAnchor:g.leadingAnchor constant:24],
        [self.hostField.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
        [self.hostField.heightAnchor   constraintEqualToConstant:40],

        [self.picker.topAnchor      constraintEqualToAnchor:self.hostField.bottomAnchor constant:8],
        [self.picker.leadingAnchor  constraintEqualToAnchor:g.leadingAnchor],
        [self.picker.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [self.picker.heightAnchor   constraintEqualToConstant:140],

        [self.connectButton.topAnchor      constraintEqualToAnchor:self.picker.bottomAnchor constant:16],
        [self.connectButton.centerXAnchor  constraintEqualToAnchor:g.centerXAnchor],

        [self.statusLabel.topAnchor      constraintEqualToAnchor:self.connectButton.bottomAnchor constant:24],
        [self.statusLabel.leadingAnchor  constraintEqualToAnchor:g.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
    ]];

    self.net = [[NetworkClient alloc] init];
    self.net.delegate = self;
    [self.net startBrowsingBonjour:^(NSArray<NSNetService *> *list) {
        self.services = list;
        [self.picker reloadAllComponents];
    }];

    [self _maybeAutoConnect];
}

- (void)_maybeAutoConnect {
    // Si /tmp/screenmirror.conf contiene una línea "host=IP" autoconectamos.
    NSString *cfg = [NSString stringWithContentsOfFile:@"/tmp/screenmirror.conf"
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!cfg.length) return;
    for (NSString *line in [cfg componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"host="]) {
            self.hostField.text = [t substringFromIndex:5];
            NSLog(@"[VC] auto-connect %@", self.hostField.text);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self toggleConnect]; });
            return;
        }
    }
}

- (void)setStatus:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.text = s; });
}

- (NSString *)deviceName {
    struct utsname u; uname(&u);
    return [NSString stringWithUTF8String:u.machine];
}

#pragma mark - Connect / disconnect

- (void)toggleConnect {
    if (self.net.connected) {
        [self.net disconnect];
        [self.capture stop];
        [self.encoder stop];
        self.capture = nil; self.encoder = nil;
        [self.connectButton setTitle:@"Connect" forState:UIControlStateNormal];
        [self setStatus:@"Disconnected"];
        return;
    }

    NSString *host = self.hostField.text;
    if (host.length == 0) {
        NSInteger row = [self.picker selectedRowInComponent:0];
        if (row < (NSInteger)self.services.count) {
            NSNetService *s = self.services[row];
            host = s.hostName ?: @"";
        }
    }
    if (host.length == 0) {
        [self setStatus:@"Selecciona un servidor o introduce IP"];
        return;
    }

    [self setStatus:[NSString stringWithFormat:@"Conectando a %@...", host]];
    [self.net connectToHost:host port:4878];
}

#pragma mark - NetworkClient

- (void)networkClientDidConnect:(NetworkClient *)c {
    [self setStatus:@"Conectado, iniciando captura..."];
    [self.connectButton setTitle:@"Disconnect" forState:UIControlStateNormal];

    self.framesEncoded = 0;
    self.keyframes = 0;
    self.bytesSent = 0;
    self.configSent = NO;

    self.capture = [[ScreenCapture alloc] init];
    self.capture.delegate = self;

    self.injector = [[TouchInjector alloc] initWithPointSize:self.capture.pointSize];

    self.encoder = [[VideoEncoder alloc] init];
    self.encoder.delegate = self;
    [self.encoder startWithWidth:(int)self.capture.displaySize.width
                          height:(int)self.capture.displaySize.height];

    // Handshake
    SMIRHandshake hs = {0};
    hs.width  = CFSwapInt32HostToBig((uint32_t)self.capture.displaySize.width);
    hs.height = CFSwapInt32HostToBig((uint32_t)self.capture.displaySize.height);
    float scale = (float)self.capture.displayScale;
    uint32_t scaleBits;
    memcpy(&scaleBits, &scale, 4);
    scaleBits = CFSwapInt32HostToBig(scaleBits);
    memcpy(&hs.scale, &scaleBits, 4);
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    hs.ios_major = (uint8_t)v.majorVersion;
    hs.ios_minor = (uint8_t)v.minorVersion;
    hs.orientation = 1;
    NSString *name = [self deviceName];
    strncpy(hs.device_name, name.UTF8String, sizeof(hs.device_name) - 1);

    NSData *payload = [NSData dataWithBytes:&hs length:sizeof(hs)];
    [self.net sendType:SMIR_HANDSHAKE payload:payload];

    if (![self.capture start]) {
        NSString *err = self.capture.lastError ?: @"desconocido";
        [self setStatus:[NSString stringWithFormat:@"Captura falló: %@", err]];
        [self.net disconnect];
        return;
    }

    [self.statsTimer invalidate];
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(_updateStats)
                                                     userInfo:nil
                                                      repeats:YES];
}

- (void)_updateStats {
    NSString *s = [NSString stringWithFormat:
        @"Backend: %@\nCaptured: %lu (black: %lu)\nEncoded: %lu (key: %lu)\nSent: %.1f KB\nConfig: %@\n%@",
        self.capture.backendName,
        (unsigned long)self.capture.framesCaptured,
        (unsigned long)self.capture.framesBlack,
        (unsigned long)self.framesEncoded,
        (unsigned long)self.keyframes,
        self.bytesSent / 1024.0,
        self.configSent ? @"sent" : @"pending",
        self.capture.lastError ?: @""];
    [self setStatus:s];
    NSLog(@"[Stats] backend=%@ cap=%lu black=%lu enc=%lu key=%lu sent=%llu cfg=%d err=%@",
          self.capture.backendName,
          (unsigned long)self.capture.framesCaptured,
          (unsigned long)self.capture.framesBlack,
          (unsigned long)self.framesEncoded,
          (unsigned long)self.keyframes,
          self.bytesSent,
          self.configSent,
          self.capture.lastError);
}

- (void)networkClient:(NetworkClient *)c didDisconnectWithError:(NSError *)err {
    [self.statsTimer invalidate];
    self.statsTimer = nil;
    [self.capture stop];
    [self.encoder stop];
    self.capture = nil; self.encoder = nil;
    [self.connectButton setTitle:@"Connect" forState:UIControlStateNormal];
    [self setStatus:err ? [@"Error: " stringByAppendingString:err.localizedDescription] : @"Disconnected"];
}

- (void)networkClient:(NetworkClient *)c didReceiveType:(SMIRType)type payload:(NSData *)payload {
    switch (type) {
        case SMIR_TOUCH_DOWN:
        case SMIR_TOUCH_MOVE:
        case SMIR_TOUCH_UP: {
            if (payload.length < sizeof(SMIRTouch)) return;
            SMIRTouch t;
            memcpy(&t, payload.bytes, sizeof(t));
            uint32_t xb, yb;
            memcpy(&xb, &t.x_norm, 4); xb = CFSwapInt32BigToHost(xb);
            memcpy(&yb, &t.y_norm, 4); yb = CFSwapInt32BigToHost(yb);
            float x, y;
            memcpy(&x, &xb, 4);
            memcpy(&y, &yb, 4);
            CGPoint p = CGPointMake(x, y);
            if (type == SMIR_TOUCH_DOWN) [self.injector touchDownFinger:t.finger_id atNorm:p];
            else if (type == SMIR_TOUCH_MOVE) [self.injector touchMoveFinger:t.finger_id atNorm:p];
            else [self.injector touchUpFinger:t.finger_id atNorm:p];
            break;
        }
        case SMIR_KEY_EVENT: {
            if (payload.length < sizeof(SMIRKey)) return;
            SMIRKey k; memcpy(&k, payload.bytes, sizeof(k));
            uint16_t code = CFSwapInt16BigToHost(k.hid_keycode);
            if (k.down) [self.injector keyDown:code]; else [self.injector keyUp:code];
            break;
        }
        case SMIR_TEXT_INPUT: {
            if (payload.length < 4) return;
            uint32_t len; memcpy(&len, payload.bytes, 4);
            len = CFSwapInt32BigToHost(len);
            if (payload.length < 4 + len) return;
            NSString *s = [[NSString alloc] initWithBytes:(const uint8_t *)payload.bytes + 4
                                                   length:len encoding:NSUTF8StringEncoding];
            if (s) [self.injector typeText:s];
            break;
        }
        case SMIR_BUTTON_EVENT: {
            if (payload.length < sizeof(SMIRButton)) return;
            SMIRButton b; memcpy(&b, payload.bytes, sizeof(b));
            [self.injector pressButton:b.button_id down:b.down ? YES : NO];
            break;
        }
        case SMIR_PING: {
            [self.net sendType:SMIR_PONG payload:payload];
            break;
        }
        default: break;
    }
}

#pragma mark - ScreenCaptureDelegate

- (void)screenCapture:(ScreenCapture *)cap didCaptureBuffer:(CVPixelBufferRef)pb pts:(uint64_t)ptsUs {
    [self.encoder encodePixelBuffer:pb pts:ptsUs];
}

#pragma mark - VideoEncoderDelegate

- (void)videoEncoder:(VideoEncoder *)enc didProduceConfigSPS:(NSData *)sps PPS:(NSData *)pps {
    NSMutableData *d = [NSMutableData data];
    uint32_t sl = CFSwapInt32HostToBig((uint32_t)sps.length);
    [d appendBytes:&sl length:4];
    [d appendData:sps];
    uint32_t pl = CFSwapInt32HostToBig((uint32_t)pps.length);
    [d appendBytes:&pl length:4];
    [d appendData:pps];
    [self.net sendType:SMIR_VIDEO_CONFIG payload:d];
    self.configSent = YES;
    self.bytesSent += d.length;
    NSLog(@"[VC] config enviado SPS=%lu PPS=%lu", (unsigned long)sps.length, (unsigned long)pps.length);
}

- (void)videoEncoder:(VideoEncoder *)enc didProduceFrame:(NSData *)annexB keyframe:(BOOL)keyframe pts:(uint64_t)ptsUs {
    NSMutableData *d = [NSMutableData dataWithCapacity:annexB.length + 12];
    uint8_t hdr[4] = { keyframe ? 1 : 0, 0, 0, 0 };
    [d appendBytes:hdr length:4];
    uint64_t pts = CFSwapInt64HostToBig(ptsUs);
    [d appendBytes:&pts length:8];
    [d appendData:annexB];
    [self.net sendType:SMIR_VIDEO_FRAME payload:d];
    self.framesEncoded++;
    if (keyframe) self.keyframes++;
    self.bytesSent += d.length;
}

#pragma mark - Picker / TextField

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pv { return 1; }
- (NSInteger)pickerView:(UIPickerView *)pv numberOfRowsInComponent:(NSInteger)c {
    return self.services.count;
}
- (NSString *)pickerView:(UIPickerView *)pv titleForRow:(NSInteger)row forComponent:(NSInteger)c {
    NSNetService *s = self.services[row];
    return [NSString stringWithFormat:@"%@ (%@)", s.name, s.hostName ?: @"resolving..."];
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

@end
