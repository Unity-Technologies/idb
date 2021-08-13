/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBXCTestReporterConfiguration.h"

@implementation FBXCTestReporterConfiguration

- (instancetype)initWithResultBundlePath:(nullable NSString *)resultBundlePath coveragePath:(nullable NSString *)coveragePath logDirectoryPath:(nullable NSString *)logDirectoryPath binaryPath:(nullable NSString *)binaryPath reportAttachments:(BOOL)reportAttachments
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _resultBundlePath = resultBundlePath;
  _coveragePath = coveragePath;
  _logDirectoryPath = logDirectoryPath;
  _binaryPath = binaryPath;
  _reportAttachments = reportAttachments;

  return self;
}

@end
