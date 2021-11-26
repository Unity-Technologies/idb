/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBXCTestReporterConfiguration.h"

#import <FBControlCore/FBControlCore.h>
#import <XCTestBootstrap/XCTestBootstrap.h>

@implementation FBXCTestReporterConfiguration

- (instancetype)initWithResultBundlePath:(nullable NSString *)resultBundlePath coverageConfiguration:(nullable FBCodeCoverageConfiguration *)coverageConfiguration logDirectoryPath:(nullable NSString *)logDirectoryPath binariesPaths:(nullable NSArray<NSString *> *)binariesPaths reportAttachments:(BOOL)reportAttachments
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _resultBundlePath = resultBundlePath;
  _coverageConfiguration = coverageConfiguration;
  _logDirectoryPath = logDirectoryPath;
  _binariesPaths = binariesPaths;
  _reportAttachments = reportAttachments;

  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"Result Bundle %@ | Coverage %@ | Log Path %@ | Binaries Paths %@ | Report Attachments %d", self.resultBundlePath, self.coverageConfiguration, self.logDirectoryPath, [FBCollectionInformation oneLineDescriptionFromArray:self.binariesPaths], self.reportAttachments];
}

@end
