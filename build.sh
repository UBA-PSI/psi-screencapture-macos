#!/bin/sh
# Builds screenrec as a universal binary (arm64 + x86_64) that runs on macOS 13 and later.
set -eu
cd "$(dirname "$0")"

FLAGS="-O -swift-version 5 -parse-as-library"
swiftc $FLAGS -target arm64-apple-macos13.0  screenrec.swift -o screenrec-arm64
swiftc $FLAGS -target x86_64-apple-macos13.0 screenrec.swift -o screenrec-x86_64
lipo -create screenrec-arm64 screenrec-x86_64 -output screenrec
rm screenrec-arm64 screenrec-x86_64
# Ad-hoc signature for both architectures (the linker signs arm64 only).
codesign --force --sign - screenrec

lipo -info screenrec
otool -l screenrec | grep -A3 LC_BUILD_VERSION
