#!/bin/zsh
# Run App — Debug build & launch
set -e
cd "$(dirname "$0")/.."

# Quit any running instance first (same bundle id would clash on open)
osascript -e 'tell application "Ice" to quit' >/dev/null 2>&1 || true
for i in {1..20}; do
  pgrep -x Ice >/dev/null 2>&1 || break
  sleep 0.25
done

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

open "build/Build/Products/Debug/Ice.app"
