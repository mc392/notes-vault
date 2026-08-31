#!/bin/sh
# Xcode Cloud clones the bare repository, and NotesVault.xcodeproj is gitignored
# (it's generated from project.yml — see .gitignore). Without this, Xcode Cloud
# fails immediately with "Project NotesVault.xcodeproj does not exist at the
# root of the repository". Regenerate it here before the build starts.
set -e

brew install xcodegen

cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
