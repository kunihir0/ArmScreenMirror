#import "Crypto.h"
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <Security/Security.h>
#import <dlfcn.h>

// kCCModeGCM = 11. No está declarado en SDK iOS 16+ pero el modo sigue
// soportado en runtime por todas las versiones desde iOS 8.
#ifndef kCCModeGCM
#define kCCModeGCM 11
#endif

// ---- Tipos de los símbolos privados/deprecated que vamos a resolver con dlsym -----

// One-shot (iOS 13+). En iOS 16.7+ devuelve kCCUnimplemented (-4300) en algunos
// dispositivos: por eso lo intentamos pero comprobamos el resultado.
typedef CCCryptorStatus (*GCMOneshotEncryptFn)(
    CCAlgorithm, const void *, size_t,        // alg, key, keyLen
    const void *, size_t,                     // iv, ivLen
    const void *, size_t,                     // aData, aDataLen
    const void *, size_t, void *,             // dataIn, dataInLen, dataOut
    void *, size_t *);                        // tagOut, tagLength

typedef CCCryptorStatus (*GCMOneshotDecryptFn)(
    CCAlgorithm, const void *, size_t,
    const void *, size_t,
    const void *, size_t,
    const void *, size_t, void *,
    const void *, size_t);

// Legacy (iOS 8+). Marcadas deprecated en headers nuevos pero los símbolos
// siguen exportados y operativos hasta iOS 18.
typedef CCCryptorStatus (*GCMSetIVFn)(CCCryptorRef, const void *, size_t);
typedef CCCryptorStatus (*GCMEncryptFn)(CCCryptorRef, const void *, size_t, void *);
typedef CCCryptorStatus (*GCMDecryptFn)(CCCryptorRef, const void *, size_t, void *);
typedef CCCryptorStatus (*GCMFinalFn)(CCCryptorRef, void *, size_t *);

@implementation SMIRCrypto {
    uint64_t _sendCtr;
    uint64_t _recvCtr;

    GCMOneshotEncryptFn _fnOneEnc;
    GCMOneshotDecryptFn _fnOneDec;
    GCMSetIVFn          _fnSetIV;
    GCMEncryptFn        _fnLegacyEnc;
    GCMDecryptFn        _fnLegacyDec;
    GCMFinalFn          _fnLegacyFinal;
}

+ (NSData *)randomBytes:(NSUInteger)len {
    NSMutableData *d = [NSMutableData dataWithLength:len];
    int r = SecRandomCopyBytes(kSecRandomDefault, len, d.mutableBytes);
    return r == errSecSuccess ? d : nil;
}

+ (NSData *)pbkdf2WithPassword:(NSString *)password
                          salt:(NSData *)salt
                    iterations:(uint32_t)iter
                      keyBytes:(NSUInteger)len
{
    if (!password || password.length == 0 || !salt || len == 0) return nil;
    NSData *pwd = [password dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *out = [NSMutableData dataWithLength:len];
    // SHA-512 + 600k iters: la PRF SHA-512 es más cara para GPUs/ASICs que
    // SHA-256, y 600 000 está alineado con la recomendación actual de OWASP.
    int r = CCKeyDerivationPBKDF(kCCPBKDF2,
                                 pwd.bytes, pwd.length,
                                 salt.bytes, salt.length,
                                 kCCPRFHmacAlgSHA512, iter,
                                 out.mutableBytes, len);
    return r == kCCSuccess ? [out copy] : nil;
}

+ (NSData *)hkdfSHA256WithIKM:(NSData *)ikm
                          salt:(NSData *)salt
                          info:(NSData *)info
                        length:(NSUInteger)len
{
    if (!ikm || len == 0) return nil;
    if (len > 255 * CC_SHA256_DIGEST_LENGTH) return nil;

    // HKDF-Extract: PRK = HMAC-SHA256(salt, IKM)
    uint8_t prk[CC_SHA256_DIGEST_LENGTH];
    const void *saltBytes = salt.bytes;
    size_t saltLen = salt.length;
    uint8_t zeroSalt[CC_SHA256_DIGEST_LENGTH] = {0};
    if (!saltBytes || saltLen == 0) {
        saltBytes = zeroSalt; saltLen = sizeof(zeroSalt);
    }
    CCHmac(kCCHmacAlgSHA256, saltBytes, saltLen, ikm.bytes, ikm.length, prk);

    // HKDF-Expand: T(i) = HMAC(PRK, T(i-1) || info || i)
    NSMutableData *out = [NSMutableData dataWithCapacity:len];
    uint8_t T[CC_SHA256_DIGEST_LENGTH] = {0};
    size_t T_len = 0;
    for (uint8_t i = 1; out.length < len; i++) {
        CCHmacContext ctx;
        CCHmacInit(&ctx, kCCHmacAlgSHA256, prk, sizeof(prk));
        if (T_len) CCHmacUpdate(&ctx, T, T_len);
        if (info.length) CCHmacUpdate(&ctx, info.bytes, info.length);
        CCHmacUpdate(&ctx, &i, 1);
        CCHmacFinal(&ctx, T);
        T_len = CC_SHA256_DIGEST_LENGTH;
        NSUInteger remaining = len - out.length;
        NSUInteger take = remaining < T_len ? remaining : T_len;
        [out appendBytes:T length:take];
    }
    // Limpia memoria
    memset(prk, 0, sizeof(prk));
    memset(T, 0, sizeof(T));
    return [out copy];
}

static void counterToIV(uint64_t ctr, uint8_t iv[12]) {
    iv[0] = iv[1] = iv[2] = iv[3] = 0;
    for (int i = 0; i < 8; i++) {
        iv[4 + i] = (uint8_t)((ctr >> ((7 - i) * 8)) & 0xFFu);
    }
}

- (instancetype)init {
    if ((self = [super init])) {
        _backend = SMIRCryptoBackendUnknown;

        // Resolvemos los símbolos en RTLD_DEFAULT — estarán enlazados desde
        // la libCommonCrypto del sistema cuando la app cargue.
        _fnOneEnc      = dlsym(RTLD_DEFAULT, "CCCryptorGCMOneshotEncrypt");
        _fnOneDec      = dlsym(RTLD_DEFAULT, "CCCryptorGCMOneshotDecrypt");
        _fnSetIV       = dlsym(RTLD_DEFAULT, "CCCryptorGCMSetIV");
        _fnLegacyEnc   = dlsym(RTLD_DEFAULT, "CCCryptorGCMEncrypt");
        _fnLegacyDec   = dlsym(RTLD_DEFAULT, "CCCryptorGCMDecrypt");
        _fnLegacyFinal = dlsym(RTLD_DEFAULT, "CCCryptorGCMFinal");

        // Detección por sondeo: hacemos un encrypt+decrypt con clave conocida
        // contra cada API y elegimos la que dé roundtrip correcto.
        [self _detectBackend];

        NSLog(@"[Crypto] backend disponible: %@ (oneEnc=%p oneDec=%p legacy={SetIV=%p Enc=%p Dec=%p Final=%p})",
              self.backendName,
              _fnOneEnc, _fnOneDec, _fnSetIV, _fnLegacyEnc, _fnLegacyDec, _fnLegacyFinal);
    }
    return self;
}

- (NSString *)backendName {
    switch (_backend) {
        case SMIRCryptoBackendGCMOneshot:  return @"AES-GCM (CCCryptorGCMOneshot, iOS 13+ moderno)";
        case SMIRCryptoBackendGCMLegacy:   return @"AES-GCM (CCCryptorGCMSetIV legacy, iOS 8+)";
        case SMIRCryptoBackendUnavailable: return @"NO DISPONIBLE";
        default:                           return @"sin detectar";
    }
}

#pragma mark - Detección de backend disponible

- (void)_detectBackend {
    // Vector de prueba con clave/IV conocidos. Hacemos encrypt+decrypt
    // y verificamos roundtrip.
    static const uint8_t testKey[32] = {
        0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
        0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,
        0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,
        0x18,0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,
    };
    static const uint8_t testIV[12] = {0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b};
    static const uint8_t testPlain[24] = "ScreenMirrorProbe-2026!";

    NSData *keyData = [NSData dataWithBytes:testKey length:sizeof(testKey)];

    // Probamos OneShot primero (más moderna y rápida si funciona).
    if (_fnOneEnc && _fnOneDec) {
        if ([self _probeWithKey:keyData iv:testIV plain:testPlain plainLen:sizeof(testPlain)
                          using:SMIRCryptoBackendGCMOneshot]) {
            _backend = SMIRCryptoBackendGCMOneshot;
            return;
        }
    }
    // Fallback: legacy.
    if (_fnSetIV && _fnLegacyEnc && _fnLegacyDec && _fnLegacyFinal) {
        if ([self _probeWithKey:keyData iv:testIV plain:testPlain plainLen:sizeof(testPlain)
                          using:SMIRCryptoBackendGCMLegacy]) {
            _backend = SMIRCryptoBackendGCMLegacy;
            return;
        }
    }
    _backend = SMIRCryptoBackendUnavailable;
}

- (BOOL)_probeWithKey:(NSData *)key
                   iv:(const uint8_t *)iv
                plain:(const uint8_t *)plain
             plainLen:(size_t)plainLen
                using:(SMIRCryptoBackend)be
{
    NSMutableData *cipher = [NSMutableData dataWithLength:plainLen + 16];
    BOOL ok = NO;
    if (be == SMIRCryptoBackendGCMOneshot) {
        ok = [self _gcmOneshotEncrypt:plain plainLen:plainLen iv:iv
                                  key:key
                                  out:cipher.mutableBytes];
    } else if (be == SMIRCryptoBackendGCMLegacy) {
        ok = [self _gcmLegacyEncrypt:plain plainLen:plainLen iv:iv
                                 key:key
                                 out:cipher.mutableBytes];
    }
    if (!ok) return NO;

    NSMutableData *roundtrip = [NSMutableData dataWithLength:plainLen];
    if (be == SMIRCryptoBackendGCMOneshot) {
        ok = [self _gcmOneshotDecrypt:cipher.bytes ctLen:plainLen
                                  tag:(const uint8_t *)cipher.bytes + plainLen
                                   iv:iv
                                  key:key
                                  out:roundtrip.mutableBytes];
    } else {
        ok = [self _gcmLegacyDecrypt:cipher.bytes ctLen:plainLen
                                 tag:(const uint8_t *)cipher.bytes + plainLen
                                  iv:iv
                                 key:key
                                 out:roundtrip.mutableBytes];
    }
    if (!ok) return NO;

    return memcmp(roundtrip.bytes, plain, plainLen) == 0;
}

#pragma mark - Backends raw

- (BOOL)_gcmOneshotEncrypt:(const void *)plain plainLen:(size_t)plainLen
                        iv:(const uint8_t *)iv
                       key:(NSData *)key
                       out:(uint8_t *)out
{
    size_t tagLen = 16;
    CCCryptorStatus s = _fnOneEnc(kCCAlgorithmAES,
                                  key.bytes, key.length,
                                  iv, 12,
                                  NULL, 0,
                                  plain, plainLen, out,
                                  out + plainLen, &tagLen);
    return s == kCCSuccess && tagLen == 16;
}

- (BOOL)_gcmOneshotDecrypt:(const void *)ct ctLen:(size_t)ctLen
                       tag:(const uint8_t *)tag
                        iv:(const uint8_t *)iv
                       key:(NSData *)key
                       out:(uint8_t *)out
{
    CCCryptorStatus s = _fnOneDec(kCCAlgorithmAES,
                                  key.bytes, key.length,
                                  iv, 12,
                                  NULL, 0,
                                  ct, ctLen, out,
                                  tag, 16);
    return s == kCCSuccess;
}

- (BOOL)_gcmLegacyEncrypt:(const void *)plain plainLen:(size_t)plainLen
                       iv:(const uint8_t *)iv
                      key:(NSData *)key
                      out:(uint8_t *)out
{
    CCCryptorRef cryptor = NULL;
    CCCryptorStatus s = CCCryptorCreateWithMode(kCCEncrypt, kCCModeGCM, kCCAlgorithmAES,
                                                ccNoPadding,
                                                NULL,
                                                key.bytes, key.length,
                                                NULL, 0, 0, 0, &cryptor);
    if (s != kCCSuccess || !cryptor) return NO;
    s = _fnSetIV(cryptor, iv, 12);
    if (s != kCCSuccess) { CCCryptorRelease(cryptor); return NO; }
    s = _fnLegacyEnc(cryptor, plain, plainLen, out);
    if (s != kCCSuccess) { CCCryptorRelease(cryptor); return NO; }
    size_t tagLen = 16;
    s = _fnLegacyFinal(cryptor, out + plainLen, &tagLen);
    CCCryptorRelease(cryptor);
    return s == kCCSuccess && tagLen == 16;
}

- (BOOL)_gcmLegacyDecrypt:(const void *)ct ctLen:(size_t)ctLen
                      tag:(const uint8_t *)tag
                       iv:(const uint8_t *)iv
                      key:(NSData *)key
                      out:(uint8_t *)out
{
    CCCryptorRef cryptor = NULL;
    CCCryptorStatus s = CCCryptorCreateWithMode(kCCDecrypt, kCCModeGCM, kCCAlgorithmAES,
                                                ccNoPadding,
                                                NULL,
                                                key.bytes, key.length,
                                                NULL, 0, 0, 0, &cryptor);
    if (s != kCCSuccess || !cryptor) return NO;
    s = _fnSetIV(cryptor, iv, 12);
    if (s != kCCSuccess) { CCCryptorRelease(cryptor); return NO; }
    s = _fnLegacyDec(cryptor, ct, ctLen, out);
    if (s != kCCSuccess) { CCCryptorRelease(cryptor); return NO; }
    uint8_t computedTag[16];
    size_t tagLen = 16;
    s = _fnLegacyFinal(cryptor, computedTag, &tagLen);
    CCCryptorRelease(cryptor);
    if (s != kCCSuccess || tagLen != 16) return NO;
    // Comparación constante
    uint8_t diff = 0;
    for (int i = 0; i < 16; i++) diff |= computedTag[i] ^ tag[i];
    return diff == 0;
}

#pragma mark - API pública (encrypt / decrypt)

- (NSData *)encrypt:(NSData *)plaintext {
    if (_backend == SMIRCryptoBackendUnavailable) return nil;
    if (!_key || _key.length != 32 || !plaintext) return nil;

    uint8_t iv[12];
    counterToIV(_sendCtr, iv);

    NSMutableData *out = [NSMutableData dataWithLength:plaintext.length + 16];
    BOOL ok = NO;
    if (_backend == SMIRCryptoBackendGCMOneshot) {
        ok = [self _gcmOneshotEncrypt:plaintext.bytes plainLen:plaintext.length
                                   iv:iv key:_key out:out.mutableBytes];
    } else if (_backend == SMIRCryptoBackendGCMLegacy) {
        ok = [self _gcmLegacyEncrypt:plaintext.bytes plainLen:plaintext.length
                                  iv:iv key:_key out:out.mutableBytes];
    }
    if (!ok) return nil;
    _sendCtr++;
    return [out copy];
}

- (NSData *)decrypt:(NSData *)data {
    if (_backend == SMIRCryptoBackendUnavailable) return nil;
    if (!_key || _key.length != 32 || data.length < 16) return nil;

    NSUInteger ctLen = data.length - 16;
    const uint8_t *ct  = data.bytes;
    const uint8_t *tag = (const uint8_t *)data.bytes + ctLen;

    uint8_t iv[12];
    counterToIV(_recvCtr, iv);

    NSMutableData *out = [NSMutableData dataWithLength:ctLen];
    BOOL ok = NO;
    if (_backend == SMIRCryptoBackendGCMOneshot) {
        ok = [self _gcmOneshotDecrypt:ct ctLen:ctLen tag:tag
                                   iv:iv key:_key out:out.mutableBytes];
    } else if (_backend == SMIRCryptoBackendGCMLegacy) {
        ok = [self _gcmLegacyDecrypt:ct ctLen:ctLen tag:tag
                                  iv:iv key:_key out:out.mutableBytes];
    }
    if (!ok) return nil;
    _recvCtr++;
    return [out copy];
}

@end
