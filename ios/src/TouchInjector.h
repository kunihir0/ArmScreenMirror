#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface TouchInjector : NSObject

@property (nonatomic, assign) CGSize pointSize;  // tamaño lógico (puntos)

- (instancetype)initWithPointSize:(CGSize)size;

- (void)touchDownFinger:(uint8_t)fid atNorm:(CGPoint)p;
- (void)touchMoveFinger:(uint8_t)fid atNorm:(CGPoint)p;
- (void)touchUpFinger:(uint8_t)fid atNorm:(CGPoint)p;

/// Sintetiza un gesto de swipe completo con timing real de 120Hz, timestamps
/// monotónicos y velocidad consistente — todo lo que iOS necesita para que
/// UIScrollView lo reconozca como swipe (no como tap).
- (void)performSwipeFromNorm:(CGPoint)from
                      toNorm:(CGPoint)to
                  durationMs:(uint32_t)durationMs;

- (void)keyDown:(uint16_t)hidUsage;
- (void)keyUp:(uint16_t)hidUsage;
- (void)typeText:(NSString *)s;

- (void)pressButton:(uint8_t)buttonId down:(BOOL)down;

@end
