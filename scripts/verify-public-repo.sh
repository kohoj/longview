#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
allowed_top_level=(
    .github
    .gitignore
    .swift-format
    CHANGELOG.md
    CODE_OF_CONDUCT.md
    CONTRIBUTING.md
    Fixtures
    LICENSE
    Package.swift
    PRIVACY.md
    README.md
    README.zh-CN.md
    SECURITY.md
    Sources
    Tests
    docs
    scripts
)

while IFS= read -r -d '' entry_path; do
    name="${entry_path:t}"
    case "$name" in
        .git|.build|.swiftpm|.DS_Store) continue ;;
    esac
    if (( ! ${allowed_top_level[(Ie)$name]} )); then
        print -u2 -- "unexpected top-level repository entry: $name"
        exit 1
    fi
done < <(find "$project_root" -mindepth 1 -maxdepth 1 -print0)

required_files=(
    LICENSE
    README.md
    PRIVACY.md
    SECURITY.md
    CONTRIBUTING.md
    .swift-format
    Package.swift
)
for relative_path in $required_files; do
    if [[ ! -f "$project_root/$relative_path" ]]; then
        print -u2 -- "required public project file is missing: $relative_path"
        exit 1
    fi
done

large_file=$(find "$project_root" \
    -path "$project_root/.git" -prune -o \
    -path "$project_root/.build" -prune -o \
    -type f -size +1M -print -quit)
if [[ -n "$large_file" ]]; then
    print -u2 -- "unexpected file larger than 1 MiB: $large_file"
    exit 1
fi

captured_media=$(find "$project_root" \
    -path "$project_root/.git" -prune -o \
    -path "$project_root/.build" -prune -o \
    -type f \( \
        -iname '*.gif' -o -iname '*.heic' -o -iname '*.jpeg' -o \
        -iname '*.jpg' -o -iname '*.mov' -o -iname '*.mp4' -o \
        -iname '*.pdf' -o -iname '*.png' -o -iname '*.webp' \
    \) -print -quit)
if [[ -n "$captured_media" ]]; then
    print -u2 -- "captured or generated media is not allowed in the source repository: $captured_media"
    exit 1
fi

credential_match=$(grep -R -I -n -E \
    --exclude-dir=.git --exclude-dir=.build \
    -- '-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[opsu]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}' \
    "$project_root" | head -n 1 || true)
if [[ -n "$credential_match" ]]; then
    print -u2 -- "credential-like material found in repository: $credential_match"
    exit 1
fi

print -r -- "public repository boundary verified"
