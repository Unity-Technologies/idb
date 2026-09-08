#!/usr/bin/env bash
# Builds the frameworks Unity ships and collects them into an output directory.
#
# Upstream's build.sh dropped the `framework build <output>` subcommand that
# used to both build and install, so the collect step lives here rather than as
# a fork-local patch to build.sh.
#
# Usage: .yamato/build-frameworks.sh <output-directory>

set -euo pipefail

output_directory=${1:?usage: $0 <output-directory>}

cd "$(dirname "$0")/.."

# Unity ships universal frameworks; upstream's build.sh defaults to arm64 only.
export IDB_ARCHS="arm64 x86_64"

./build.sh build frameworks

frameworks_directory="$output_directory/Frameworks"
mkdir -p "$frameworks_directory"

for name in FBControlCore XCTestBootstrap FBSimulatorControl FBDeviceControl; do
  artifact="Build/Products/Debug/$name.framework"
  if [ ! -d "$artifact" ]; then
    echo "error: expected build product not found: $artifact"
    exit 1
  fi
  echo "Copying $artifact to $frameworks_directory"
  cp -R "$artifact" "$frameworks_directory/"
done
