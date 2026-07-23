#!/bin/sh

set -eu
umask 077

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
project_root=$(CDPATH= cd "$script_dir/.." && pwd)
. "$script_dir/lib/distribution.sh"

prefix=${LONGVIEW_PREFIX:-"$HOME/.local"}
requested_tag=""
check_only=0
dry_run=0

usage() {
    cat <<'EOF'
Usage: ./scripts/update.sh [--to vX.Y.Z] [--prefix DIR] [--check] [--dry-run]

Resolve an immutable release tag from origin, clone it into a temporary
directory, and reuse Longview's transactional installer. Moving branches are
never installed.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --to)
            [ "$#" -ge 2 ] || longview_die "missing value for --to"
            requested_tag=$2
            shift 2
            ;;
        --prefix)
            [ "$#" -ge 2 ] || longview_die "missing value for --prefix"
            prefix=$2
            shift 2
            ;;
        --check) check_only=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) longview_die "unknown option: $1" ;;
    esac
done

prefix=$(longview_resolve_prefix "$prefix")
longview_require_macos
command -v git >/dev/null 2>&1 || longview_die "git is required for source updates"

remote=$(git -C "$project_root" remote get-url origin 2>/dev/null || true)
[ -n "$remote" ] || longview_die "this checkout has no origin remote"

if [ -n "$requested_tag" ]; then
    printf '%s\n' "$requested_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        || longview_die "--to must be a stable SemVer tag such as v0.3.1"
    tag=$requested_tag
else
    tag=$(git ls-remote --tags --refs "$remote" 'refs/tags/v*' \
        | awk '{sub("refs/tags/", "", $2); print $2}' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V \
        | tail -n 1 || true)
    [ -n "$tag" ] || longview_die "origin has no stable vX.Y.Z release tags"
fi

current_version="not-installed"
receipt="$prefix/share/longview/install-receipt.json"
if [ -f "$receipt" ]; then
    current_version=$(longview_receipt_value "$receipt" version || true)
fi

if [ "$check_only" -eq 1 ]; then
    printf '%s\n' "Current: $current_version"
    printf '%s\n' "Latest:  ${tag#v}"
    printf '%s\n' "Tag:     $tag"
    exit 0
fi

update_directory=$(mktemp -d "${TMPDIR:-/tmp}/longview-update.XXXXXX")
cleanup() {
    if [ -n "${update_directory:-}" ] && [ -d "$update_directory" ]; then
        rm -rf "$update_directory"
    fi
}
trap cleanup 0 HUP INT TERM

checkout="$update_directory/repository"
git clone --quiet --no-checkout -- "$remote" "$checkout"
git -C "$checkout" -c advice.detachedHead=false checkout --quiet "$tag^{}"
source_version=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' \
    "$checkout/Sources/LongviewCLIKit/LongviewBuildInfo.swift")
[ "$source_version" = "${tag#v}" ] \
    || longview_die "release tag $tag does not match source version ${source_version:-unknown}"

if [ "$dry_run" -eq 1 ]; then
    "$checkout/scripts/install.sh" --prefix "$prefix" --dry-run
else
    "$checkout/scripts/install.sh" --prefix "$prefix"
fi
