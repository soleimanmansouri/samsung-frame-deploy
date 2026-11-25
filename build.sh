#!/bin/sh
# Builds FrameDeploy.app (self-contained: copy it to any Apple-silicon Mac, macOS 13+).
set -e
cd "$(dirname "$0")"
(cd app && swift build -c release)
A=FrameDeploy.app/Contents
mkdir -p $A/MacOS $A/Resources
cp app/.build/release/FrameDeploy $A/MacOS/FrameDeploy
cp frame.py $A/Resources/frame.py
cp Info.plist $A/Info.plist
codesign --force --deep -s - FrameDeploy.app
echo "built FrameDeploy.app"
