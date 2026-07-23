#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
. "$project_root/scripts/lib/distribution.sh"
longview_require_build_tools

swift build \
    --package-path "$project_root" \
    --configuration release \
    --product longview

binary_directory=$(swift build \
    --package-path "$project_root" \
    --configuration release \
    --show-bin-path)
binary_path="$binary_directory/longview"

longview_sign_locally "$binary_path"
print -r -- "$binary_path"
