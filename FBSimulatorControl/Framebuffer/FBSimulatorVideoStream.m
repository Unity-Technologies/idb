/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSimulatorVideoStream.h"

#import <CoreVideo/CoreVideo.h>
#import <CoreVideo/CVPixelBufferIOSurface.h>
#import <FBControlCore/FBControlCore.h>
#import <IOSurface/IOSurface.h>
#import <VideoToolbox/VideoToolbox.h>

#import "FBSimulatorError.h"

@protocol FBSimulatorVideoStreamFramePusher <NSObject>

- (BOOL)setupWithPixelBuffer:(CVPixelBufferRef)pixelBuffer error:(NSError **)error;
- (BOOL)writeEncodedFrame:(CVPixelBufferRef)pixelBuffer frameNumber:(NSUInteger)frameNumber timeAtFirstFrame:(CFTimeInterval)timeAtFirstFrame error:(NSError **)error;

@end

@interface FBSimulatorVideoStreamFramePusher_Bitmap : NSObject <FBSimulatorVideoStreamFramePusher>

- (instancetype)initWithConsumer:(id<FBDataConsumer>)consumer;

@property (nonatomic, strong, readonly) id<FBDataConsumer> consumer;

@end

@interface FBSimulatorVideoStreamFramePusher_VideoToolbox : NSObject <FBSimulatorVideoStreamFramePusher>

- (instancetype)initWithConfiguration:(FBVideoStreamConfiguration *)configuration compressionSessionProperties:(NSDictionary<NSString *, id> *)compressionSessionProperties videoCodec:(CMVideoCodecType)videoCodec consumer:(id<FBDataConsumer, FBDataConsumerStackConsuming>)consumer compressorCallback:(VTCompressionOutputCallback)compressorCallback logger:(id<FBControlCoreLogger>)logger;

@property (nonatomic, copy, readonly) FBVideoStreamConfiguration *configuration;
@property (nonatomic, assign, nullable, readwrite) VTCompressionSessionRef compressionSession;
@property (nonatomic, assign, readonly) CMVideoCodecType videoCodec;
@property (nonatomic, assign, readonly) VTCompressionOutputCallback compressorCallback;
@property (nonatomic, strong, readonly) id<FBControlCoreLogger> logger;
@property (nonatomic, strong, readonly) id<FBDataConsumer, FBDataConsumerStackConsuming> consumer;
@property (nonatomic, strong, readonly) NSDictionary<NSString *, id> *compressionSessionProperties;

@end

static void H264AnnexBCompressorCallback(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus encodeStats, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
{
  FBSimulatorVideoStreamFramePusher_VideoToolbox *pusher = (__bridge FBSimulatorVideoStreamFramePusher_VideoToolbox *)(outputCallbackRefCon);
  WriteFrameToAnnexBStream(sampleBuffer, pusher.consumer, pusher.logger, nil);
}

static void MJPEGCompressorCallback(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus encodeStats, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
{
  FBSimulatorVideoStreamFramePusher_VideoToolbox *pusher = (__bridge FBSimulatorVideoStreamFramePusher_VideoToolbox *)(outputCallbackRefCon);
  CMBlockBufferRef blockBufffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  WriteJPEGDataToMJPEGStream(blockBufffer, pusher.consumer, pusher.logger, nil);
}

static void MinicapCompressorCallback(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus encodeStats, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
{
  NSUInteger frameNumber = (NSUInteger) sourceFrameRefCon;
  FBSimulatorVideoStreamFramePusher_VideoToolbox *pusher = (__bridge FBSimulatorVideoStreamFramePusher_VideoToolbox *)(outputCallbackRefCon);
  if (frameNumber == 0) {
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    WriteMinicapHeaderToStream((uint32) dimensions.width, (uint32) dimensions.height, pusher.consumer, pusher.logger, nil);
  }
  CMBlockBufferRef blockBufffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  WriteJPEGDataToMinicapStream(blockBufffer, pusher.consumer, pusher.logger, nil);
}

@implementation FBSimulatorVideoStreamFramePusher_Bitmap

- (instancetype)initWithConsumer:(id<FBDataConsumer>)consumer
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _consumer = consumer;

  return self;
}

- (BOOL)setupWithPixelBuffer:(CVPixelBufferRef)pixelBuffer error:(NSError **)error
{
  return YES;
}

- (BOOL)writeEncodedFrame:(CVPixelBufferRef)pixelBuffer frameNumber:(NSUInteger)frameNumber timeAtFirstFrame:(CFTimeInterval)timeAtFirstFrame error:(NSError **)error
{
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
  size_t size = CVPixelBufferGetDataSize(pixelBuffer);
  NSData *data = [NSData dataWithBytesNoCopy:baseAddress length:size freeWhenDone:NO];
  [self.consumer consumeData:data];

  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  return YES;
}

@end

@implementation FBSimulatorVideoStreamFramePusher_VideoToolbox

- (instancetype)initWithConfiguration:(FBVideoStreamConfiguration *)configuration compressionSessionProperties:(NSDictionary<NSString *, id> *)compressionSessionProperties videoCodec:(CMVideoCodecType)videoCodec consumer:(id<FBDataConsumer, FBDataConsumerStackConsuming>)consumer compressorCallback:(VTCompressionOutputCallback)compressorCallback logger:(id<FBControlCoreLogger>)logger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _configuration = configuration;
  _compressionSessionProperties = compressionSessionProperties;
  _compressorCallback = compressorCallback;
  _consumer = consumer;
  _logger = logger;
  _videoCodec = videoCodec;

  return self;
}

- (BOOL)setupWithPixelBuffer:(CVPixelBufferRef)pixelBuffer error:(NSError **)error
{
  NSDictionary<NSString *, id> * encoderSpecification = @{
    (NSString *) kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES,
  };
  size_t sourceWidth = CVPixelBufferGetWidth(pixelBuffer);
  size_t sourceHeight = CVPixelBufferGetHeight(pixelBuffer);
  int32_t destinationWidth = (int32_t) sourceWidth;
  int32_t destinationHeight = (int32_t) sourceHeight;
  NSDictionary<NSString *, id> *sourceImageBufferAttributes = @{
    (NSString *) kCVPixelBufferWidthKey: @(sourceWidth),
    (NSString *) kCVPixelBufferHeightKey: @(sourceHeight),
  };
  NSNumber *scaleFactor = self.configuration.scaleFactor;
  if (scaleFactor && [scaleFactor isGreaterThan:@0] && [scaleFactor isLessThan:@1]) {
    destinationWidth = (int32_t) floor(scaleFactor.doubleValue * sourceWidth);
    destinationHeight = (int32_t) floor(scaleFactor.doubleValue * sourceHeight);
    [self.logger.info logFormat:@"Applying %@ scale from w=%zu/h=%zu to w=%d/h=%d", scaleFactor, sourceWidth, sourceHeight, destinationWidth, destinationHeight];
  }

  VTCompressionSessionRef compressionSession = NULL;
  OSStatus status = VTCompressionSessionCreate(
    nil, // Allocator
    destinationWidth,
    destinationHeight,
    self.videoCodec,
    (__bridge CFDictionaryRef) encoderSpecification,
    (__bridge CFDictionaryRef) sourceImageBufferAttributes,
    nil, // Compressed Data Allocator
    self.compressorCallback,
    (__bridge void * _Nullable)(self), // Callback Ref.
    &compressionSession
  );
  if (status != noErr) {
    return [[FBSimulatorError
      describeFormat:@"Failed to start Compression Session %d", status]
      failBool:error];
  }
  status = VTSessionSetProperties(
    compressionSession,
    (__bridge CFDictionaryRef) self.compressionSessionProperties
  );
  if (status != noErr) {
    return [[FBSimulatorError
      describeFormat:@"Failed to set compression session properties %d", status]
      failBool:error];
  }
  status = VTCompressionSessionPrepareToEncodeFrames(compressionSession);
  if (status != noErr) {
    return [[FBSimulatorError
      describeFormat:@"Failed to prepare compression session %d", status]
      failBool:error];
  }
  self.compressionSession = compressionSession;
  return YES;
}

- (BOOL)writeEncodedFrame:(CVPixelBufferRef)pixelBuffer frameNumber:(NSUInteger)frameNumber timeAtFirstFrame:(CFTimeInterval)timeAtFirstFrame error:(NSError **)error
{
  VTCompressionSessionRef compressionSession = self.compressionSession;
  if (!compressionSession) {
    return [[FBControlCoreError
      describeFormat:@"No compression session"]
      failBool:error];
  }

  VTEncodeInfoFlags flags;
  CMTime time = CMTimeMakeWithSeconds(CFAbsoluteTimeGetCurrent() - timeAtFirstFrame, NSEC_PER_SEC);
  OSStatus status = VTCompressionSessionEncodeFrame(
    compressionSession,
    pixelBuffer,
    time,
    kCMTimeInvalid,  // Frame duration
    NULL,  // Frame properties
    (void *) frameNumber,  // Source Frame Reference for callback.
    &flags
  );
  if (status != 0) {
    return [[FBControlCoreError
      describeFormat:@"Failed to compress %d", status]
      failBool:error];
  }
  return YES;
}

@end

@interface FBSimulatorVideoStream_Lazy : FBSimulatorVideoStream

@end

@interface FBSimulatorVideoStream_Eager : FBSimulatorVideoStream

@property (nonatomic, assign, readonly) NSUInteger framesPerSecond;
@property (nonatomic, strong, readwrite) FBDispatchSourceNotifier *timer;

- (instancetype)initWithFramebuffer:(FBFramebuffer *)framebuffer configuration:(FBVideoStreamConfiguration *)configuration framesPerSecond:(NSUInteger)framesPerSecond writeQueue:(dispatch_queue_t)writeQueue logger:(id<FBControlCoreLogger>)logger;

@end

@interface FBSimulatorVideoStream ()

@property (nonatomic, weak, readonly) FBFramebuffer *framebuffer;
@property (nonatomic, copy, readonly) FBVideoStreamConfiguration *configuration;
@property (nonatomic, strong, readonly) dispatch_queue_t writeQueue;
@property (nonatomic, strong, readonly) id<FBControlCoreLogger> logger;
@property (nonatomic, strong, readonly) FBMutableFuture<NSNull *> *startedFuture;
@property (nonatomic, strong, readonly) FBMutableFuture<NSNull *> *stoppedFuture;

@property (nonatomic, assign, nullable, readwrite) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign, readwrite) CFTimeInterval timeAtFirstFrame;
@property (nonatomic, assign, readwrite) NSUInteger frameNumber;
@property (nonatomic, copy, nullable, readwrite) NSDictionary<NSString *, id> *pixelBufferAttributes;
@property (nonatomic, strong, nullable, readwrite) id<FBDataConsumer, FBDataConsumerStackConsuming> consumer;
@property (nonatomic, strong, nullable, readwrite) id<FBSimulatorVideoStreamFramePusher> framePusher;

- (void)pushFrame;

@end

static NSDictionary<NSString *, id> *FBBitmapStreamPixelBufferAttributesFromPixelBuffer(CVPixelBufferRef pixelBuffer)
{
  size_t width = CVPixelBufferGetWidth(pixelBuffer);
  size_t height = CVPixelBufferGetHeight(pixelBuffer);
  size_t frameSize = CVPixelBufferGetDataSize(pixelBuffer);
  size_t rowSize = CVPixelBufferGetBytesPerRow(pixelBuffer);
  OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
  NSString *pixelFormatString = (__bridge_transfer NSString *) UTCreateStringForOSType(pixelFormat);

  return @{
    @"width" : @(width),
    @"height" : @(height),
    @"row_size" : @(rowSize),
    @"frame_size" : @(frameSize),
    @"format" : pixelFormatString,
  };
}

@implementation FBSimulatorVideoStream

+ (dispatch_queue_t)writeQueue
{
  return dispatch_queue_create("com.facebook.FBSimulatorControl.BitmapStream", DISPATCH_QUEUE_SERIAL);
}

+ (nullable instancetype)streamWithFramebuffer:(FBFramebuffer *)framebuffer configuration:(FBVideoStreamConfiguration *)configuration logger:(id<FBControlCoreLogger>)logger
{
  NSNumber *framesPerSecondNumber = configuration.framesPerSecond;
  NSUInteger framesPerSecond = framesPerSecondNumber.unsignedIntegerValue;
  if (framesPerSecondNumber && framesPerSecond > 0) {
    return [[FBSimulatorVideoStream_Eager alloc] initWithFramebuffer:framebuffer configuration:configuration framesPerSecond:framesPerSecond writeQueue:self.writeQueue logger:logger];
  }
  return [[FBSimulatorVideoStream_Lazy alloc] initWithFramebuffer:framebuffer configuration:configuration writeQueue:self.writeQueue logger:logger];
}

- (instancetype)initWithFramebuffer:(FBFramebuffer *)framebuffer configuration:(FBVideoStreamConfiguration *)configuration writeQueue:(dispatch_queue_t)writeQueue logger:(id<FBControlCoreLogger>)logger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _framebuffer = framebuffer;
  _configuration = configuration;
  _writeQueue = writeQueue;
  _logger = logger;
  _startedFuture = FBMutableFuture.future;
  _stoppedFuture = FBMutableFuture.future;

  return self;
}

#pragma mark Public

- (FBFuture<NSNull *> *)startStreaming:(id<FBDataConsumer, FBDataConsumerStackConsuming>)consumer
{
  return [[FBFuture
    onQueue:self.writeQueue resolve:^ FBFuture<NSNull *> * {
      if (self.startedFuture.hasCompleted) {
        return [[FBSimulatorError
          describe:@"Cannot start streaming, since streaming is stopped"]
          failFuture];
      }
      if (self.consumer) {
        return [[FBSimulatorError
          describe:@"Cannot start streaming, since streaming has already has started"]
          failFuture];
      }
      self.consumer = consumer;
      return [self attachConsumerIfNeeded];
    }]
    onQueue:self.writeQueue fmap:^(id _) {
      return self.startedFuture;
    }];
}

- (FBFuture<NSNull *> *)stopStreaming
{
  return [FBFuture
    onQueue:self.writeQueue resolve:^ FBFuture<NSNull *> *{
      if (self.stoppedFuture.hasCompleted) {
        return self.stoppedFuture;
      }
      id<FBDataConsumer> consumer = self.consumer;
      if (!consumer) {
        return [[FBSimulatorError
          describe:@"Cannot stop streaming, no consumer attached"]
          failFuture];
      }
      if (![self.framebuffer.attachedConsumers containsObject:self]) {
        return [[FBSimulatorError
          describe:@"Cannot stop streaming, is not attached to a surface"]
          failFuture];
      }
      self.consumer = nil;
      [self.framebuffer detachConsumer:self];
      [consumer consumeEndOfFile];
      [self.stoppedFuture resolveWithResult:NSNull.null];
      return self.stoppedFuture;
    }];
}

#pragma mark Private

- (FBFuture<NSNull *> *)attachConsumerIfNeeded
{
  return [FBFuture
    onQueue:self.writeQueue resolve:^{
      if ([self.framebuffer isConsumerAttached:self]) {
        [self.logger logFormat:@"Already attached %@ as a consumer", self];
        return FBFuture.empty;
      }
      // If we have a surface now, we can start rendering, so mount the surface.
      IOSurface *surface = [self.framebuffer attachConsumer:self onQueue:self.writeQueue];
      [self didChangeIOSurface:surface];
      return FBFuture.empty;
    }];
}

#pragma mark FBFramebufferConsumer

- (void)didChangeIOSurface:(IOSurface *)surface
{
  [self mountSurface:surface error:nil];
  [self pushFrame];
}

- (void)didReceiveDamageRect:(CGRect)rect
{
}

#pragma mark Private

- (BOOL)mountSurface:(IOSurface *)surface error:(NSError **)error
{
  // Remove the old pixel buffer.
  CVPixelBufferRef oldBuffer = self.pixelBuffer;
  if (oldBuffer) {
    CVPixelBufferRelease(oldBuffer);
  }

  // Make a Buffer from the Surface
  CVPixelBufferRef buffer = NULL;
  CVReturn status = CVPixelBufferCreateWithIOSurface(
    NULL,
    (__bridge IOSurfaceRef _Nonnull)(surface),
    NULL,
    &buffer
  );
  if (status != kCVReturnSuccess) {
    return [[FBSimulatorError
      describeFormat:@"Failed to create Pixel Buffer from Surface with errorCode %d", status]
      failBool:error];
  }

  id<FBDataConsumer, FBDataConsumerStackConsuming> consumer = self.consumer;
  if (!consumer) {
    return [[FBSimulatorError
      describe:@"Cannot mount surface when there is no consumer"]
      failBool:error];
  }

  // Get the Attributes
  NSDictionary<NSString *, id> *attributes = FBBitmapStreamPixelBufferAttributesFromPixelBuffer(buffer);
  [self.logger logFormat:@"Mounting Surface with Attributes: %@", attributes];

  // Swap the pixel buffers.
  self.pixelBuffer = buffer;
  self.pixelBufferAttributes = attributes;

  id<FBSimulatorVideoStreamFramePusher> framePusher = [self.class framePusherForConfiguration:self.configuration compressionSessionProperties:self.compressionSessionProperties consumer:consumer logger:self.logger error:nil];
  if (!framePusher) {
    return NO;
  }
  if (![framePusher setupWithPixelBuffer:buffer error:error]) {
    return NO;
  }
  self.framePusher = framePusher;

  // Signal that we've started
  [self.startedFuture resolveWithResult:NSNull.null];

  return YES;
}

- (void)pushFrame
{
  // Ensure that we have all preconditions in place before pushing.
  CVPixelBufferRef pixelBufer = self.pixelBuffer;
  id<FBDataConsumer> consumer = self.consumer;
  id<FBSimulatorVideoStreamFramePusher> framePusher = self.framePusher;
  if (!pixelBufer || !consumer || !framePusher) {
    return;
  }
  NSUInteger frameNumber = self.frameNumber;
  if (frameNumber == 0) {
    self.timeAtFirstFrame = CFAbsoluteTimeGetCurrent();
  }
  CFTimeInterval timeAtFirstFrame = self.timeAtFirstFrame;

  // Push the Frame
  [framePusher writeEncodedFrame:pixelBufer frameNumber:frameNumber timeAtFirstFrame:timeAtFirstFrame error:nil];

  // Increment frame counter
  self.frameNumber = frameNumber + 1;
}

+ (id<FBSimulatorVideoStreamFramePusher>)framePusherForConfiguration:(FBVideoStreamConfiguration *)configuration compressionSessionProperties:(NSDictionary<NSString *, id> *)compressionSessionProperties consumer:(id<FBDataConsumer, FBDataConsumerStackConsuming>)consumer logger:(id<FBControlCoreLogger>)logger error:(NSError **)error
{
  // Get the base compression session properties, and add the class-cluster properties to them.
  NSMutableDictionary<NSString *, id> *derivedCompressionSessionProperties = [NSMutableDictionary dictionaryWithDictionary:@{
    (NSString *) kVTCompressionPropertyKey_RealTime: @YES,
    (NSString *) kVTCompressionPropertyKey_AllowFrameReordering: @NO,
  }];
  [derivedCompressionSessionProperties addEntriesFromDictionary:compressionSessionProperties];
  FBVideoStreamEncoding encoding = configuration.encoding;
  if ([encoding isEqualToString:FBVideoStreamEncodingH264]) {
    derivedCompressionSessionProperties[(NSString *) kVTCompressionPropertyKey_ProfileLevel] = (NSString *) kVTProfileLevel_H264_High_AutoLevel;
    return [[FBSimulatorVideoStreamFramePusher_VideoToolbox alloc]
      initWithConfiguration:configuration
      compressionSessionProperties:[derivedCompressionSessionProperties copy]
      videoCodec:kCMVideoCodecType_H264
      consumer:consumer
      compressorCallback:H264AnnexBCompressorCallback
      logger:logger];
  }
  if ([encoding isEqualToString:FBVideoStreamEncodingMJPEG]) {
      derivedCompressionSessionProperties[(NSString *) kVTCompressionPropertyKey_Quality] = configuration.compressionQuality;
      return [[FBSimulatorVideoStreamFramePusher_VideoToolbox alloc]
        initWithConfiguration:configuration
        compressionSessionProperties:[derivedCompressionSessionProperties copy]
        videoCodec:kCMVideoCodecType_JPEG
        consumer:consumer
        compressorCallback:MJPEGCompressorCallback
        logger:logger];
  }
  if ([encoding isEqualToString:FBVideoStreamEncodingMinicap]) {
    derivedCompressionSessionProperties[(NSString *) kVTCompressionPropertyKey_Quality] = configuration.compressionQuality;
    return [[FBSimulatorVideoStreamFramePusher_VideoToolbox alloc]
        initWithConfiguration:configuration
        compressionSessionProperties:[derivedCompressionSessionProperties copy]
        videoCodec:kCMVideoCodecType_JPEG
        consumer:consumer
        compressorCallback:MinicapCompressorCallback
        logger:logger];
  }
  if ([encoding isEqual:FBVideoStreamEncodingBGRA]) {
    return [[FBSimulatorVideoStreamFramePusher_Bitmap alloc] initWithConsumer:consumer];
  }
  return [[FBControlCoreError
    describeFormat:@"%@ is not supported for Simulators", encoding]
    fail:error];
}

- (NSDictionary<NSString *, id> *)compressionSessionProperties
{
  return @{};
}

#pragma mark FBiOSTargetOperation

- (FBFuture<NSNull *> *)completed
{
  return [[FBMutableFuture.future
    resolveFromFuture:self.stoppedFuture]
    onQueue:self.writeQueue respondToCancellation:^{
      return [self stopStreaming];
    }];
}

@end

@implementation FBSimulatorVideoStream_Lazy

- (void)didReceiveDamageRect:(CGRect)rect
{
  [self pushFrame];
}

@end

@implementation FBSimulatorVideoStream_Eager

- (instancetype)initWithFramebuffer:(FBFramebuffer *)framebuffer configuration:(FBVideoStreamConfiguration *)configuration framesPerSecond:(NSUInteger)framesPerSecond writeQueue:(dispatch_queue_t)writeQueue logger:(id<FBControlCoreLogger>)logger
{
  self = [super initWithFramebuffer:framebuffer configuration:configuration writeQueue:writeQueue logger:logger];
  if (!self) {
    return nil;
  }

  _framesPerSecond = framesPerSecond;

  return self;
}

#pragma mark Private

- (BOOL)mountSurface:(IOSurface *)surface error:(NSError **)error
{
  if (![super mountSurface:surface error:error]) {
    return NO;
  }

  if (self.timer) {
    [self.timer terminate];
    self.timer = nil;
  }
  uint64_t timeInterval = NSEC_PER_SEC / self.framesPerSecond;
  self.timer = [FBDispatchSourceNotifier timerNotifierNotifierWithTimeInterval:timeInterval queue:self.writeQueue handler:^(FBDispatchSourceNotifier *_) {
    [self pushFrame];
  }];

  return YES;
}

- (NSDictionary<NSString *, id> *)compressionSessionProperties
{
  return @{
    (NSString *) kVTCompressionPropertyKey_ExpectedFrameRate: @(self.framesPerSecond),
    (NSString *) kVTCompressionPropertyKey_MaxKeyFrameInterval: @2,
  };
}

@end
