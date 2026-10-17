#!/bin/zsh
# Publish — build, zip, and create a GitHub Release in one command
# Usage: ./scripts/publish.sh 0.12.0-fork.1
set -e
cd "$(dirname "$0")/.."

TAG="${1:?⚠️ Usage: ./scripts/publish.sh <tag>}"

gh auth status >/dev/null 2>&1 || {
    echo "⚠️ Not logged in. Run: gh auth login"
    exit 1
}

./scripts/release.sh "$TAG"

gh release create "$TAG" "dist/Ice-$TAG.zip" --generate-notes

echo ""
echo "🎉 Release $TAG published!"
gh release view "$TAG"
