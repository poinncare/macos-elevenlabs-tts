#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
stage="$(mktemp -d .tts-build.XXXXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/TTS.app/Contents/MacOS"
cp Info.plist "$stage/TTS.app/Contents/Info.plist"
/usr/bin/clang -fobjc-arc -O2 -mmacosx-version-min=14.0 \
    -framework AppKit -framework AVFoundation main.m -o "$stage/TTS.app/Contents/MacOS/TTS"
/usr/bin/codesign --force --sign - "$stage/TTS.app"
if [[ -e TTS.app ]]; then
    mv TTS.app "$stage/previous.app"
fi
mv "$stage/TTS.app" TTS.app
