/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBXCTestDescriptor.h"

#import <XCTestBootstrap/XCTestBootstrap.h>

#import "FBIDBError.h"
#import "FBIDBStorageManager.h"
#import "FBIDBTestOperation.h"
#import "FBTemporaryDirectory.h"
#import "FBTestApplicationsPair.h"
#import "FBXCTestReporterConfiguration.h"
#import "FBXCTestRunFileReader.h"

static FBFuture<FBApplicationLaunchConfiguration *> *BuildAppLaunchConfig(NSString *bundleID, NSDictionary<NSString *, NSString *> *environment, NSArray<NSString *> * arguments, id<FBControlCoreLogger> logger,  NSString * processLogDirectory, dispatch_queue_t queue)
{
  FBLoggingDataConsumer *stdOutConsumer = [FBLoggingDataConsumer consumerWithLogger:logger];
  FBLoggingDataConsumer *stdErrConsumer = [FBLoggingDataConsumer consumerWithLogger:logger];

  FBFuture<id<FBDataConsumer, FBDataConsumerLifecycle>> *stdOutFuture = [FBFuture futureWithResult:stdOutConsumer];
  FBFuture<id<FBDataConsumer, FBDataConsumerLifecycle>> *stdErrFuture = [FBFuture futureWithResult:stdErrConsumer];

  if (processLogDirectory) {
    FBXCTestLogger *mirrorLogger = [FBXCTestLogger defaultLoggerInDirectory:processLogDirectory];
    NSUUID *udid = NSUUID.UUID;
    stdOutFuture = [mirrorLogger logConsumptionToFile:stdOutConsumer outputKind:@"out" udid:udid logger:logger];
    stdErrFuture = [mirrorLogger logConsumptionToFile:stdErrConsumer outputKind:@"err" udid:udid logger:logger];
  }

  return [[FBFuture
    futureWithFutures:@[stdOutFuture, stdErrFuture]]
    onQueue:queue map:^ (NSArray<id<FBDataConsumer, FBDataConsumerLifecycle>> *outputs) {
      FBProcessIO *io = [[FBProcessIO alloc]
        initWithStdIn:nil
        stdOut:[FBProcessOutput outputForDataConsumer:outputs[0]]
        stdErr:[FBProcessOutput outputForDataConsumer:outputs[1]]];
      return [[FBApplicationLaunchConfiguration alloc]
        initWithBundleID:bundleID
        bundleName:nil
        arguments:arguments ?: @[]
        environment:environment ?: @{}
        waitForDebugger:NO
        io:io
        launchMode:FBApplicationLaunchModeFailIfRunning];
  }];
}

static const NSTimeInterval FBLogicTestTimeout = 60 * 60; //Aprox. an hour.

@interface FBXCTestRunRequest_LogicTest : FBXCTestRunRequest

@end

@implementation FBXCTestRunRequest_LogicTest

- (BOOL)isLogicTest
{
  return YES;
}

- (BOOL)isUITest
{
  return NO;
}

- (FBFuture<FBIDBTestOperation *> *)startWithTestDescriptor:(id<FBXCTestDescriptor>)testDescriptor logDirectoryPath:(NSString *)logDirectoryPath reportActivities:(BOOL)reportActivities target:(id<FBiOSTarget>)target reporter:(id<FBXCTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger temporaryDirectory:(FBTemporaryDirectory *)temporaryDirectory
{
  NSError *error = nil;
  NSURL *workingDirectory = [temporaryDirectory ephemeralTemporaryDirectory];
  if (![NSFileManager.defaultManager createDirectoryAtURL:workingDirectory withIntermediateDirectories:YES attributes:nil error:&error]) {
    return [FBFuture futureWithError:error];
  }

  NSString *coveragePath = nil;
  if (self.collectCoverage) {
    NSURL *dir = [temporaryDirectory ephemeralTemporaryDirectory];
    NSString *coverageFileName = [NSString stringWithFormat:@"coverage_%@.profraw", NSUUID.UUID.UUIDString];
    coveragePath = [dir.path stringByAppendingPathComponent:coverageFileName];
  }

  NSString *testFilter = nil;
  NSArray<NSString *> *testsToSkip = self.testsToSkip.allObjects ?: @[];
  if (testsToSkip.count > 0) {
    return [[FBXCTestError
      describeFormat:@"'Tests to Skip' %@ provided, but Logic Tests to not support this.", [FBCollectionInformation oneLineDescriptionFromArray:testsToSkip]]
      failFuture];
  }
  NSArray<NSString *> *testsToRun = self.testsToRun.allObjects ?: @[];
  if (testsToRun.count > 1){
    return [[FBXCTestError
      describeFormat:@"More than one 'Tests to Run' %@ provided, but only one 'Tests to Run' is supported.", [FBCollectionInformation oneLineDescriptionFromArray:testsToRun]]
      failFuture];
  }
  testFilter = testsToRun.firstObject;

  NSTimeInterval timeout = self.testTimeout.boolValue ? self.testTimeout.doubleValue : FBLogicTestTimeout;
  FBLogicTestConfiguration *configuration = [FBLogicTestConfiguration
    configurationWithEnvironment:self.environment
    workingDirectory:workingDirectory.path
    testBundlePath:testDescriptor.testBundle.path
    waitForDebugger:self.waitForDebugger
    timeout:timeout
    testFilter:testFilter
    mirroring:FBLogicTestMirrorFileLogs
    coveragePath:coveragePath
    binaryPath:testDescriptor.testBundle.binary.path
    logDirectoryPath:logDirectoryPath];

  return [self startTestExecution:configuration logDirectoryPath:logDirectoryPath target:target reporter:reporter logger:logger];
}

- (FBFuture<FBIDBTestOperation *> *)startTestExecution:(FBLogicTestConfiguration *)configuration logDirectoryPath:(NSString *)logDirectoryPath target:(id<FBiOSTarget>)target reporter:(id<FBXCTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger
{
  FBLogicReporterAdapter *adapter = [[FBLogicReporterAdapter alloc] initWithReporter:reporter logger:logger];
  FBLogicTestRunStrategy *runner = [[FBLogicTestRunStrategy alloc] initWithTarget:(id<FBiOSTarget, FBProcessSpawnCommands, FBXCTestExtendedCommands>)target configuration:configuration reporter:adapter logger:logger];
  FBFuture<NSNull *> *completed = [runner execute];
  if (completed.error) {
    return [FBFuture futureWithError:completed.error];
  }
  FBXCTestReporterConfiguration *reporterConfiguration = [[FBXCTestReporterConfiguration alloc]
    initWithResultBundlePath:nil
    coveragePath:configuration.coveragePath
    logDirectoryPath:logDirectoryPath
    binaryPath:configuration.binaryPath
    reportAttachments:self.reportAttachments];
  FBIDBTestOperation *operation = [[FBIDBTestOperation alloc]
    initWithConfiguration:configuration
    reporterConfiguration:reporterConfiguration
    reporter:reporter
    logger:logger
    completed:completed
    queue:target.workQueue];
  return [FBFuture futureWithResult:operation];
}

@end

@interface FBXCTestRunRequest_AppTest : FBXCTestRunRequest

@end

@implementation FBXCTestRunRequest_AppTest

- (BOOL)isLogicTest
{
  return NO;
}

- (BOOL)isUITest
{
  return NO;
}

- (FBFuture<FBIDBTestOperation *> *)startWithTestDescriptor:(id<FBXCTestDescriptor>)testDescriptor logDirectoryPath:(NSString *)logDirectoryPath reportActivities:(BOOL)reportActivities target:(id<FBiOSTarget>)target reporter:(id<FBXCTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger temporaryDirectory:(FBTemporaryDirectory *)temporaryDirectory
{
  return [[[testDescriptor
    testAppPairForRequest:self target:target]
    onQueue:target.workQueue fmap:^ FBFuture<FBTestLaunchConfiguration *> * (FBTestApplicationsPair *pair) {
      [logger logFormat:@"Obtaining launch configuration for App Pair %@ on descriptor %@", pair, testDescriptor];
      return [testDescriptor testConfigWithRunRequest:self testApps:pair logDirectoryPath:logDirectoryPath logger:logger queue:target.workQueue];
    }]
    onQueue:target.workQueue fmap:^ FBFuture<FBIDBTestOperation *> * (FBTestLaunchConfiguration *testConfig) {
      [logger logFormat:@"Obtained launch configuration %@", testConfig];
      return [FBXCTestRunRequest_AppTest startTestExecution:testConfig logDirectoryPath:logDirectoryPath reportAttachments:self.reportAttachments target:target reporter:reporter logger:logger];
    }];
}

+ (FBFuture<FBIDBTestOperation *> *)startTestExecution:(FBTestLaunchConfiguration *)configuration logDirectoryPath:(NSString *)logDirectoryPath reportAttachments:(BOOL)reportAttachments target:(id<FBiOSTarget>)target reporter:(id<FBXCTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger
{
  return [[target
    installedApplicationWithBundleID:configuration.targetApplicationBundleID ?: configuration.applicationLaunchConfiguration.bundleID]
    onQueue:target.workQueue map:^(FBInstalledApplication *installedApp) {
      NSString *binaryPath = installedApp.bundle.binary.path;
      FBFuture<NSNull *> *testCompleted = [target runTestWithLaunchConfiguration:configuration reporter:reporter logger:logger];
      FBXCTestReporterConfiguration *reporterConfiguration = [[FBXCTestReporterConfiguration alloc]
        initWithResultBundlePath:configuration.resultBundlePath
        coveragePath:configuration.coveragePath
        logDirectoryPath:logDirectoryPath
        binaryPath:binaryPath
        reportAttachments:reportAttachments];
      return [[FBIDBTestOperation alloc]
        initWithConfiguration:configuration
        reporterConfiguration:reporterConfiguration
        reporter:reporter
        logger:logger
        completed:testCompleted
        queue:target.workQueue];
    }];
}

@end

@interface FBXCTestRunRequest_UITest : FBXCTestRunRequest_AppTest

@end

@implementation FBXCTestRunRequest_UITest

- (BOOL)isLogicTest
{
  return NO;
}

- (BOOL)isUITest
{
  return YES;
}

@end

@implementation FBXCTestRunRequest

@synthesize testBundleID = _testBundleID;
@synthesize appBundleID = _appBundleID;
@synthesize testHostAppBundleID = _testHostAppBundleID;
@synthesize environment = _environment;
@synthesize arguments = _arguments;
@synthesize testsToRun = _testsToRun;
@synthesize testsToSkip = _testsToSkip;
@synthesize testTimeout = _testTimeout;


#pragma mark Initializers

+ (instancetype)logicTestWithTestBundleID:(NSString *)testBundleID environment:(NSDictionary<NSString *, NSString *> *)environment arguments:(NSArray<NSString *> *)arguments testsToRun:(NSSet<NSString *> *)testsToRun testsToSkip:(NSSet<NSString *> *)testsToSkip testTimeout:(NSNumber *)testTimeout reportActivities:(BOOL)reportActivities reportAttachments:(BOOL)reportAttachments collectCoverage:(BOOL)collectCoverage collectLogs:(BOOL)collectLogs waitForDebugger:(BOOL)waitForDebugger
{
  return [[FBXCTestRunRequest_LogicTest alloc] initWithTestBundleID:testBundleID appBundleID:nil testHostAppBundleID:nil environment:environment arguments:arguments testsToRun:testsToRun testsToSkip:testsToSkip testTimeout:testTimeout reportActivities:reportActivities reportAttachments:reportAttachments collectCoverage:collectCoverage collectLogs:collectLogs waitForDebugger:waitForDebugger];
}

+ (instancetype)applicationTestWithTestBundleID:(NSString *)testBundleID appBundleID:(NSString *)appBundleID environment:(NSDictionary<NSString *, NSString *> *)environment arguments:(NSArray<NSString *> *)arguments testsToRun:(NSSet<NSString *> *)testsToRun testsToSkip:(NSSet<NSString *> *)testsToSkip testTimeout:(NSNumber *)testTimeout reportActivities:(BOOL)reportActivities reportAttachments:(BOOL)reportAttachments collectCoverage:(BOOL)collectCoverage collectLogs:(BOOL)collectLogs
{
  return [[FBXCTestRunRequest_AppTest alloc] initWithTestBundleID:testBundleID appBundleID:appBundleID testHostAppBundleID:nil environment:environment arguments:arguments testsToRun:testsToRun testsToSkip:testsToSkip testTimeout:testTimeout reportActivities:reportActivities reportAttachments:reportAttachments collectCoverage:collectCoverage collectLogs:collectLogs waitForDebugger:NO];
}

+ (instancetype)uiTestWithTestBundleID:(NSString *)testBundleID appBundleID:(NSString *)appBundleID testHostAppBundleID:(NSString *)testHostAppBundleID environment:(NSDictionary<NSString *, NSString *> *)environment arguments:(NSArray<NSString *> *)arguments testsToRun:(NSSet<NSString *> *)testsToRun testsToSkip:(NSSet<NSString *> *)testsToSkip testTimeout:(NSNumber *)testTimeout reportActivities:(BOOL)reportActivities reportAttachments:(BOOL)reportAttachments collectCoverage:(BOOL)collectCoverage collectLogs:(BOOL)collectLogs
{
  return [[FBXCTestRunRequest_UITest alloc] initWithTestBundleID:testBundleID appBundleID:appBundleID testHostAppBundleID:testHostAppBundleID environment:environment arguments:arguments testsToRun:testsToRun testsToSkip:testsToSkip testTimeout:testTimeout reportActivities:reportActivities reportAttachments:reportAttachments collectCoverage:collectCoverage collectLogs:collectLogs waitForDebugger:NO];
}

- (instancetype)initWithTestBundleID:(NSString *)testBundleID appBundleID:(NSString *)appBundleID testHostAppBundleID:(NSString *)testHostAppBundleID environment:(NSDictionary<NSString *, NSString *> *)environment arguments:(NSArray<NSString *> *)arguments testsToRun:(NSSet<NSString *> *)testsToRun testsToSkip:(NSSet<NSString *> *)testsToSkip testTimeout:(NSNumber *)testTimeout reportActivities:(BOOL)reportActivities reportAttachments:(BOOL)reportAttachments collectCoverage:(BOOL)collectCoverage collectLogs:(BOOL)collectLogs waitForDebugger:(BOOL)waitForDebugger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _testBundleID = testBundleID;
  _appBundleID = appBundleID;
  _testHostAppBundleID = testHostAppBundleID;
  _environment = environment;
  _arguments = arguments;
  _testsToRun = testsToRun;
  _testsToSkip = testsToSkip;
  _testTimeout = testTimeout;
  _reportActivities = reportActivities;
  _reportAttachments = reportAttachments;
  _collectCoverage = collectCoverage;
  _collectLogs = collectLogs;
  _waitForDebugger = waitForDebugger;

  return self;
}

- (BOOL)isLogicTest
{
  return NO;
}

- (BOOL)isUITest
{
  return NO;
}

- (FBFuture<FBIDBTestOperation *> *)startWithBundleStorageManager:(FBXCTestBundleStorage *)bundleStorage target:(id<FBiOSTarget>)target reporter:(id<FBXCTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger temporaryDirectory:(FBTemporaryDirectory *)temporaryDirectory
{
  return [[self
    fetchAndSetupDescriptorWithBundleStorage:bundleStorage target:target]
    onQueue:target.workQueue fmap:^ FBFuture<FBIDBTestOperation *> * (id<FBXCTestDescriptor> descriptor) {
      NSString *logDirectoryPath = nil;
      if (self.collectLogs) {
        NSError *error;
        NSURL *directory = [temporaryDirectory ephemeralTemporaryDirectory];
        if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
          return [FBFuture futureWithError:error];
        }
        logDirectoryPath = directory.path;
      }
      return [self startWithTestDescriptor:descriptor logDirectoryPath:logDirectoryPath reportActivities:self.reportActivities target:target reporter:reporter logger:logger temporaryDirectory:temporaryDirectory];
    }];
}

- (FBFuture<FBIDBTestOperation *> *)startWithTestDescriptor:(id<FBXCTestDescriptor>)testDescriptor logDirectoryPath:(NSString *)logDirectoryPath reportActivities:(BOOL)reportActivities target:(id<FBiOSTarget>)target reporter:(id<FBXCTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger temporaryDirectory:(FBTemporaryDirectory *)temporaryDirectory
{
  return [[FBIDBError
    describeFormat:@"%@ not implemented in abstract base class", NSStringFromSelector(_cmd)]
    failFuture];
}

- (FBFuture<id<FBXCTestDescriptor>> *)fetchAndSetupDescriptorWithBundleStorage:(FBXCTestBundleStorage *)bundleStorage target:(id<FBiOSTarget>)target
{
  NSError *error = nil;
  id<FBXCTestDescriptor> testDescriptor = [bundleStorage testDescriptorWithID:self.testBundleID error:&error];
  if (!testDescriptor) {
    return [FBFuture futureWithError:error];
  }
  return [[testDescriptor setupWithRequest:self target:target] mapReplace:testDescriptor];
}

@end

@interface FBXCTestBootstrapDescriptor ()

@property (nonatomic, strong, readonly) NSString *targetAuxillaryDirectory;

@end


@implementation FBXCTestBootstrapDescriptor

@synthesize url = _url;
@synthesize name = _name;
@synthesize testBundle = _testBundle;

#pragma mark Initializers

- (instancetype)initWithURL:(NSURL *)url name:(NSString *)name testBundle:(FBBundleDescriptor *)testBundle
{
  self = [super init];

  if (!self) {
    return nil;
  }

  _url = url;
  _name = name;
  _testBundle = testBundle;

  return self;
}

#pragma mark NSObject

- (NSString *)description
{
  return [NSString stringWithFormat:@"xctestbootstrap descriptor for %@ %@ %@", self.url, self.name, self.testBundle];
}

#pragma mark Properties

- (NSString *)testBundleID
{
  return self.testBundle.identifier;
}

- (NSSet *)architectures
{
  return self.testBundle.binary.architectures;
}

#pragma mark Private

+ (FBFuture<NSNull *> *)killAllRunningApplications:(id<FBiOSTarget>)target
{
  id<FBApplicationCommands> commands = (id<FBApplicationCommands>) target;
  if (![commands conformsToProtocol:@protocol(FBApplicationCommands)]) {
    return [[FBIDBError
      describeFormat:@"%@ does not conform to FBApplicationCommands", commands]
      failFuture];
  }
  return [[[commands
    runningApplications]
    onQueue:target.workQueue fmap:^(NSDictionary<NSString *, FBProcessInfo *> *runningApplications) {
      NSMutableArray<FBFuture<NSNull *> *> *futures = [NSMutableArray array];
      for (NSString *bundleID in runningApplications) {
       [futures addObject:[commands killApplicationWithBundleID:bundleID]];
      }
      return [FBFuture futureWithFutures:futures];
    }]
    mapReplace:NSNull.null];
}

#pragma mark Public

- (FBFuture<NSNull *> *)setupWithRequest:(FBXCTestRunRequest *)request target:(id<FBiOSTarget>)target
{
  _targetAuxillaryDirectory = target.auxillaryDirectory;
  if (request.isLogicTest) {
    //Logic tests don't use an app to run
    //killing them is unnecessary for us.
    return FBFuture.empty;
  }

  // Kill all Running Applications to get back to a clean slate.
  return [[FBXCTestBootstrapDescriptor killAllRunningApplications:target] mapReplace:NSNull.null];
}

- (FBFuture<FBTestApplicationsPair *> *)testAppPairForRequest:(FBXCTestRunRequest *)request target:(id<FBiOSTarget>)target
{
  if (request.isLogicTest) {
    return [FBFuture futureWithResult:[[FBTestApplicationsPair alloc] initWithApplicationUnderTest:nil testHostApp:nil]];
  }
  if (request.isUITest) {
    if (!request.appBundleID) {
      return [[FBIDBError
        describe:@"Request for UI Test, but no app_bundle_id provided"]
        failFuture];
    }
    NSString *testHostBundleID = request.testHostAppBundleID ?: @"com.apple.Preferences";
    return [[FBFuture
      futureWithFutures:@[
        [target installedApplicationWithBundleID:request.appBundleID],
        [target installedApplicationWithBundleID:testHostBundleID],
      ]]
      onQueue:target.asyncQueue map:^(NSArray<FBInstalledApplication *> *applications) {
        return [[FBTestApplicationsPair alloc] initWithApplicationUnderTest:applications[0] testHostApp:applications[1]];
      }];
  }
  NSString *bundleID = request.testHostAppBundleID ?: request.appBundleID;
  if (!bundleID) {
    return [[FBIDBError
      describe:@"Request for Application Test, but no app_bundle_id or test_host_app_bundle_id provided"]
      failFuture];
  }
  return [[target
    installedApplicationWithBundleID:bundleID]
    onQueue:target.asyncQueue map:^(FBInstalledApplication *application) {
      return [[FBTestApplicationsPair alloc] initWithApplicationUnderTest:nil testHostApp:application];
    }];
}

- (FBFuture<FBTestLaunchConfiguration *> *)testConfigWithRunRequest:(FBXCTestRunRequest *)request testApps:(FBTestApplicationsPair *)testApps logDirectoryPath:(NSString *)logDirectoryPath logger:(id<FBControlCoreLogger>)logger queue:(dispatch_queue_t)queue
{
  BOOL uiTesting = NO;
  NSString *targetApplicationPath = nil;
  NSString *targetApplicationBundleID = nil;
  FBFuture<FBApplicationLaunchConfiguration *> *appLaunchConfigFuture = nil;
  if (request.isUITest) {
    appLaunchConfigFuture = BuildAppLaunchConfig(testApps.testHostApp.bundle.identifier, request.environment, request.arguments, logger, logDirectoryPath, queue);
    // Test config
    uiTesting = YES;
    targetApplicationPath = testApps.applicationUnderTest.bundle.path;
    targetApplicationBundleID = testApps.applicationUnderTest.bundle.identifier;
  } else {
    appLaunchConfigFuture = BuildAppLaunchConfig(request.appBundleID, request.environment, request.arguments, logger, logDirectoryPath, queue);
  }
  NSString *coveragePath = nil;
  if (request.collectCoverage) {
    NSString *coverageFileName = [NSString stringWithFormat:@"coverage_%@.profraw", NSUUID.UUID.UUIDString];
    coveragePath = [self.targetAuxillaryDirectory stringByAppendingPathComponent:coverageFileName];
  }

  return [appLaunchConfigFuture onQueue:queue map:^ FBTestLaunchConfiguration * (FBApplicationLaunchConfiguration *applicationLaunchConfiguration) {
    return [[FBTestLaunchConfiguration alloc]
      initWithTestBundlePath:self.testBundle.path
      applicationLaunchConfiguration:applicationLaunchConfiguration
      testHostPath:nil
      timeout:(request.testTimeout ? request.testTimeout.doubleValue : 0)
      initializeUITesting:uiTesting
      useXcodebuild:NO
      testsToRun:request.testsToRun
      testsToSkip:request.testsToSkip
      targetApplicationPath:targetApplicationPath
      targetApplicationBundleID:targetApplicationBundleID
      xcTestRunProperties:nil
      resultBundlePath:nil
      reportActivities:request.reportActivities
      coveragePath:coveragePath
      logDirectoryPath:logDirectoryPath];
  }];
}

@end

@interface FBXCodebuildTestRunDescriptor ()

@property (nonatomic, strong, readonly) NSString *targetAuxillaryDirectory;

@end

@implementation FBXCodebuildTestRunDescriptor

@synthesize url = _url;
@synthesize name = _name;
@synthesize testBundle = _testBundle;

- (instancetype)initWithURL:(NSURL *)url name:(NSString *)name testBundle:(FBBundleDescriptor *)testBundle testHostBundle:(FBBundleDescriptor *)testHostBundle
{
  self = [super init];

  if (!self) {
    return nil;
  }

  _url = url;
  _name = name;
  _testBundle = testBundle;
  _testHostBundle = testHostBundle;

  return self;
}

#pragma mark NSObject

- (NSString *)description
{
  return [NSString stringWithFormat:@"xcodebuild descriptor for %@ %@ %@ %@", self.url, self.name, self.testBundle, self.testHostBundle];
}

#pragma mark Properties

- (NSString *)testBundleID
{
  return self.testBundle.identifier;
}

- (NSSet *)architectures
{
  return self.testHostBundle.binary.architectures;
}

#pragma mark Public Methods

- (FBFuture<NSNull *> *)setupWithRequest:(FBXCTestRunRequest *)request target:(id<FBiOSTarget>)target
{
  _targetAuxillaryDirectory = target.auxillaryDirectory;
  return FBFuture.empty;
}

- (FBFuture<FBTestApplicationsPair *> *)testAppPairForRequest:(FBXCTestRunRequest *)request target:(id<FBiOSTarget>)target
{
  return [FBFuture futureWithResult:[[FBTestApplicationsPair alloc] initWithApplicationUnderTest:nil testHostApp:nil]];
}

- (FBFuture<FBTestLaunchConfiguration *> *)testConfigWithRunRequest:(FBXCTestRunRequest *)request testApps:(FBTestApplicationsPair *)testApps logDirectoryPath:(NSString *)logDirectoryPath logger:(id<FBControlCoreLogger>)logger queue:(dispatch_queue_t)queue
{
  NSString *resultBundleName = [NSString stringWithFormat:@"resultbundle_%@", NSUUID.UUID.UUIDString];
  NSString *resultBundlePath = [self.targetAuxillaryDirectory stringByAppendingPathComponent:resultBundleName];

  NSError *error = nil;
  NSDictionary<NSString *, id> *properties = [FBXCTestRunFileReader readContentsOf:self.url expandPlaceholderWithPath:self.targetAuxillaryDirectory error:&error];
  if (!properties) {
    return [FBFuture futureWithError:error];
  }
  return [BuildAppLaunchConfig(request.appBundleID, request.environment, request.arguments, logger, nil, queue)
   onQueue:queue map:^ FBTestLaunchConfiguration * (FBApplicationLaunchConfiguration *launchConfig) {
    return [[FBTestLaunchConfiguration alloc]
      initWithTestBundlePath:self.testBundle.path
      applicationLaunchConfiguration:launchConfig
      testHostPath:self.testHostBundle.path
      timeout:0
      initializeUITesting:request.isUITest
      useXcodebuild:YES
      testsToRun:request.testsToRun
      testsToSkip:request.testsToSkip
      targetApplicationPath:nil
      targetApplicationBundleID:nil
      xcTestRunProperties:properties
      resultBundlePath:resultBundlePath
      reportActivities:request.reportActivities
      coveragePath:nil
      logDirectoryPath:logDirectoryPath];
  }];
}


@end
