#!/usr/bin/env bash
# Relink a framework binary without SwiftSyntax objects.
# Xcode incorrectly links SwiftSyntax into runtime payloads when using macro
# packages. This script rebuilds the already-compiled binary using the same
# object files but filters SwiftSyntax objects out of the link file list.
# Dynamically detects Universal (fat) binaries and relinks each architecture separately.

set -euo pipefail

IOS_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET:-17.0}
MACOS_DEPLOYMENT_TARGET=${MACOS_DEPLOYMENT_TARGET:-14.0}

usage() {
    cat <<'EOF'
Usage: relink_without_swiftsyntax.sh --derived-data <path> --config <cfg> --framework <name> --platform <ios|macos> [--arch <arch>]

Environment overrides:
  IOS_DEPLOYMENT_TARGET  (default: 17.0)
  MACOS_DEPLOYMENT_TARGET (default: 14.0)
EOF
}

DERIVED_DATA=""
CONFIG=""
FRAMEWORK=""
PLATFORM=""
ARCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --derived-data) DERIVED_DATA="$2"; shift 2 ;;
        --config) CONFIG="$2"; shift 2 ;;
        --framework) FRAMEWORK="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$DERIVED_DATA" || -z "$CONFIG" || -z "$FRAMEWORK" || -z "$PLATFORM" ]]; then
    echo "Missing required arguments" >&2
    usage
    exit 1
fi

if [[ ! -d "$DERIVED_DATA/Build/Products" ]]; then
    echo "Derived data path looks invalid: $DERIVED_DATA" >&2
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
    FRAMEWORK_BINARY_REAL=$(python3 - <<'PY' "$FRAMEWORK_BINARY"
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)
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

# Track files for cleanup
declare -a TMP_FILES=()
trap 'rm -f "${TMP_FILES[@]}"' EXIT

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
    python3 - <<'PY' "$link_file" "$filtered_file"
import sys
source, dest = sys.argv[1:3]
patterns = ("SwiftSyntax", "SwiftParser", "SwiftDiagnostics", "SwiftParserDiagnostics", "SwiftBasicFormat", "_SwiftSyntaxCShims", "ExtensionApi")
with open(source) as src, open(dest, "w") as dst:
    for line in src:
        if not any(token in line for token in patterns):
            dst.write(line)
PY

    if ! grep -q '[^[:space:]]' "$filtered_file"; then
        echo "Filtered link file list is empty for $CURRENT_ARCH, aborting." >&2
        exit 1
    fi

    module_dir=""
    module_file=$(find "$DERIVED_DATA/Build/Intermediates.noindex" \
        -path "*/$CONFIG_SUFFIX/*/Objects-normal/$CURRENT_ARCH/$FRAMEWORK.swiftmodule" -print -quit 2>/dev/null || true)
    if [[ -n "$module_file" ]]; then
        module_dir=$(dirname "$module_file")
    fi

    linker_resp=""
    lto_file=""
    dep_info=""
    if [[ -n "$module_dir" ]]; then
        [[ -f "$module_dir/$FRAMEWORK-linker-args.resp" ]] && linker_resp="$module_dir/$FRAMEWORK-linker-args.resp"
        [[ -f "$module_dir/${FRAMEWORK}_lto.o" ]] && lto_file="$module_dir/${FRAMEWORK}_lto.o"
        [[ -f "$module_dir/${FRAMEWORK}_dependency_info.dat" ]] && dep_info="$module_dir/${FRAMEWORK}_dependency_info.dat"
    fi

    SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
    PLATFORM_PATH=$(xcrun --sdk "$SDK" --show-sdk-platform-path)
    CLANG=$(xcrun --sdk "$SDK" --find clang)
    SWIFTC_PATH=$(xcrun --find swiftc)
    TOOLCHAIN_DIR=$(cd "$(dirname "$SWIFTC_PATH")/.." && pwd)
    SWIFT_LIB_DIR="$TOOLCHAIN_DIR/lib/swift/$SDK"

    EAGER_TBD_DIR="$DERIVED_DATA/Build/Intermediates.noindex/EagerLinkingTBDs/$CONFIG_SUFFIX"
    PLATFORM_DEV_LIB="$PLATFORM_PATH/Developer/usr/lib"
    DEVELOPER_FRAMEWORKS="$PLATFORM_PATH/Developer/Library/Frameworks"
    SDK_DEVELOPER_FRAMEWORKS="$SDK_PATH/Developer/Library/Frameworks"

    TARGET_TRIPLE="${CURRENT_ARCH}-apple-${TRIPLE_BASE}${TARGET_VERSION}"
    
    # Extract Install Name dynamically while ignoring header architectures lines
    INSTALL_NAME=$(otool -D "$FRAMEWORK_BINARY_REAL" 2>/dev/null | grep -v ':$' | head -n 1 || true)
    if [[ -z "$INSTALL_NAME" ]]; then
        if [[ "$platform_lc" = "macos" ]]; then
            INSTALL_NAME="@rpath/$FRAMEWORK.framework/Versions/A/$FRAMEWORK"
        else
            INSTALL_NAME="@rpath/$FRAMEWORK.framework/$FRAMEWORK"
        fi
    fi

    tmp_binary=$(mktemp "/tmp/${FRAMEWORK}.relinked.${CURRENT_ARCH}.XXXXXX")
    TMP_FILES+=("$tmp_binary")

    link_args=(
        "$CLANG" "-Xlinker" "-reproducible" "-target" "$TARGET_TRIPLE" "-dynamiclib"
        "-isysroot" "$SDK_PATH" "-O0" "-filelist" "$filtered_file" "-install_name" "$INSTALL_NAME"
        "-Xlinker" "-rpath" "-Xlinker" "/usr/lib/swift" "-dead_strip" "-rdynamic"
        "-Xlinker" "-no_deduplicate" "-fobjc-link-runtime" "-Wl,-no_warn_duplicate_libraries"
        "-Wl,-make_mergeable" "-Xlinker" "-dead_strip" "-o" "$tmp_binary"
    )

    if [[ -d "$EAGER_TBD_DIR" ]]; then link_args+=("-L$EAGER_TBD_DIR" "-F$EAGER_TBD_DIR"); fi
    if [[ -d "$PRODUCTS_DIR" ]]; then link_args+=("-L$PRODUCTS_DIR" "-F$PRODUCTS_DIR"); fi
    if [[ -d "$PRODUCTS_DIR/PackageFrameworks" ]]; then
        link_args+=("-F$PRODUCTS_DIR/PackageFrameworks" "-Xlinker" "-rpath" "-Xlinker" "$PRODUCTS_DIR/PackageFrameworks")
    elif [[ -d "$(dirname "$FRAMEWORK_DIR")" ]]; then
        parent_dir="$(dirname "$FRAMEWORK_DIR")"
        link_args+=("-F$parent_dir" "-Xlinker" "-rpath" "-Xlinker" "$parent_dir")
    fi
    
    if [[ -d "$PLATFORM_DEV_LIB" ]]; then link_args+=("-L$PLATFORM_DEV_LIB"); fi
    if [[ -d "$SWIFT_LIB_DIR" ]]; then link_args+=("-L$SWIFT_LIB_DIR"); fi
    link_args+=("-L/usr/lib/swift")
    if [[ -d "$DEVELOPER_FRAMEWORKS" ]]; then link_args+=("-iframework" "$DEVELOPER_FRAMEWORKS"); fi
    if [[ -d "$SDK_DEVELOPER_FRAMEWORKS" ]]; then link_args+=("-iframework" "$SDK_DEVELOPER_FRAMEWORKS"); fi

    if [[ -n "$lto_file" ]]; then link_args+=("-Xlinker" "-object_path_lto" "-Xlinker" "$lto_file"); fi
    if [[ -n "$dep_info" ]]; then link_args+=("-Xlinker" "-dependency_info" "-Xlinker" "$dep_info"); fi

    if [[ -n "$module_dir" ]]; then
        for ext in swiftmodule swiftdoc swiftinterface swiftsourceinfo abi.json swiftconstvalues; do
            for candidate in "$module_dir"/$FRAMEWORK*".$ext"; do
                if [[ -f "$candidate" ]]; then link_args+=("-Xlinker" "-add_ast_path" "-Xlinker" "$candidate"); fi
            done
        done
    fi

    if [[ -n "$linker_resp" ]]; then link_args+=("@$linker_resp"); fi

    echo "  -> Relinking architecture $CURRENT_ARCH without SwiftSyntax..."
    "${link_args[@]}"

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
