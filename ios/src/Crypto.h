#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Wrapper sobre CommonCrypto para AES-256-GCM + PBKDF2-SHA256.
/// Mantiene contadores monotónicos para usar como IV — no es necesario
/// transmitirlos porque ambos extremos los siguen en paralelo (TCP garantiza
/// orden, así que el contador del receptor coincide con el del emisor).
typedef NS_ENUM(uint8_t, SMIRCryptoBackend) {
    SMIRCryptoBackendUnknown     = 0,
    SMIRCryptoBackendGCMOneshot  = 1,   // CCCryptorGCMOneshotEncrypt (iOS 13+, salvo stubs)
    SMIRCryptoBackendGCMLegacy   = 2,   // CCCryptorGCMSetIV/Encrypt/Final (iOS 8+)
    SMIRCryptoBackendUnavailable = 3,
};

@interface SMIRCrypto : NSObject

@property (nonatomic, copy, nullable) NSData *key;   // 32 bytes (AES-256)
@property (nonatomic, readonly) uint64_t sendCounter;
@property (nonatomic, readonly) uint64_t recvCounter;
@property (nonatomic, readonly) SMIRCryptoBackend backend;
@property (nonatomic, readonly) NSString *backendName;

- (nullable NSData *)encrypt:(NSData *)plaintext;
- (nullable NSData *)decrypt:(NSData *)cipherWithTag;

+ (NSData *)randomBytes:(NSUInteger)len;
+ (nullable NSData *)pbkdf2WithPassword:(NSString *)password
                                    salt:(NSData *)salt
                              iterations:(uint32_t)iterations
                                keyBytes:(NSUInteger)keyBytes;

/// HKDF-SHA256: extrae+expande una clave de longitud arbitraria a partir de
/// material de entrada arbitrario (ikm) + salt + info contextual.
+ (nullable NSData *)hkdfSHA256WithIKM:(NSData *)ikm
                                  salt:(NSData *)salt
                                  info:(NSData *)info
                                length:(NSUInteger)length;

@end

NS_ASSUME_NONNULL_END
