#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

@class ScreenCapture;

@protocol ScreenCaptureDelegate <NSObject>
- (void)screenCapture:(ScreenCapture *)cap didCaptureBuffer:(CVPixelBufferRef)pb pts:(uint64_t)ptsUs;
@end

@interface ScreenCapture : NSObject

@property (nonatomic, weak) id<ScreenCaptureDelegate> delegate;
@property (nonatomic, readonly) CGSize displaySize;        // píxeles destino codificador (tras escala)
@property (nonatomic, readonly) CGSize nativeDisplaySize;  // resolución nativa física (ej. 1284x2778)
@property (nonatomic, readonly) CGFloat displayScale;      // 2.0/3.0 (pantalla nativa)
@property (nonatomic, readonly) CGSize pointSize;          // tamaño lógico iPhone
@property (nonatomic, assign)   NSInteger fps;             // fps activo
@property (nonatomic, assign)   NSInteger idleFps;         // fps cuando no hay cambios
@property (nonatomic, assign)   CGFloat captureScale;      // factor sobre nativa (0..1). Aplicar antes de start.

@property (nonatomic, readonly) NSUInteger framesCaptured;
@property (nonatomic, readonly) NSUInteger framesBlack;
@property (nonatomic, readonly) NSString  *backendName;
@property (nonatomic, readonly) NSString  *lastError;
@property (nonatomic, readonly) double     avgCaptureTimeMs;
@property (nonatomic, readonly) double     maxCaptureTimeMs;
@property (nonatomic, readonly) double     carAvgMs;
@property (nonatomic, readonly) double     carMaxMs;
@property (nonatomic, readonly) double     scaleAvgMs;
@property (nonatomic, readonly) double     scaleMaxMs;

- (BOOL)start;
- (void)stop;
- (void)resetIntervalTiming;

@end
