#import "VideoEncoder.h"
#import <VideoToolbox/VideoToolbox.h>

@implementation VideoEncoder {
    VTCompressionSessionRef _session;
    int _w, _h;
    BOOL _sentConfig;
    BOOL _forceKey;
}

- (instancetype)init {
    if ((self = [super init])) {
        _bitrate = 1500 * 1000;
        _keyframeInterval = 120;
        _quality = 0.5f;
        _fps = 30;
    }
    return self;
}

- (void)dealloc { [self stop]; }

static void EncoderCallback(void *outputCallbackRefCon,
                            void *sourceFrameRefCon,
                            OSStatus status,
                            VTEncodeInfoFlags infoFlags,
                            CMSampleBufferRef sb)
{
    VideoEncoder *self_ = (__bridge VideoEncoder *)outputCallbackRefCon;
    if (status != noErr || !sb || !CMSampleBufferDataIsReady(sb)) return;
    [self_ _handleSampleBuffer:sb];
}

- (BOOL)startWithWidth:(int)w height:(int)h {
    return [self startWithWidth:w height:h fps:_fps > 0 ? _fps : 30];
}

- (BOOL)startWithWidth:(int)w height:(int)h fps:(NSInteger)fps {
    [self stop];
    _w = w; _h = h;
    _fps = fps > 0 ? fps : 30;
    _sentConfig = NO;

    NSDictionary *src = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    OSStatus s = VTCompressionSessionCreate(
        kCFAllocatorDefault, w, h,
        kCMVideoCodecType_H264,
        NULL, (__bridge CFDictionaryRef)src, NULL,
        EncoderCallback, (__bridge void *)self,
        &_session);
    NSLog(@"[VideoEncoder] VTCompressionSessionCreate w=%d h=%d fps=%ld s=%d session=%p", w, h, (long)_fps, (int)s, _session);
    if (s != noErr) {
        return NO;
    }

    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);

    // Quality-mode (0..1) configurable por preset.
    float quality = _quality;
    CFNumberRef ql = CFNumberCreate(NULL, kCFNumberFloatType, &quality);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_Quality, ql);
    CFRelease(ql);

    int bitrate = (int)_bitrate;
    CFNumberRef br = CFNumberCreate(NULL, kCFNumberIntType, &bitrate);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, br);
    CFRelease(br);

    int kfi = (int)_keyframeInterval;
    CFNumberRef kn = CFNumberCreate(NULL, kCFNumberIntType, &kfi);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, kn);
    CFRelease(kn);

    int fpsVal = (int)_fps;
    CFNumberRef fr = CFNumberCreate(NULL, kCFNumberIntType, &fpsVal);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate, fr);
    CFRelease(fr);

    // Latencia mínima: 0 frames de delay.
    int maxFrameDelay = 0;
    CFNumberRef md = CFNumberCreate(NULL, kCFNumberIntType, &maxFrameDelay);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxFrameDelayCount, md);
    CFRelease(md);

    VTCompressionSessionPrepareToEncodeFrames(_session);
    return YES;
}

- (void)stop {
    if (_session) {
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
}

- (void)forceKeyframe { _forceKey = YES; }

- (void)encodePixelBuffer:(CVPixelBufferRef)pb pts:(uint64_t)ptsUs {
    if (!_session || !pb) {
        static int s_dropped = 0;
        if (++s_dropped < 5) NSLog(@"[VideoEncoder] drop session=%p pb=%p", _session, pb);
        return;
    }
    CMTime pts = CMTimeMake((int64_t)ptsUs, 1000000);
    int32_t fpsVal = (int32_t)(_fps > 0 ? _fps : 30);
    CMTime dur = CMTimeMake(1, fpsVal);
    NSDictionary *frameProps = nil;
    if (_forceKey) {
        frameProps = @{ (id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES };
        _forceKey = NO;
    }
    OSStatus r = VTCompressionSessionEncodeFrame(_session, pb, pts, dur,
        (__bridge CFDictionaryRef)frameProps, NULL, NULL);
    if (r != noErr) {
        static int s_err = 0;
        if (++s_err <= 5)
            NSLog(@"[VideoEncoder] encode err=%d pb=%p (%zux%zu)",
                  (int)r, pb, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb));
    }
}

- (void)_handleSampleBuffer:(CMSampleBufferRef)sb {
    BOOL keyframe = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(attachments, 0);
        keyframe = !CFDictionaryContainsKey(d, kCMSampleAttachmentKey_NotSync);
    }

    if (keyframe && !_sentConfig) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
        size_t spsSize = 0, spsCount = 0;
        const uint8_t *spsPtr = NULL;
        size_t ppsSize = 0, ppsCount = 0;
        const uint8_t *ppsPtr = NULL;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &spsPtr, &spsSize, &spsCount, NULL) == noErr &&
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &ppsPtr, &ppsSize, &ppsCount, NULL) == noErr) {
            NSData *sps = [NSData dataWithBytes:spsPtr length:spsSize];
            NSData *pps = [NSData dataWithBytes:ppsPtr length:ppsSize];
            [self.delegate videoEncoder:self didProduceConfigSPS:sps PPS:pps];
            _sentConfig = YES;
        }
    }

    // Convertir AVCC -> Annex-B
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t totalLen = 0;
    char *dataPtr = NULL;
    if (CMBlockBufferGetDataPointer(bb, 0, NULL, &totalLen, &dataPtr) != noErr) return;

    NSMutableData *out = [NSMutableData dataWithCapacity:totalLen + 64];
    static const uint8_t startCode[4] = {0,0,0,1};
    size_t offset = 0;
    while (offset < totalLen - 4) {
        uint32_t naluLen = 0;
        memcpy(&naluLen, dataPtr + offset, 4);
        naluLen = CFSwapInt32BigToHost(naluLen);
        if (naluLen == 0 || offset + 4 + naluLen > totalLen) break;
        [out appendBytes:startCode length:4];
        [out appendBytes:dataPtr + offset + 4 length:naluLen];
        offset += 4 + naluLen;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    uint64_t ptsUs = (uint64_t)CMTimeGetSeconds(pts) * 1000000ULL;
    [self.delegate videoEncoder:self didProduceFrame:out keyframe:keyframe pts:ptsUs];
}

@end
