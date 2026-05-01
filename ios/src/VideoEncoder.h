#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@class VideoEncoder;

@protocol VideoEncoderDelegate <NSObject>
- (void)videoEncoder:(VideoEncoder *)enc didProduceConfigSPS:(NSData *)sps PPS:(NSData *)pps;
- (void)videoEncoder:(VideoEncoder *)enc didProduceFrame:(NSData *)annexB keyframe:(BOOL)keyframe pts:(uint64_t)ptsUs;
@end

@interface VideoEncoder : NSObject

@property (nonatomic, weak) id<VideoEncoderDelegate> delegate;
@property (nonatomic, assign) NSInteger bitrate;          // bps cap; default 800 Kbps
@property (nonatomic, assign) NSInteger keyframeInterval; // frames; default 240
@property (nonatomic, assign) float     quality;          // 0..1 VTQuality; default 0.5

- (BOOL)startWithWidth:(int)w height:(int)h;
- (void)stop;
- (void)encodePixelBuffer:(CVPixelBufferRef)pb pts:(uint64_t)ptsUs;
- (void)forceKeyframe;

@end
