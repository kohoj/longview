#!/bin/sh

set -eu
umask 077

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
project_root=$(CDPATH= cd "$script_dir/.." && pwd)
. "$script_dir/lib/distribution.sh"

prefix=${LONGVIEW_PREFIX:-"$HOME/.local"}
force=0
dry_run=0

usage() {
    cat <<'EOF'
Usage: ./scripts/install.sh [--prefix DIR] [--force] [--dry-run]

Build and atomically install Longview from this checkout.
The default prefix is $HOME/.local. The script never invokes sudo or edits PATH.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || longview_die "missing value for --prefix"
            prefix=$2
            shift 2
            ;;
        --force) force=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) longview_die "unknown option: $1" ;;
    esac
done

prefix=$(longview_resolve_prefix "$prefix")
longview_require_macos
longview_require_build_tools

printf '%s\n' "Building Longview from $project_root" >&2
swift build --package-path "$project_root" --configuration release --product longview
binary_directory=$(swift build \
    --package-path "$project_root" \
    --configuration release \
    --show-bin-path)
candidate="$binary_directory/longview"
[ -x "$candidate" ] || longview_die "release build did not produce $candidate"
codesign --verify --strict "$candidate" 2>/dev/null \
    || longview_die "candidate binary has an invalid local signature"

version=$(longview_binary_version "$candidate")
[ -n "$version" ] || longview_die "candidate did not return the Longview version protocol"
candidate_hash=$(longview_sha256 "$candidate")

bin_directory="$prefix/bin"
share_directory="$prefix/share/longview"
doc_directory="$prefix/share/doc/longview"
destination="$bin_directory/longview"
receipt="$share_directory/install-receipt.json"

if [ -L "$destination" ]; then
    longview_die "refusing to replace symbolic link: $destination"
fi
if [ -e "$destination" ] && [ ! -f "$destination" ]; then
    longview_die "refusing to replace non-regular path: $destination"
fi
if [ -f "$destination" ] && [ ! -f "$receipt" ] && [ "$force" -ne 1 ]; then
    longview_die "an unmanaged binary already exists at $destination; pass --force to replace it"
fi

if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' "Would install Longview $version"
    printf '%s\n' "  binary:  $destination"
    printf '%s\n' "  receipt: $receipt"
    printf '%s\n' "  sha256:  $candidate_hash"
    exit 0
fi

mkdir -p "$bin_directory" "$share_directory/lib" "$doc_directory"
longview_acquire_lock "$prefix"
transaction_directory=$(mktemp -d "$prefix/.longview-install.XXXXXX")
cleanup() {
    if [ -n "${transaction_directory:-}" ] && [ -d "$transaction_directory" ]; then
        rm -rf "$transaction_directory"
    fi
    longview_release_lock
}
trap cleanup 0 HUP INT TERM

staged_binary="$transaction_directory/longview"
staged_receipt="$transaction_directory/install-receipt.json"
/usr/bin/install -m 0755 "$candidate" "$staged_binary"

git_commit=""
git_tag=""
source_remote=""
if command -v git >/dev/null 2>&1 && git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_commit=$(git -C "$project_root" rev-parse HEAD 2>/dev/null || true)
    git_tag=$(git -C "$project_root" describe --tags --exact-match HEAD 2>/dev/null || true)
    candidate_remote=$(git -C "$project_root" remote get-url origin 2>/dev/null || true)
    case "$candidate_remote" in
        https://github.com/*|git@github.com:*|ssh://git@github.com/*)
            source_remote=$candidate_remote
            ;;
        *) source_remote="" ;;
    esac
fi

plutil -create xml1 "$staged_receipt"
plutil -insert schemaVersion -integer 1 "$staged_receipt"
plutil -insert product -string longview "$staged_receipt"
plutil -insert version -string "$version" "$staged_receipt"
plutil -insert gitTag -string "$git_tag" "$staged_receipt"
plutil -insert gitCommit -string "$git_commit" "$staged_receipt"
plutil -insert sourceRemote -string "$source_remote" "$staged_receipt"
plutil -insert installedAt -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$staged_receipt"
plutil -insert prefix -string "$prefix" "$staged_receipt"
plutil -insert executablePath -string "$destination" "$staged_receipt"
plutil -insert sha256 -string "$candidate_hash" "$staged_receipt"
plutil -insert build -dictionary "$staged_receipt"
plutil -insert build.swiftVersion -string "$(swift --version 2>&1 | sed -n '1p')" "$staged_receipt"
plutil -insert build.macOSVersion -string "$(sw_vers -productVersion)" "$staged_receipt"
plutil -insert build.architecture -string "$(uname -m)" "$staged_receipt"
plutil -convert json "$staged_receipt"
chmod 0644 "$staged_receipt"

/usr/bin/install -m 0644 "$project_root/LICENSE" "$doc_directory/LICENSE"
/usr/bin/install -m 0755 "$script_dir/uninstall.sh" "$share_directory/uninstall.sh"
/usr/bin/install -m 0644 "$script_dir/lib/distribution.sh" "$share_directory/lib/distribution.sh"

staged_destination="$bin_directory/.longview.new.$$"
staged_receipt_destination="$share_directory/.install-receipt.new.$$"
mv "$staged_binary" "$staged_destination"
mv "$staged_receipt" "$staged_receipt_destination"
mv -f "$staged_destination" "$destination"
mv -f "$staged_receipt_destination" "$receipt"

installed_hash=$(longview_sha256 "$destination")
[ "$installed_hash" = "$candidate_hash" ] || longview_die "installed binary checksum mismatch"
[ "$(longview_binary_version "$destination")" = "$version" ] \
    || longview_die "installed binary version mismatch"

printf '%s\n' "Installed Longview $version"
printf '%s\n' "  binary:  $destination"
printf '%s\n' "  receipt: $receipt"
printf '%s\n' "  sha256:  $installed_hash"
case ":${PATH:-}:" in
    *":$bin_directory:"*) ;;
    *)
        printf '\n%s\n' "Add Longview to this shell:"
        printf '  export PATH="%s/bin:$PATH"\n' "$prefix"
        ;;
esac
printf '\n%s\n' "Next: longview doctor --pretty"
