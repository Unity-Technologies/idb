/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <FBControlCore/FBControlCore.h>

NS_ASSUME_NONNULL_BEGIN

@class FBDevice;

/**
 An Implementation of FBApplicationCommands for Devices
 */
@interface FBDeviceApplicationCommands : NSObject <FBApplicationCommands>
/**
 Instantiates the Commands instance.

 @param target the target to use.
 @return a new instance of the Command.
 */
+ (instancetype)commandsWithTarget:(FBDevice *)target;
- (FBFuture<NSNull *> *)deltaInstallApplicationWithPath:(NSString *)path andShadowDirectory:(NSString *)shadowDir;

@end

NS_ASSUME_NONNULL_END
