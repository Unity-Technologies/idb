/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBDeviceControl/FBAFCConnection.h>
#import <FBDeviceControl/FBAMDServiceConnection.h>
#import <FBDeviceControl/FBAMDefines.h>
#import <FBDeviceControl/FBAMDevice.h>
#import <FBDeviceControl/FBAMDeviceManager.h>
#import <FBDeviceControl/FBAMRestorableDevice.h>
#import <FBDeviceControl/FBAMRestorableDeviceManager.h>
#import <FBDeviceControl/FBDevice.h>
#import <FBDeviceControl/FBDeviceCommands.h>
#import <FBDeviceControl/FBDeviceControlFrameworkLoader.h>
#import <FBDeviceControl/FBDeviceDebugSymbolsCommands.h>
#import <FBDeviceControl/FBDeviceManager.h>
#import <FBDeviceControl/FBInstrumentsClient.h>

// Fork-local: the generated Swift header refers to types from these
// frameworks, but only @imports them under Clang modules, which are not
// enabled in Objective-C++ translation units such as Unity's Pram.
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

#if __has_include(<FBDeviceControl/FBDeviceControl-Swift.h>)
 #import <FBDeviceControl/FBDeviceControl-Swift.h>
#endif
