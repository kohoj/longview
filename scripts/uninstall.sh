#!/bin/sh

set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
if [ -f "$script_dir/lib/distribution.sh" ]; then
    . "$script_dir/lib/distribution.sh"
else
    printf '%s\n' "longview: distribution helper is missing" >&2
    exit 1
fi

prefix=${LONGVIEW_PREFIX:-"$HOME/.local"}
force=0
dry_run=0

usage() {
    cat <<'EOF'
Usage: uninstall.sh [--prefix DIR] [--force] [--dry-run]

Remove only files recorded by Longview's source installer.
Screenshots, shell configuration, caches, and macOS permissions are never removed.
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

destination="$prefix/bin/longview"
share_directory="$prefix/share/longview"
receipt="$share_directory/install-receipt.json"
doc_directory="$prefix/share/doc/longview"

[ -f "$receipt" ] || longview_die "managed installation receipt not found: $receipt"
[ ! -L "$destination" ] || longview_die "refusing to remove symbolic link: $destination"
[ -f "$destination" ] || longview_die "managed executable not found: $destination"

receipt_product=$(longview_receipt_value "$receipt" product)
receipt_path=$(longview_receipt_value "$receipt" executablePath)
receipt_hash=$(longview_receipt_value "$receipt" sha256)
[ "$receipt_product" = "longview" ] || longview_die "receipt product is not Longview"
[ "$receipt_path" = "$destination" ] || longview_die "receipt points to a different executable"

installed_hash=$(longview_sha256 "$destination")
if [ "$installed_hash" != "$receipt_hash" ] && [ "$force" -ne 1 ]; then
    longview_die "installed binary was modified; pass --force to remove it"
fi

if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' "Would remove managed Longview installation"
    printf '%s\n' "  binary:  $destination"
    printf '%s\n' "  receipt: $receipt"
    exit 0
fi

longview_acquire_lock "$prefix"
trap longview_release_lock 0 HUP INT TERM

rm -f "$destination"
rm -f "$receipt" "$doc_directory/LICENSE"
rm -f "$share_directory/uninstall.sh" "$share_directory/lib/distribution.sh"
longview_release_lock
trap - 0 HUP INT TERM
rmdir "$share_directory/lib" 2>/dev/null || true
rmdir "$share_directory" 2>/dev/null || true
rmdir "$doc_directory" 2>/dev/null || true
rmdir "$prefix/share/doc" 2>/dev/null || true
rmdir "$prefix/bin" 2>/dev/null || true

printf '%s\n' "Uninstalled Longview from $prefix"
printf '%s\n' "Screenshots and permissions for the invoking Terminal or agent host were left untouched."
