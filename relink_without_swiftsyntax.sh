#!/usr/bin/env bash
# Relink a framework binary without SwiftSyntax objects.
# Xcode incorrectly links SwiftSyntax into runtime payloads when using macro
# packages. This script rebuilds the already-compiled binary using the same
# object files but filters SwiftSyntax objects out of the link file list.
# Dynamically detects Universal binaries and caches linker commands for fast incremental builds.

set -euo pipefail

IOS_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET:-17.0}
MACOS_DEPLOYMENT_TARGET=${MACOS_DEPLOYMENT_TARGET:-14.0}

usage() {
    cat <<'EOF'
Usage: relink_without_swiftsyntax.sh --derived-data <path> --config <cfg> --framework <name> --platform <ios|macos> [--arch <arch>] --build-log <log_path>
EOF
}

DERIVED_DATA=""
CONFIG=""
FRAMEWORK=""
PLATFORM=""
ARCH=""
BUILD_LOG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --derived-data) DERIVED_DATA="$2"; shift 2 ;;
        --config) CONFIG="$2"; shift 2 ;;
        --framework) FRAMEWORK="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --build-log) BUILD_LOG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ ! -f "$BUILD_LOG" ]]; then
    echo "Build log not found at $BUILD_LOG. Cannot extract linker command." >&2
    exit 1
fi

if [[ -z "$DERIVED_DATA" || -z "$CONFIG" || -z "$FRAMEWORK" || -z "$PLATFORM" ]]; then
    echo "Missing required arguments" >&2
    usage
    exit 1
fi

platform_lc=$(printf "%s" "$PLATFORM" | tr '[:upper:]' '[:lower:]')
case "$platform_lc" in
    ios)
        SDK="iphoneos"
        CONFIG_SUFFIX="${CONFIG}-iphoneos"
        TARGET_VERSION="$IOS_DEPLOYMENT_TARGET"
        TRIPLE_BASE="ios"
        ;;
    macos|macosx)
        SDK="macosx"
        CONFIG_SUFFIX="${CONFIG}"
        TARGET_VERSION="$MACOS_DEPLOYMENT_TARGET"
        TRIPLE_BASE="macosx"
        platform_lc="macos"
        ;;
    *) echo "Unsupported platform: $PLATFORM" >&2; exit 1 ;;
esac

PRODUCTS_DIR="$DERIVED_DATA/Build/Products/$CONFIG_SUFFIX"
FRAMEWORK_DIR="$PRODUCTS_DIR/PackageFrameworks/$FRAMEWORK.framework"
if [[ ! -d "$FRAMEWORK_DIR" ]]; then
    FRAMEWORK_DIR="$PRODUCTS_DIR/$FRAMEWORK.framework"
fi
FRAMEWORK_BINARY="$FRAMEWORK_DIR/$FRAMEWORK"

FRAMEWORK_BINARY_REAL=""
if [[ -e "$FRAMEWORK_BINARY" ]]; then
    # Safely extract realpath via python
    FRAMEWORK_BINARY_REAL=$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$FRAMEWORK_BINARY")
fi

if [[ -z "$FRAMEWORK_BINARY_REAL" || ! -f "$FRAMEWORK_BINARY_REAL" ]]; then
    if [[ "$platform_lc" = "macos" ]]; then
        for candidate in \
            "$FRAMEWORK_DIR/Versions/A/$FRAMEWORK" \
            "$FRAMEWORK_DIR/Versions/Current/$FRAMEWORK"; do
            if [[ -f "$candidate" ]]; then
                FRAMEWORK_BINARY_REAL="$candidate"
                break
            fi
        done
    else
        FRAMEWORK_BINARY_REAL="$FRAMEWORK_BINARY"
    fi
fi

if [[ -z "$FRAMEWORK_BINARY_REAL" || ! -f "$FRAMEWORK_BINARY_REAL" ]]; then
    echo "Framework binary not found at $FRAMEWORK_BINARY, skipping relink." >&2
    exit 0
fi

# Detect architectures via lipo
DETECTED_ARCHS=$(lipo -archs "$FRAMEWORK_BINARY_REAL" 2>/dev/null || echo "")
if [[ -n "$DETECTED_ARCHS" ]]; then
    ARCHS="$DETECTED_ARCHS"
elif [[ -n "${ARCH:-}" ]]; then
    ARCHS="$ARCH"
else
    echo "Could not determine architectures for $FRAMEWORK_BINARY_REAL" >&2
    exit 1
fi

# Track files for cleanup (guarded against older bash unbound array errors)
declare -a TMP_FILES=()
trap '[[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}"' EXIT

declare -a NEW_THIN_BINARIES=()

for CURRENT_ARCH in $ARCHS; do
    echo "Evaluating architecture: $CURRENT_ARCH"

    link_file=""
    while IFS= read -r -d '' candidate; do
        if grep -q 'SwiftSyntax' "$candidate"; then
            link_file="$candidate"
            break
        fi
    done < <(find "$DERIVED_DATA/Build/Intermediates.noindex" \
        -path "*/$CONFIG_SUFFIX/*/Objects-normal/$CURRENT_ARCH/$FRAMEWORK.LinkFileList" -print0 2>/dev/null || true)

    if [[ -z "$link_file" ]]; then
        echo "  -> No SwiftSyntax references found for $CURRENT_ARCH; preserving existing architecture."
        tmp_thin=$(mktemp "/tmp/${FRAMEWORK}.${CURRENT_ARCH}.XXXXXX")
        TMP_FILES+=("$tmp_thin")
        lipo "$FRAMEWORK_BINARY_REAL" -thin "$CURRENT_ARCH" -output "$tmp_thin" 2>/dev/null || cp "$FRAMEWORK_BINARY_REAL" "$tmp_thin"
        NEW_THIN_BINARIES+=("$tmp_thin")
        continue
    fi

    filtered_file=$(mktemp "/tmp/${FRAMEWORK}.NoSwiftSyntax.LinkFileList.XXXXXX")
    TMP_FILES+=("$filtered_file")
    
    python3 -c '
import sys
source, dest = sys.argv[1:3]
patterns = ("SwiftSyntax", "SwiftParser", "SwiftDiagnostics", "SwiftParserDiagnostics", "SwiftBasicFormat", "_SwiftSyntaxCShims", "ExtensionApi")
with open(source) as src, open(dest, "w") as dst:
    for line in src:
        if not any(token in line for token in patterns):
            dst.write(line)
' "$link_file" "$filtered_file"

    if ! grep -q '[^[:space:]]' "$filtered_file"; then
        echo "Filtered link file list is empty for $CURRENT_ARCH, aborting." >&2
        exit 1
    fi

    tmp_binary=$(mktemp "/tmp/${FRAMEWORK}.relinked.${CURRENT_ARCH}.XXXXXX")
    TMP_FILES+=("$tmp_binary")

    cmd_cache_file="$DERIVED_DATA/Build/Intermediates.noindex/${FRAMEWORK}.${CURRENT_ARCH}.linker_cmd.txt"

    echo "  -> Extracting original linker command for $CURRENT_ARCH..."
    
    python3 - "$BUILD_LOG" "$CURRENT_ARCH" "$FRAMEWORK" "$filtered_file" "$tmp_binary" "$cmd_cache_file" <<'EOF'
import sys, shlex, subprocess, os

log_path, arch, framework, new_filelist, out_binary, cache_path = sys.argv[1:7]

target_cmd = None
with open(log_path, 'r') as f:
    for line in f:
        # Match target arch dynamically, removing SwiftSyntax
        if ('/clang' in line or '/swiftc' in line) and f'-target {arch}-' in line and f'/{framework}' in line and '-filelist' in line:
            target_cmd = line.strip()
            break

if target_cmd:
    with open(cache_path, 'w') as f:
        f.write(target_cmd)
else:
    if os.path.exists(cache_path):
        print("  -> Xcode build was cached. Reusing saved linker command...")
        with open(cache_path, 'r') as f:
            target_cmd = f.read().strip()

if not target_cmd:
    print(f"Error: Could not find original linker command for {arch} in build log or cache. Please run a clean build (rm -rf .xcodebuild-ios).")
    sys.exit(1)

tokens = shlex.split(target_cmd)

for i, token in enumerate(tokens):
    if token == '-filelist' and i + 1 < len(tokens):
        tokens[i+1] = new_filelist
    elif token == '-o' and i + 1 < len(tokens):
        tokens[i+1] = out_binary

try:
    subprocess.run(tokens, check=True)
except subprocess.CalledProcessError as e:
    print(f"Relink failed for {arch}")
    sys.exit(e.returncode)
EOF
    
    NEW_THIN_BINARIES+=("$tmp_binary")
done

# Re-stitch binary
if [[ ${#NEW_THIN_BINARIES[@]} -gt 0 ]]; then
    echo "Stitching architectures back into a universal binary..."
    lipo -create -output "$FRAMEWORK_BINARY_REAL" "${NEW_THIN_BINARIES[@]}"
    chmod +x "$FRAMEWORK_BINARY_REAL"
    after_size=$(stat -f%z "$FRAMEWORK_BINARY_REAL" 2>/dev/null || stat -c%s "$FRAMEWORK_BINARY_REAL")
    echo "Universal relink successful. Final size: $after_size bytes"
fi
