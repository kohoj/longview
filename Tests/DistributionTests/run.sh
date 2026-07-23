#!/bin/sh

set -eu
umask 077

project_root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
expected_version=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' \
    "$project_root/Sources/LongviewCLIKit/LongviewBuildInfo.swift")
test_root=$(mktemp -d "${TMPDIR:-/tmp}/longview-distribution.XXXXXX")
cleanup() {
    if [ -n "${test_root:-}" ] && [ -d "$test_root" ]; then
        rm -rf "$test_root"
    fi
}
trap cleanup 0 HUP INT TERM

prefix="$test_root/prefix with spaces"
mkdir -p "$prefix/bin"
sentinel="$prefix/bin/keep-me"
printf '%s\n' "sentinel" > "$sentinel"

"$project_root/scripts/install.sh" --prefix "$prefix" >/dev/null
binary="$prefix/bin/longview"
receipt="$prefix/share/longview/install-receipt.json"
[ -x "$binary" ]
[ -f "$receipt" ]
[ "$(plutil -extract product raw -o - "$receipt")" = "longview" ]
[ "$(plutil -extract version raw -o - "$receipt")" = "$expected_version" ]
[ "$(plutil -extract executablePath raw -o - "$receipt")" = "$binary" ]
[ "$(shasum -a 256 "$binary" | awk '{print $1}')" \
    = "$(plutil -extract sha256 raw -o - "$receipt")" ]
"$binary" version | grep -q "\"version\":\"$expected_version\""
doctor_output=$("$binary" doctor)
printf '%s\n' "$doctor_output" | grep -q '"managed":true'
printf '%s\n' "$doctor_output" | grep -q '"receiptMatchesBinary":true'

# A managed reinstall is idempotent and keeps unrelated siblings.
before_hash=$(shasum -a 256 "$binary" | awk '{print $1}')
"$project_root/scripts/install.sh" --prefix "$prefix" >/dev/null
after_hash=$(shasum -a 256 "$binary" | awk '{print $1}')
[ "$before_hash" = "$after_hash" ]
[ -f "$sentinel" ]

# A modified managed binary is preserved unless force is explicit.
printf '%s' "modified" >> "$binary"
if "$project_root/scripts/uninstall.sh" --prefix "$prefix" >/dev/null 2>&1; then
    printf '%s\n' "uninstall unexpectedly removed a modified binary" >&2
    exit 1
fi
[ -f "$binary" ]

"$project_root/scripts/uninstall.sh" --prefix "$prefix" --force >/dev/null
[ ! -e "$binary" ]
[ ! -e "$receipt" ]
[ -f "$sentinel" ]

# Update must resolve and install an immutable tag without mutating its checkout.
update_source="$test_root/update-source"
update_origin="$test_root/update-origin.git"
update_checkout="$test_root/update-checkout"
update_prefix="$test_root/update prefix"
mkdir -p "$update_source"
rsync -a --exclude .git --exclude .build "$project_root/" "$update_source/"
git -C "$update_source" init -q -b main
git -C "$update_source" config user.name "Longview Distribution Test"
git -C "$update_source" config user.email "distribution-test@invalid.example"
git -C "$update_source" add .
git -C "$update_source" commit -q -m "fixture source release"
git -C "$update_source" tag -a "v$expected_version" -m "fixture release"
git clone -q --bare "$update_source" "$update_origin"
git clone -q "$update_origin" "$update_checkout"

"$update_checkout/scripts/update.sh" --check --prefix "$update_prefix" \
    | grep -q "Latest:  $expected_version"
"$update_checkout/scripts/update.sh" --to "v$expected_version" \
    --prefix "$update_prefix" >/dev/null
[ -x "$update_prefix/bin/longview" ]
[ "$(plutil -extract gitTag raw -o - "$update_prefix/share/longview/install-receipt.json")" \
    = "v$expected_version" ]

printf '%s\n' "distribution tests passed: managed install, receipt, doctor, idempotence, guarded uninstall, immutable-tag update"
