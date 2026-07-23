#!/bin/sh

longview_die() {
    printf '%s\n' "longview: $*" >&2
    exit 1
}

longview_resolve_prefix() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) longview_die "--prefix must be an absolute path" ;;
    esac
}

longview_require_macos() {
    [ "$(uname -s)" = "Darwin" ] || longview_die "Longview requires macOS"
    [ "$(id -u)" -ne 0 ] || longview_die "refusing to run as root; use a user-writable prefix"
    command -v plutil >/dev/null 2>&1 || longview_die "plutil is missing"
    command -v shasum >/dev/null 2>&1 || longview_die "shasum is missing"

    longview_macos_major=$(sw_vers -productVersion | awk -F. '{print $1}')
    [ "$longview_macos_major" -ge 14 ] 2>/dev/null \
        || longview_die "Longview requires macOS 14 or newer"
}

longview_require_build_tools() {
    command -v swift >/dev/null 2>&1 || longview_die "Swift is missing; run: xcode-select --install"
    command -v codesign >/dev/null 2>&1 || longview_die "codesign is missing; install Xcode Command Line Tools"
}

longview_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

longview_binary_version() {
    "$1" version 2>/dev/null \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
}

longview_sign_locally() {
    codesign --force --sign - --timestamp=none "$1" >/dev/null 2>&1 \
        || longview_die "failed to apply a local ad-hoc signature to $1"
    codesign --verify --strict "$1" >/dev/null 2>&1 \
        || longview_die "local ad-hoc signature verification failed for $1"
}

longview_receipt_value() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

longview_acquire_lock() {
    longview_lock_path="$1/share/longview/.transaction-lock"
    mkdir -p "$1/share/longview"
    if ! mkdir "$longview_lock_path" 2>/dev/null; then
        longview_die "another install, update, or uninstall transaction may be active: $longview_lock_path"
    fi
    printf '%s\n' "$$" > "$longview_lock_path/pid"
}

longview_release_lock() {
    if [ -n "${longview_lock_path:-}" ] && [ -d "$longview_lock_path" ]; then
        rm -f "$longview_lock_path/pid"
        rmdir "$longview_lock_path" 2>/dev/null || true
    fi
}
