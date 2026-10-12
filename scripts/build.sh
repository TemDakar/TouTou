#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p dist/Toutu.app/Contents/MacOS
mkdir -p dist/Toutu.app/Contents/Resources
cp scripts/fetch_usage.py dist/Toutu.app/Contents/Resources/fetch_usage.py
cp .build/release/Toutu dist/Toutu.app/Contents/MacOS/Toutu
cp scripts/Info.plist dist/Toutu.app/Contents/Info.plist
codesign --force --sign - dist/Toutu.app
rm -f dist/Toutu.app.zip
ditto -c -k --keepParent dist/Toutu.app dist/Toutu.app.zip
printf 'Готово: %s/dist/Toutu.app (архив для Releases: dist/Toutu.app.zip)\n' "$PWD"
