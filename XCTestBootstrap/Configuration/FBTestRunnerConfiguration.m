/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBTestRunnerConfiguration.h"

#import "FBTestConfiguration.h"
#import "FBXCTestConstants.h"
#import "XCTestBootstrapError.h"

@implementation FBTestRunnerConfiguration

#pragma mark Initializers

- (instancetype)initWithSessionIdentifier:(NSUUID *)sessionIdentifier testRunner:(FBBundleDescriptor *)testRunner launchEnvironment:(NSDictionary<NSString *, NSString *> *)launchEnvironment testedApplicationAdditionalEnvironment:(NSDictionary<NSString *, NSString *> *)testedApplicationAdditionalEnvironment
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _sessionIdentifier = sessionIdentifier;
  _testRunner = testRunner;
  _launchEnvironment = launchEnvironment;
  _testedApplicationAdditionalEnvironment = testedApplicationAdditionalEnvironment;

  return self;
}

#pragma mark Public

+ (FBFuture<FBTestRunnerConfiguration *> *)prepareConfigurationWithTarget:(id<FBiOSTarget, FBXCTestExtendedCommands>)target testLaunchConfiguration:(FBTestLaunchConfiguration *)testLaunchConfiguration workingDirectory:(NSString *)workingDirectory codesign:(FBCodesignProvider *)codesign
{
  if (codesign) {
    return [[[codesign
      cdHashForBundleAtPath:testLaunchConfiguration.testBundlePath]
      rephraseFailure:@"Could not determine bundle at path '%@' is codesigned and codesigning is required", testLaunchConfiguration.testBundlePath]
      onQueue:target.asyncQueue fmap:^(id _) {
        return [self prepareConfigurationWithTargetAfterCodesignatureCheck:target testLaunchConfiguration:testLaunchConfiguration workingDirectory:workingDirectory];
      }];
  }
  return [self prepareConfigurationWithTargetAfterCodesignatureCheck:target testLaunchConfiguration:testLaunchConfiguration workingDirectory:workingDirectory];
}

+ (NSDictionary<NSString *, NSString *> *)launchEnvironmentWithHostApplication:(FBBundleDescriptor *)hostApplication hostApplicationAdditionalEnvironment:(NSDictionary<NSString *, NSString *> *)hostApplicationAdditionalEnvironment testBundle:(FBBundleDescriptor *)testBundle testConfigurationPath:(NSString *)testConfigurationPath frameworkSearchPaths:(NSArray<NSString *> *)frameworkSearchPaths
{
  NSMutableDictionary<NSString *, NSString *> *environmentVariables = hostApplicationAdditionalEnvironment.mutableCopy;
  NSString *frameworkSearchPath = [frameworkSearchPaths componentsJoinedByString:@":"];
  [environmentVariables addEntriesFromDictionary:@{
    @"AppTargetLocation" : hostApplication.binary.path,
    @"DYLD_FALLBACK_FRAMEWORK_PATH" : frameworkSearchPath ?: @"",
    @"DYLD_FALLBACK_LIBRARY_PATH" : frameworkSearchPath ?: @"",
    @"OBJC_DISABLE_GC" : @"YES",
    @"TestBundleLocation" : testBundle.path,
    @"XCODE_DBG_XPC_EXCLUSIONS" : @"com.apple.dt.xctestSymbolicator",
    @"XCTestConfigurationFilePath" : testConfigurationPath,
  }];
  return [self addAdditionalEnvironmentVariables:environmentVariables.copy];
}

- (NSArray<NSString *> *)launchArguments
{
  return @[
    @"-NSTreatUnknownArgumentsAsOpen", @"NO",
    @"-ApplePersistenceIgnoreState", @"YES"
  ];
}

#pragma mark NSCopying

- (instancetype)copyWithZone:(NSZone *)zone
{
  return self;
}

#pragma mark Private

+ (NSDictionary<NSString *, NSString *> *)addAdditionalEnvironmentVariables:(NSDictionary<NSString *, NSString *> *)currentEnvironmentVariables
{
  NSString *prefix = @"CUSTOM_";
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"self BEGINSWITH %@", prefix];
  NSArray *filter = [[NSProcessInfo.processInfo.environment allKeys] filteredArrayUsingPredicate:predicate];
  NSDictionary *envVariableWtihPrefix = [NSProcessInfo.processInfo.environment dictionaryWithValuesForKeys:filter];

  NSMutableDictionary *envs = [currentEnvironmentVariables mutableCopy];
  for (NSString *key in envVariableWtihPrefix)
  {
    envs[[key substringFromIndex:[prefix length]]] = envVariableWtihPrefix[key];
  }

  return [NSDictionary dictionaryWithDictionary:envs];
}


+ (FBFuture<FBTestRunnerConfiguration *> *)prepareConfigurationWithTargetAfterCodesignatureCheck:(id<FBiOSTarget, FBXCTestExtendedCommands>)target testLaunchConfiguration:(FBTestLaunchConfiguration *)testLaunchConfiguration workingDirectory:(NSString *)workingDirectory
{
  // Common Paths
  NSString *runtimeRoot = target.runtimeRootDirectory;
  NSString *platformRoot = target.platformRootDirectory;

  // This directory will contain XCTest.framework, built for the target platform.
  NSString *platformDeveloperFrameworksPath = [platformRoot stringByAppendingPathComponent:@"Developer/Library/Frameworks"];
  // See if the injector lib is present, not that this may not be present on certain versions of Xcode.
  NSString *xctTargetBootstrapInjectPath = [platformRoot stringByAppendingPathComponent:@"Developer/usr/lib/libXCTTargetBootstrapInject.dylib"];
  // Container directory for XCTest related Frameworks.
  NSString *developerLibraryPath = [runtimeRoot stringByAppendingPathComponent:@"Developer/Library"];
  // A Framework needed for UI based test
  NSString *automationFrameworkPath = [developerLibraryPath stringByAppendingPathComponent:@"PrivateFrameworks/XCTAutomationSupport.framework"];
  // Contains other frameworks, depended on by XCTest and Instruments
  NSArray<NSString *> *XCTestFrameworksPaths = @[
    [developerLibraryPath stringByAppendingPathComponent:@"Frameworks"],
    [developerLibraryPath stringByAppendingPathComponent:@"PrivateFrameworks"],
    platformDeveloperFrameworksPath,
  ];

  NSDictionary *testedApplicationAdditionalEnvironment = @{
    @"DYLD_INSERT_LIBRARIES" : xctTargetBootstrapInjectPath
  };
  if (![NSFileManager.defaultManager fileExistsAtPath:automationFrameworkPath] && ![NSFileManager.defaultManager fileExistsAtPath:xctTargetBootstrapInjectPath]) {
    automationFrameworkPath = nil;
    testedApplicationAdditionalEnvironment = nil;
  }

  // Prepare XCTest bundle
  NSError *error;
  NSUUID *sessionIdentifier = [NSUUID UUID];
  FBBundleDescriptor *testBundle = [FBBundleDescriptor bundleFromPath:testLaunchConfiguration.testBundlePath error:&error];
  if (!testBundle) {
    return [[[XCTestBootstrapError
      describe:@"Failed to prepare test bundle"]
      causedBy:error]
      failFuture];
  }

  // Prepare the test configuration
  FBTestConfiguration *testConfiguration = [FBTestConfiguration
    configurationByWritingToFileWithSessionIdentifier:sessionIdentifier
    moduleName:testBundle.name
    testBundlePath:testBundle.path
    uiTesting:testLaunchConfiguration.shouldInitializeUITesting
    testsToRun:testLaunchConfiguration.testsToRun
    testsToSkip:testLaunchConfiguration.testsToSkip
    targetApplicationPath:testLaunchConfiguration.targetApplicationPath
    targetApplicationBundleID:testLaunchConfiguration.targetApplicationBundleID
    automationFrameworkPath:automationFrameworkPath
    reportActivities:testLaunchConfiguration.reportActivities
    error:&error];
  if (!testBundle) {
    return [[[XCTestBootstrapError
      describe:@"Failed to prepare test configuration"]
      causedBy:error]
      failFuture];
  }

  return [[FBFuture
    futureWithFutures:@[
      [target installedApplicationWithBundleID:testLaunchConfiguration.applicationLaunchConfiguration.bundleID],
      [target extendedTestShim],
    ]]
    onQueue:target.asyncQueue map:^(NSArray<id> *tuple) {
      FBInstalledApplication *hostApplication = tuple[0];
      NSString *shimPath = tuple[1];
      NSMutableDictionary<NSString *, NSString *> *hostApplicationAdditionalEnvironment = [NSMutableDictionary dictionary];
      hostApplicationAdditionalEnvironment[kEnv_ShimStartXCTest] = @"1";
      hostApplicationAdditionalEnvironment[@"DYLD_INSERT_LIBRARIES"] = shimPath;
      NSString *coveragePath = testLaunchConfiguration.coveragePath;
      if (coveragePath) {
        hostApplicationAdditionalEnvironment[kEnv_LLVMProfileFile] = testLaunchConfiguration.coveragePath;
      }
      NSString *logDirectoryPath = testLaunchConfiguration.logDirectoryPath;
      if (logDirectoryPath) {
        hostApplicationAdditionalEnvironment[kEnv_LogDirectoryPath] = logDirectoryPath;
      }
      // These Search Paths are added via "DYLD_FALLBACK_FRAMEWORK_PATH" so that they can be resolved when linked by the Application.
      // This is needed so that the Application is aware of how to link the XCTest.framework from the developer directory.
      // The Application binary will not contain linker opcodes that point to the XCTest.framework within the Simulator runtime bundle.
      // Therefore we need to provide them to the test runner so it can pass them to the app launch.
      NSArray<NSString *> *frameworkSearchPaths = [XCTestFrameworksPaths arrayByAddingObject:[hostApplication.bundle.path stringByAppendingPathComponent:@"Frameworks"]];

      // The environment constructed for the app launch must contain the relevant env vars to point at the relevant configuration.
      NSDictionary<NSString *, NSString *> *launchEnvironment = [FBTestRunnerConfiguration
        launchEnvironmentWithHostApplication:hostApplication.bundle
        hostApplicationAdditionalEnvironment:hostApplicationAdditionalEnvironment
        testBundle:testBundle
        testConfigurationPath:testConfiguration.path
        frameworkSearchPaths:frameworkSearchPaths];

      return [[FBTestRunnerConfiguration alloc]
        initWithSessionIdentifier:sessionIdentifier
        testRunner:hostApplication.bundle
        launchEnvironment:launchEnvironment
        testedApplicationAdditionalEnvironment:testedApplicationAdditionalEnvironment];
    }];
}

@end
