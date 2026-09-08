/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/// Fork-local: the Objective-C surface that Unity's Pram consumes.
///
/// Upstream rewrote the command classes in Swift and moved their API to
/// async/await, which left them invisible to Objective-C callers. Pram's
/// idb-interface is Objective-C++ and chains `FBFuture`s, so the protocols it
/// names are redeclared here under their historical Objective-C names, with
/// the `FBFuture`-returning shapes it expects. The Swift names carry a
/// `Unity` prefix only to avoid colliding with upstream's own protocols.
///
/// Conformances are annotated on the upstream types themselves; see
/// FBDeviceFileContainer, FBDeviceLogOperation and FBDeviceLaunchedApplication.

import Foundation

/// Historical `FBiOSTargetOperation`: an operation of indeterminate length.
@objc(FBiOSTargetOperation)
public protocol UnityTargetOperation: NSObjectProtocol {

  /// A future that resolves when the operation has completed.
  @objc var completed: FBFuture<NSNull> { get }
}

/// Historical `FBLaunchedApplication`.
@objc(FBLaunchedApplication)
public protocol UnityLaunchedApplication: NSObjectProtocol {

  /// The bundle identifier of the launched application.
  @objc var bundleID: String { get }

  /// The process identifier of the launched application.
  @objc var processIdentifier: pid_t { get }
}

/// Historical `FBFileContainer`, in its `FBFuture` form.
@objc(FBFileContainer)
public protocol UnityFileContainer: NSObjectProtocol {

  @objc(copyFromHost:toContainer:)
  func copyFromHost(_ sourcePath: String, toContainer destinationPath: String) -> FBFuture<NSNull>

  @objc(copyFromContainer:toHost:)
  func copyFromContainer(_ sourcePath: String, toHost destinationPath: String) -> FBFuture<NSString>

  @objc(createDirectory:)
  func createDirectory(_ directoryPath: String) -> FBFuture<NSNull>

  @objc(remove:)
  func remove(_ path: String) -> FBFuture<NSNull>

  @objc(contentsOfDirectory:)
  func contentsOfDirectory(_ path: String) -> FBFuture<NSArray>
}
