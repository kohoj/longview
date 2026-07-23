#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
command -v jq >/dev/null 2>&1 || {
    print -u2 -- "jq is required for repository verification"
    exit 1
}
verification_scratch=$(mktemp -d /tmp/longview-verification.XXXXXX)
trap '/bin/rm -rf -- "$verification_scratch"' EXIT

"$project_root/scripts/verify-public-repo.sh"
swift format lint --strict --recursive \
    "$project_root/Sources" \
    "$project_root/Tests" \
    "$project_root/Fixtures" \
    "$project_root/Package.swift"
swift test --package-path "$project_root" --scratch-path "$verification_scratch"
swift build \
    --package-path "$project_root" \
    --scratch-path "$verification_scratch" \
    --configuration release \
    --product longview

binary_directory=$(swift build \
    --package-path "$project_root" \
    --scratch-path "$verification_scratch" \
    --configuration release \
    --show-bin-path)
binary_path="$binary_directory/longview"
product_sources=(
    "$project_root/Sources/LongviewCore"
    "$project_root/Sources/LongviewCapture"
    "$project_root/Sources/LongviewCLIKit"
    "$project_root/Sources/LongviewCLI"
)

expected_architecture="${LONGVIEW_EXPECTED_ARCH:-$(uname -m)}"
if ! file "$binary_path" | grep -q "Mach-O 64-bit executable $expected_architecture"; then
    print -u2 -- "release architecture does not match $expected_architecture"
    exit 1
fi
if ! vtool -show-build "$binary_path" | grep -Eq 'minos[[:space:]]+14\.0'; then
    print -u2 -- "release binary does not preserve the macOS 14.0 deployment target"
    exit 1
fi

if nm -u "$binary_path" | grep -E \
    '_CGS|_SLS|SkyLight|SLEvent|_AXUIElementGetWindow|CGWindowListCreateImage|VNRecognize'; then
    print -u2 -- "forbidden private, legacy capture, or OCR symbol found in product binary"
    exit 1
fi

if otool -L "$binary_path" | grep -E \
    'PrivateFrameworks|SkyLight|Vision\.framework|SwiftUI\.framework'; then
    print -u2 -- "forbidden private, OCR, or UI framework found in product binary"
    exit 1
fi

if grep -R -n -E \
    'SkyLight|_CGS|_SLS|PrivateFrameworks|CGWindowListCreateImage|Vision|VNRecognize|Cua|Agent-S|pyautogui' \
    $product_sources; then
    print -u2 -- "forbidden implementation found in product source"
    exit 1
fi

if grep -R -n -E \
    'SwiftUI|MenuBarExtra|NSSavePanel|NSOpenPanel|NSWindow|NSStatusItem|Carbon' \
    $product_sources; then
    print -u2 -- "UI implementation escaped into the CLI product"
    exit 1
fi

if ! otool -L "$binary_path" | grep -q 'ScreenCaptureKit'; then
    print -u2 -- "longshot capability is missing ScreenCaptureKit"
    exit 1
fi

if grep -R -n -E \
    'URLSession|NWConnection|CFStreamCreatePairWithSocket|socket\(' \
    $product_sources; then
    print -u2 -- "CLI product exposes a network path"
    exit 1
fi

event_matches=$(grep -R -n -E \
    'CGEventPost|postToPid|\.post\(tap:|scrollWheelEvent2Source' \
    $product_sources | grep -v '/SystemScrollEventPoster.swift:' || true)
if [[ -n "$event_matches" ]]; then
    print -u2 -- "$event_matches"
    print -u2 -- "event injection escaped SystemScrollEventPoster"
    exit 1
fi

mutation_matches=$(grep -R -n -E \
    'AXUIElementSetAttributeValue|AXUIElementPerformAction|CGWarpMouseCursorPosition|CGAssociateMouseAndMouseCursorPosition|\.activate\(options:' \
    $product_sources | grep -v '/WindowScrollSessions.swift:' || true)
if [[ -n "$mutation_matches" ]]; then
    print -u2 -- "$mutation_matches"
    print -u2 -- "longshot mutation escaped WindowScrollSessions"
    exit 1
fi

if grep -n -E \
    'mouseEventSource|keyboardEventSource|NSPasteboard|AXUIElementPerformAction|kAXPressAction|mouseEvent|keyboardEvent|leftMouse|rightMouse|keyDown|keyUp|activate\(' \
    "$project_root/Sources/LongviewCore/SystemScrollEventPoster.swift"; then
    print -u2 -- "scroll poster exposes a broader mutation surface"
    exit 1
fi

capabilities_json="$verification_scratch/capabilities.json"
"$binary_path" capabilities > "$capabilities_json"
jq -e '
    .schemaVersion == 2 and
    .type == "result" and
    .result.schemaVersion == 2 and
    .result.longshot.backgroundCapture == true and
    .result.longshot.capturePacing == "capture-verified-adaptive" and
    .result.longshot.frameSource == "ScreenCaptureKit.SCStream" and
    .result.longshot.overlapPolicy == "online-validated-minimum-24-percent" and
    .result.longshot.settleMillisecondsSemantics == "maximum-frame-stability-wait" and
    .result.longshot.defaultFocusPolicy == "background-first" and
    (.result.longshot.targetSelectors | index("window-id")) != null and
    (.result.longshot.scrollRoutes | index("accessibility-value")) != null and
    (.result.longshot.scrollRoutes | index("foreground-event")) != null
' "$capabilities_json" >/dev/null

doctor_json="$verification_scratch/doctor.json"
"$binary_path" doctor > "$doctor_json"
jq -e '.command == "doctor" and .result.schemaVersion == 2' "$doctor_json" >/dev/null

version_json="$verification_scratch/version.json"
"$binary_path" version > "$version_json"
source_version=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' \
    "$project_root/Sources/LongviewCLIKit/LongviewBuildInfo.swift")
[[ "$(jq -r '.result.version' "$version_json")" == "$source_version" ]]

package_json="$verification_scratch/package.json"
swift package --package-path "$project_root" dump-package > "$package_json"
[[ "$(jq '[.products[] | select(.name == "longview")] | length' "$package_json")" == "1" ]]
if jq -e '[.products[] | select(.name == "LongviewFixtureApp")] | length != 0' "$package_json" >/dev/null; then
    print -u2 -- "validation fixture escaped into distributed products"
    exit 1
fi

usage_json="$verification_scratch/usage.json"
set +e
"$binary_path" longshot 2> "$usage_json"
usage_exit=$?
set -e
if [[ "$usage_exit" -ne 64 ]]; then
    print -u2 -- "missing longshot output did not return EX_USAGE (64)"
    exit 1
fi
jq -e '.type == "error"' "$usage_json" >/dev/null

"$project_root/Tests/DistributionTests/run.sh"

print -r -- "verification passed: public boundary, dual-arch-ready release contract, tests, schema v2, doctor, installation lifecycle, public APIs, no UI/OCR/network, and bounded scroll mutation"
