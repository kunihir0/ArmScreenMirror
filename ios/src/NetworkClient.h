#import <Foundation/Foundation.h>
#import "Protocol.h"

@class NetworkClient;

@protocol NetworkClientDelegate <NSObject>
- (void)networkClientDidConnect:(NetworkClient *)c;
- (void)networkClient:(NetworkClient *)c didDisconnectWithError:(NSError * _Nullable)err;
- (void)networkClient:(NetworkClient *)c didReceiveType:(SMIRType)type payload:(NSData *)payload;
@end

@interface NetworkClient : NSObject

@property (nonatomic, weak) id<NetworkClientDelegate> delegate;
@property (nonatomic, readonly) BOOL connected;

/// Contraseña usada para derivar la clave de cifrado AES-256-GCM.
/// Debe coincidir con la contraseña en el Mac. Sin contraseña no se conecta.
@property (nonatomic, copy) NSString *password;

- (void)connectToHost:(NSString *)host port:(uint16_t)port;
- (void)disconnect;
- (void)sendType:(SMIRType)type payload:(NSData *)payload;
- (void)startBrowsingBonjour:(void(^)(NSArray<NSNetService *> *))onUpdate;
- (void)stopBrowsing;

@end
