#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"

swift build \
    --package-path "$project_root" \
    --configuration release \
    --product longview

binary_directory=$(swift build \
    --package-path "$project_root" \
    --configuration release \
    --show-bin-path)
binary_path="$binary_directory/longview"

codesign --verify --strict --verbose=2 "$binary_path"
print -r -- "$binary_path"
