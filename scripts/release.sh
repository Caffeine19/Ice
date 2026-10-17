#!/bin/zsh
# Release App — Release build & package zip
# Usage: ./scripts/release.sh 0.12.0-fork.1
set -e
cd "$(dirname "$0")/.."

TAG="${1:?⚠️ Usage: ./scripts/release.sh <tag>}"

# ENABLE_HARDENED_RUNTIME=NO is required: ad-hoc signed Sparkle has no Team ID,
# so hardened runtime library validation kills the app at launch.
# Signed with the Apple Development cert (team HMNPYJ4S3K) so TCC grants survive rebuilds.
xcodebuild \
  -project Ice.xcodeproj \
  -scheme Ice \
  -configuration Release \
  -sdk macosx \
  -derivedDataPath build \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=HMNPYJ4S3K \
  ENABLE_HARDENED_RUNTIME=NO \
  build

mkdir -p dist
rm -f "dist/Ice-$TAG.zip"
ditto -c -k --keepParent \
  "build/Build/Products/Release/Ice.app" \
  "dist/Ice-$TAG.zip"

echo ""
echo "✅ dist/Ice-$TAG.zip"
