#!/bin/zsh
# Verify Build — Debug build only (no launch)
set -e
cd "$(dirname "$0")/.."

xcodebuild \
  -project Ice.xcodeproj \
  -scheme Ice \
  -configuration Debug \
  -sdk macosx \
  -derivedDataPath build \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=HMNPYJ4S3K \
  ENABLE_HARDENED_RUNTIME=NO \
  build
