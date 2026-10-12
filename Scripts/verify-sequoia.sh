#!/bin/bash
# Prove the app still builds for its macOS 15 floor. The compiler reports one availability error per
# run, so a macOS 26-only API that slipped in unguarded surfaces here, never on a user's Sequoia Mac.
#
#   ./Scripts/verify-sequoia.sh           # typecheck at 15 and 26, then Release build + artifact checks
#   ./Scripts/verify-sequoia.sh --quick   # typecheck only
#
# Exit codes: 0 ok · 2 compile or availability error · 3 wrong artifact
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
# The Command Line Tools lack the SwiftUI macro plugins (`@Entry`, `@State`), so use Xcode's toolchain.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" != *.app/* ]]; then
    XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -n1)"
    [ -n "$XCODE" ] || { echo "✗ Xcode not found in /Applications; install Xcode 26" >&2; exit 2; }
    export DEVELOPER_DIR="$XCODE/Contents/Developer"
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

# The same split project.yml makes: the helpers are their own executables with their own @main.
APP_SOURCES=()
while IFS= read -r file; do APP_SOURCES+=("$file"); done < <(
    find Tinycast -name '*.swift' \
        -not -path 'Tinycast/Features/Dictation/Helper/*' \
        -not -name 'ClipboardTextExtractor.swift' -not -name 'ClipboardTextHelper.swift' | sort)
CLIPBOARD_SOURCES=(
    Tinycast/Features/Clipboard/Service/ClipboardTextExtractor.swift
    Tinycast/Features/Clipboard/Service/ClipboardTextHelper.swift)
DICTATION_SOURCES=()
while IFS= read -r file; do DICTATION_SOURCES+=("$file"); done < <(
    find Tinycast/Features/Dictation/Helper -name '*.swift' | sort)
DICTATION_SOURCES+=(
    Tinycast/Features/Dictation/Model/DictationModel.swift
    Tinycast/Features/Dictation/Model/DictationAudioChunks.swift
    Tinycast/Features/Dictation/Model/DictationLanguage.swift
    Tinycast/Features/Dictation/Service/DictationWire.swift)

typecheck() {
    local floor="$1" name="$2"
    shift 2
    local out
    out=$(xcrun swiftc -typecheck -swift-version 6 -strict-concurrency=complete -parse-as-library \
        -target "$ARCH-apple-macos$floor" -sdk "$SDK" "$@" 2>&1)
    if echo "$out" | grep -q 'error:'; then
        echo "$out" | grep -E 'error:' | sort -u
        echo "✗ $name does not typecheck at macOS $floor"
        return 1
    fi
    echo "  ✓ $name @ macOS $floor"
}

fail=0
for floor in 15.0 26.0; do
    typecheck "$floor" Tinycast "${APP_SOURCES[@]}" || fail=1
    typecheck "$floor" ClipboardTextHelper "${CLIPBOARD_SOURCES[@]}" || fail=1
    typecheck "$floor" DictationHelper "${DICTATION_SOURCES[@]}" || fail=1
done
[ "$fail" -ne 0 ] && exit 2
[ "$QUICK" -eq 1 ] && exit 0

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
echo "==> Release build"
if ! xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
    -derivedDataPath "$STAGE/DD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO build > "$STAGE/build.log" 2>&1; then
    grep -E 'error:' "$STAGE/build.log" | sort -u | head -20
    echo "✗ Release build failed"
    exit 2
fi

APP="$STAGE/DD/Build/Products/Release/Tinycast.app"
BIN="$APP/Contents/MacOS/Tinycast"
PLIST_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
[ "$PLIST_MIN" = "15.0" ] || { echo "✗ LSMinimumSystemVersion is $PLIST_MIN, not 15.0"; exit 3; }
for A in arm64 x86_64; do
    MINOS="$(xcrun vtool -arch "$A" -show-build-version "$BIN" | awk '/minos/{print $2}')"
    [ "$MINOS" = "15.0" ] || { echo "✗ $A: minos is $MINOS, not 15.0"; exit 3; }
    # A strong load of a macOS 26-only framework makes dyld refuse to launch the app on Sequoia.
    STRONG="$(otool -l -arch "$A" "$BIN" \
        | awk '/^ *cmd /{cmd=$2} /^ *name /{if (cmd=="LC_LOAD_DYLIB" && $2 ~ /FoundationModels/) print $2}')"
    [ -z "$STRONG" ] || { echo "✗ $A: FoundationModels is strongly linked"; exit 3; }
done
echo "✓ builds for macOS 15: floor 15.0 on both slices, FoundationModels weak-linked"
