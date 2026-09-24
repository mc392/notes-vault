#!/bin/sh
# Generates NotesVault.xcodeproj from project.yml, with the dependency versions pinned.
#
# `Package.resolved` at the root pins `swift test`. Xcode does not read it for the app:
# a generated project keeps its own copy inside the project bundle, and with none there it
# resolves afresh — so without this copy, the build that goes to TestFlight could link a
# cryptolib-swift release nobody has reviewed, while the tests ran against the pinned one.
# Every path that builds the app (CI, TestFlight, Xcode Cloud, a Mac by hand) runs this
# rather than `xcodegen generate` alone.
set -e

cd "$(dirname "$0")/.."
xcodegen generate

resolved_dir="NotesVault.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolved_dir"
cp Package.resolved "$resolved_dir/Package.resolved"
