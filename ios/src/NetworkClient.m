#import "NetworkClient.h"
#import "Crypto.h"
#import "X25519.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <fcntl.h>
#import <unistd.h>

// HELLO v2: "SMIH" + ver=2 + flags + 2 reserved + 16 nonce + 32 X25519 pubkey
#define SMIR_HELLO_MAGIC  0x534D4948u  // 'SMIH'
#define SMIR_HELLO_LEN    56
#define SMIR_PROTO_VER    2
#define SMIR_NONCE_LEN    16
#define SMIR_X25519_LEN   32
#define SMIR_PBKDF2_ITERS 600000u

typedef enum : uint8_t {
    NetStateIdle = 0,
    NetStateAwaitingHelloResponse,   // mandé hello, espero los 24 bytes del Mac
    NetStateEncrypted,               // auth completa, mensajes cifrados
} NetState;

@interface NetworkClient () <NSStreamDelegate, NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@end

@implementation NetworkClient {
    NSInputStream  *_in;
    NSOutputStream *_out;
    NSMutableData  *_writeBuf;
    NSMutableData  *_readBuf;
    BOOL _hasSpace;

    NetState        _state;
    NSData         *_clientNonce;   // generado por nosotros al conectar
    uint8_t         _ephPriv[32];   // X25519 privada efímera (se borra al final del handshake)
    uint8_t         _ephPub[32];    // X25519 pública correspondiente
    SMIRCrypto     *_crypto;

    NSNetServiceBrowser *_browser;
    NSMutableArray<NSNetService *> *_services;
    void (^_onUpdate)(NSArray<NSNetService *> *);
}

- (instancetype)init {
    if ((self = [super init])) {
        _writeBuf = [NSMutableData data];
        _readBuf  = [NSMutableData data];
        _state    = NetStateIdle;
    }
    return self;
}

// Helper: garantiza que llamamos al main thread.
static inline void run_on_main(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

- (BOOL)connected { return _state == NetStateEncrypted; }

- (void)connectToHost:(NSString *)host port:(uint16_t)port {
    [self disconnect];

    if (_password.length == 0) {
        NSLog(@"[Net] sin contraseña — abortando conexión");
        [self.delegate networkClient:self didDisconnectWithError:
            [NSError errorWithDomain:@"smir" code:-2
                            userInfo:@{NSLocalizedDescriptionKey:@"Falta password en /var/jb/etc/screenmirror.conf"}]];
        return;
    }

    CFReadStreamRef  rs = NULL;
    CFWriteStreamRef ws = NULL;
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)host, port, &rs, &ws);
    if (!rs || !ws) {
        [self.delegate networkClient:self didDisconnectWithError:
            [NSError errorWithDomain:@"smir" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"CFStreamCreatePair failed"}]];
        return;
    }

    _in  = CFBridgingRelease(rs);
    _out = CFBridgingRelease(ws);
    _in.delegate  = self;
    _out.delegate = self;
    [_in  scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_out scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    _clientNonce = [SMIRCrypto randomBytes:SMIR_NONCE_LEN];
    smir_x25519_make_priv(_ephPriv);
    smir_x25519_pub_from_priv(_ephPub, _ephPriv);
    _state = NetStateAwaitingHelloResponse;
    [self _enqueueHello];

    [_in  open];
    [_out open];
}

- (void)_enqueueHello {
    // HELLO v2: 'SMIH' + ver + flags + 2 reserved + 16 nonce + 32 X25519 pub.
    NSMutableData *hello = [NSMutableData dataWithCapacity:SMIR_HELLO_LEN];
    uint32_t magic = CFSwapInt32HostToBig(SMIR_HELLO_MAGIC);
    [hello appendBytes:&magic length:4];
    // flags=2 = forward-secrecy + password-auth
    uint8_t header[4] = { SMIR_PROTO_VER, /*flags*/ 2, 0, 0 };
    [hello appendBytes:header length:4];
    [hello appendData:_clientNonce];
    [hello appendBytes:_ephPub length:SMIR_X25519_LEN];
    NSAssert(hello.length == SMIR_HELLO_LEN, @"hello size");

    run_on_main(^{
        [self->_writeBuf appendData:hello];
        [self _drainWrite];
    });
}

- (void)disconnect {
    if (_in)  { [_in  close]; [_in  removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes]; _in = nil; }
    if (_out) { [_out close]; [_out removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes]; _out = nil; }
    [_writeBuf setLength:0];
    [_readBuf setLength:0];
    _state = NetStateIdle;
    _hasSpace = NO;
    _crypto = nil;
    _clientNonce = nil;
}

- (void)sendType:(SMIRType)type payload:(NSData *)payload {
    if (_state != NetStateEncrypted || !_crypto) return;

    // Mensaje plano: cabecera SMIR estándar + payload.
    SMIRHeader h = { 0 };
    h.magic  = CFSwapInt32HostToBig(SMIR_MAGIC);
    h.type   = (uint8_t)type;
    h.length = CFSwapInt32HostToBig((uint32_t)payload.length);

    NSMutableData *plain = [NSMutableData dataWithBytes:&h length:sizeof(h)];
    if (payload.length) [plain appendData:payload];

    NSData *encrypted = [_crypto encrypt:plain];
    if (!encrypted) {
        NSLog(@"[Net] encrypt failed");
        return;
    }

    uint32_t lenBE = CFSwapInt32HostToBig((uint32_t)encrypted.length);
    NSMutableData *wire = [NSMutableData dataWithCapacity:4 + encrypted.length];
    [wire appendBytes:&lenBE length:4];
    [wire appendData:encrypted];

    run_on_main(^{
        [self->_writeBuf appendData:wire];
        [self _drainWrite];
    });
}

- (void)_drainWrite {
    if (!_out || _writeBuf.length == 0) return;
    while (_writeBuf.length > 0 && [_out hasSpaceAvailable]) {
        NSInteger n = [_out write:_writeBuf.bytes maxLength:_writeBuf.length];
        if (n <= 0) break;
        [_writeBuf replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
    }
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
    switch (event) {
        case NSStreamEventOpenCompleted:
            // Se notifica el "connected" SOLO al completarse la auth.
            break;

        case NSStreamEventHasSpaceAvailable:
            _hasSpace = YES;
            [self _drainWrite];
            break;

        case NSStreamEventHasBytesAvailable: {
            uint8_t buf[16384];
            NSInteger n = [(NSInputStream *)stream read:buf maxLength:sizeof(buf)];
            if (n > 0) {
                [_readBuf appendBytes:buf length:n];
                [self _parseInbound];
            }
            break;
        }

        case NSStreamEventErrorOccurred:
        case NSStreamEventEndEncountered: {
            NSError *err = stream.streamError;
            BOOL was = (_state != NetStateIdle);
            [self disconnect];
            if (was) [self.delegate networkClient:self didDisconnectWithError:err];
            break;
        }

        default: break;
    }
}

- (void)_parseInbound {
    while (1) {
        if (_state == NetStateAwaitingHelloResponse) {
            if (_readBuf.length < SMIR_HELLO_LEN) return;
            uint32_t magic;
            memcpy(&magic, _readBuf.bytes, 4);
            magic = CFSwapInt32BigToHost(magic);
            if (magic != SMIR_HELLO_MAGIC) {
                NSLog(@"[Net] hello magic mismatch");
                [self disconnect];
                [self.delegate networkClient:self didDisconnectWithError:
                    [NSError errorWithDomain:@"smir" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"Protocolo incompatible"}]];
                return;
            }
            uint8_t serverVer = ((const uint8_t *)_readBuf.bytes)[4];
            if (serverVer != SMIR_PROTO_VER) {
                NSLog(@"[Net] versión protocolo distinta: server=%u local=%u", serverVer, SMIR_PROTO_VER);
                [self disconnect];
                [self.delegate networkClient:self didDisconnectWithError:
                    [NSError errorWithDomain:@"smir" code:-5 userInfo:@{NSLocalizedDescriptionKey:@"Versión protocolo incompatible"}]];
                return;
            }
            NSData *serverNonce = [_readBuf subdataWithRange:NSMakeRange(8, SMIR_NONCE_LEN)];
            uint8_t peerPub[SMIR_X25519_LEN];
            [_readBuf getBytes:peerPub range:NSMakeRange(8 + SMIR_NONCE_LEN, SMIR_X25519_LEN)];
            [_readBuf replaceBytesInRange:NSMakeRange(0, SMIR_HELLO_LEN) withBytes:NULL length:0];

            // 1) ECDHE ephemeral key agreement (forward secrecy):
            uint8_t shared[32];
            int ok = smir_x25519_scalarmult(shared, _ephPriv, peerPub);
            // Borramos la privada efímera ya — si nos comprometen luego no
            // pueden recuperar shared retroactivamente.
            memset(_ephPriv, 0, sizeof(_ephPriv));
            if (!ok) {
                NSLog(@"[Net] X25519 punto inválido — abortando");
                memset(shared, 0, sizeof(shared));
                [self disconnect];
                return;
            }

            // 2) Derivación con password (PBKDF2-SHA512 600k):
            NSMutableData *salt = [NSMutableData dataWithCapacity:32];
            [salt appendData:_clientNonce];
            [salt appendData:serverNonce];
            NSData *pwdKDF = [SMIRCrypto pbkdf2WithPassword:_password
                                                       salt:salt
                                                 iterations:SMIR_PBKDF2_ITERS
                                                   keyBytes:32];
            if (!pwdKDF) {
                NSLog(@"[Net] PBKDF2 falló");
                memset(shared, 0, sizeof(shared));
                [self disconnect];
                return;
            }

            // 3) HKDF-SHA256: combina ECDHE + password en clave de sesión:
            NSMutableData *ikm = [NSMutableData dataWithBytes:shared length:32];
            [ikm appendData:pwdKDF];
            memset(shared, 0, sizeof(shared));
            NSData *info = [@"SMIR-session-key-v2" dataUsingEncoding:NSUTF8StringEncoding];
            NSData *sessionKey = [SMIRCrypto hkdfSHA256WithIKM:ikm salt:salt info:info length:32];
            if (!sessionKey) {
                NSLog(@"[Net] HKDF falló");
                [self disconnect];
                return;
            }

            _crypto = [[SMIRCrypto alloc] init];
            _crypto.key = sessionKey;
            _state = NetStateEncrypted;
            const uint8_t *pk = pwdKDF.bytes;
            const uint8_t *sk = sessionKey.bytes;
            const uint8_t *st = salt.bytes;
            NSString *dbgLine = [NSString stringWithFormat:
                @"DBG pwd.utf8=%lu pwdKDF=%02x%02x%02x%02x sharedFP=%02x%02x%02x%02x sessKey=%02x%02x%02x%02x salt=%02x%02x%02x%02x pwd1stChar=%02x\n",
                (unsigned long)[_password lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                pk[0],pk[1],pk[2],pk[3],
                ((uint8_t*)ikm.bytes)[0],((uint8_t*)ikm.bytes)[1],((uint8_t*)ikm.bytes)[2],((uint8_t*)ikm.bytes)[3],
                sk[0],sk[1],sk[2],sk[3],
                st[0],st[1],st[2],st[3],
                _password.length > 0 ? [_password characterAtIndex:0] : 0];
            [[dbgLine dataUsingEncoding:NSUTF8StringEncoding]
                writeToFile:@"/var/mobile/Library/Preferences/com.example.screenmirror.dbg.log" atomically:YES];
            NSLog(@"[Net] %@", dbgLine);
            NSLog(@"[Net] auth completada — canal cifrado: %@ (FS: X25519 ephemeral)", _crypto.backendName);
            [self.delegate networkClientDidConnect:self];
        } else if (_state == NetStateEncrypted) {
            if (_readBuf.length < 4) return;
            uint32_t lenBE; memcpy(&lenBE, _readBuf.bytes, 4);
            uint32_t total = CFSwapInt32BigToHost(lenBE);
            if (total > 16 * 1024 * 1024) {  // sanity check 16MB max
                NSLog(@"[Net] frame demasiado grande %u — abortando", total);
                [self disconnect];
                return;
            }
            if (_readBuf.length < 4 + total) return;
            NSData *enc = [_readBuf subdataWithRange:NSMakeRange(4, total)];
            [_readBuf replaceBytesInRange:NSMakeRange(0, 4 + total) withBytes:NULL length:0];

            NSData *plain = [_crypto decrypt:enc];
            if (!plain) {
                NSLog(@"[Net] decrypt falló — contraseña incorrecta o corrupción");
                [self disconnect];
                [self.delegate networkClient:self didDisconnectWithError:
                    [NSError errorWithDomain:@"smir" code:-4 userInfo:@{NSLocalizedDescriptionKey:@"Contraseña incorrecta"}]];
                return;
            }
            if (plain.length < sizeof(SMIRHeader)) continue;
            SMIRHeader h; memcpy(&h, plain.bytes, sizeof(h));
            uint32_t pmagic = CFSwapInt32BigToHost(h.magic);
            uint32_t plen   = CFSwapInt32BigToHost(h.length);
            if (pmagic != SMIR_MAGIC) continue;
            if (plain.length < sizeof(SMIRHeader) + plen) continue;
            NSData *payload = [plain subdataWithRange:NSMakeRange(sizeof(SMIRHeader), plen)];
            [self.delegate networkClient:self didReceiveType:(SMIRType)h.type payload:payload];
        } else {
            return;
        }
    }
}

#pragma mark - Bonjour

- (void)startBrowsingBonjour:(void(^)(NSArray<NSNetService *> *))onUpdate {
    [self stopBrowsing];
    _services = [NSMutableArray array];
    _onUpdate = [onUpdate copy];
    _browser = [[NSNetServiceBrowser alloc] init];
    _browser.delegate = self;
    [_browser searchForServicesOfType:@"_smirror._tcp." inDomain:@"local."];
}

- (void)stopBrowsing {
    [_browser stop];
    _browser = nil;
    _services = nil;
    _onUpdate = nil;
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)b didFindService:(NSNetService *)svc moreComing:(BOOL)more {
    svc.delegate = self;
    [svc resolveWithTimeout:5];
    [_services addObject:svc];
    if (!more && _onUpdate) _onUpdate([_services copy]);
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)b didRemoveService:(NSNetService *)svc moreComing:(BOOL)more {
    [_services removeObject:svc];
    if (!more && _onUpdate) _onUpdate([_services copy]);
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    if (_onUpdate) _onUpdate([_services copy]);
}

@end
