#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <nodejs-mobile-source-dir> <output-root> <runtime-config-json>" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$(python3 - <<'PY' "$1"
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
)"
OUTPUT_ROOT="$(python3 - <<'PY' "$2"
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
)"
CONFIG_PATH="$(python3 - <<'PY' "$3"
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
)"

source "${ROOT_DIR}/Scripts/runtime-build-common.sh"

FRAMEWORK_NAME="OllamaKitNodeRuntime"
SUPPORT_FRAMEWORK_NAME="$(json_field "$CONFIG_PATH" node supportFrameworkName)"
IOS_MIN_OS_VERSION="${IOS_MIN_OS_VERSION:-26.0}"
BUILD_ROOT="${SOURCE_DIR}/.ollamakit-build"
DEVICE_FRAMEWORK="${BUILD_ROOT}/wrapper-device/${FRAMEWORK_NAME}.framework"
SIM_FRAMEWORK="${BUILD_ROOT}/wrapper-simulator/${FRAMEWORK_NAME}.framework"
SUPPORT_DEVICE_FRAMEWORK="${SOURCE_DIR}/out_ios/Release-iphoneos/${SUPPORT_FRAMEWORK_NAME}.framework"
SUPPORT_SIM_FRAMEWORK="${SOURCE_DIR}/out_ios/Release-iphonesimulator/${SUPPORT_FRAMEWORK_NAME}.framework"
SUPPORT_XCFRAMEWORK="${SOURCE_DIR}/out_ios/${SUPPORT_FRAMEWORK_NAME}.xcframework"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

python_supports_node_config() {
    local candidate="$1"
    "$candidate" -c "import pipes; from distutils.spawn import find_executable" >/dev/null 2>&1
}

resolve_python_candidate() {
    local candidate="$1"
    if [[ -z "$candidate" ]]; then
        return 1
    fi
    if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    command -v "$candidate" 2>/dev/null || return 1
}

PYTHON_BIN=""
for candidate in \
    "${NODE_BUILD_PYTHON:-}" \
    /usr/bin/python3 \
    python3.12 \
    python3.11 \
    python3.10 \
    python3
do
    resolved_candidate="$(resolve_python_candidate "$candidate" || true)"
    if [[ -n "$resolved_candidate" ]] && python_supports_node_config "$resolved_candidate"; then
        PYTHON_BIN="$resolved_candidate"
        break
    fi
done

if [[ -z "$PYTHON_BIN" ]]; then
    PYTHON_BIN="${BUILD_PYTHON:-$(command -v python3)}"
    if ! "$PYTHON_BIN" -c "from distutils.spawn import find_executable" >/dev/null 2>&1; then
        "$PYTHON_BIN" -m pip install --disable-pip-version-check setuptools
    fi
    if ! python_supports_node_config "$PYTHON_BIN"; then
        echo "No compatible Python interpreter found for the embedded Node runtime build." >&2
        exit 1
    fi
fi

export PYTHON="$PYTHON_BIN"
export NODE_GYP_FORCE_PYTHON="$PYTHON_BIN"
export npm_config_python="$PYTHON_BIN"

pushd "$SOURCE_DIR" >/dev/null
cat > configure <<EOF
#!${PYTHON_BIN}
import os
import runpy

ROOT = os.path.dirname(__file__) or "."
os.chdir(ROOT)
runpy.run_path(os.path.join(ROOT, "configure.py"), run_name="__main__")
EOF
chmod +x configure
python3 - <<'PY' "$SOURCE_DIR/deps/zlib/zutil.h" "$SOURCE_DIR/deps/v8/src/utils/utils.h" "$SOURCE_DIR/deps/v8/src/objects/shared-function-info.h"
from pathlib import Path
import sys

zlib_path = Path(sys.argv[1])
zlib_text = zlib_path.read_text(encoding="utf-8")
zlib_needle = """#      ifndef fdopen
#        define fdopen(fd,mode) NULL /* No fdopen() */
#      endif"""
zlib_replacement = """#      if !defined(__APPLE__) && !defined(fdopen)
#        define fdopen(fd,mode) NULL /* No fdopen() */
#      endif"""
if zlib_needle not in zlib_text:
    raise SystemExit(f"expected zlib fdopen compatibility block in {zlib_path}")
zlib_path.write_text(zlib_text.replace(zlib_needle, zlib_replacement, 1), encoding="utf-8")

v8_utils_path = Path(sys.argv[2])
v8_utils_text = v8_utils_path.read_text(encoding="utf-8")
v8_utils_needle = "  static constexpr T kMax = static_cast<T>(kNumValues - 1);"
v8_utils_replacement = "  static constexpr U kMax = kNumValues - 1;"
if v8_utils_needle not in v8_utils_text:
    raise SystemExit(f"expected V8 BitField kMax definition in {v8_utils_path}")
v8_utils_path.write_text(
    v8_utils_text.replace(v8_utils_needle, v8_utils_replacement, 1),
    encoding="utf-8",
)

shared_function_info_path = Path(sys.argv[3])
shared_function_info_text = shared_function_info_path.read_text(encoding="utf-8")
shared_function_info_replacements = {
    """STATIC_ASSERT(BailoutReason::kLastErrorMessage <=
                DisabledOptimizationReasonBits::kMax);""": """STATIC_ASSERT(
      static_cast<unsigned>(BailoutReason::kLastErrorMessage) <=
      DisabledOptimizationReasonBits::kMax);""",
    """STATIC_ASSERT(FunctionSyntaxKind::kLastFunctionSyntaxKind <=
                FunctionSyntaxKindBits::kMax);""": """STATIC_ASSERT(
      static_cast<unsigned>(FunctionSyntaxKind::kLastFunctionSyntaxKind) <=
      FunctionSyntaxKindBits::kMax);""",
}
for needle, replacement in shared_function_info_replacements.items():
    if needle not in shared_function_info_text:
        raise SystemExit(
            f"expected V8 shared-function-info compatibility block in {shared_function_info_path}: {needle}"
        )
    shared_function_info_text = shared_function_info_text.replace(needle, replacement, 1)
shared_function_info_path.write_text(shared_function_info_text, encoding="utf-8")
PY
bash tools/ios_framework_prepare.sh
popd >/dev/null

mkdir -p "$OUTPUT_ROOT"
rm -rf "${OUTPUT_ROOT}/${SUPPORT_FRAMEWORK_NAME}.xcframework" "${OUTPUT_ROOT}/${FRAMEWORK_NAME}.xcframework"
cp -R "$SUPPORT_XCFRAMEWORK" "${OUTPUT_ROOT}/${SUPPORT_FRAMEWORK_NAME}.xcframework"

prepare_wrapper_framework() {
    local framework_root="$1"
    local support_framework_dir="$2"
    local sdk_name="$3"
    local arch="$4"
    local min_flag="$5"
    local supported_platform="$6"
    local platform_name="$7"
    local sdk_display_name="$8"

    rm -rf "$framework_root"
    prepare_framework_structure "$framework_root" "$FRAMEWORK_NAME" \
        "${ROOT_DIR}/RuntimeSources/Node/OllamaKitNodeRuntimeBridge.h"

    write_framework_info_plist \
        "$framework_root" \
        "com.ollamakit.runtime.node" \
        "$FRAMEWORK_NAME" \
        "$IOS_MIN_OS_VERSION" \
        "$supported_platform" \
        "$platform_name" \
        "$sdk_display_name"

    mkdir -p "${framework_root}/Resources/OllamaKitNode"
    cp "${ROOT_DIR}/RuntimeSources/Node/bootstrap.js" "${framework_root}/Resources/OllamaKitNode/bootstrap.js"
    cp "${ROOT_DIR}/RuntimeSources/Node/native-addon-allowlist.json" "${framework_root}/Resources/OllamaKitNode/native-addon-allowlist.json"

    xcrun clang++ \
        -fobjc-arc \
        -std=gnu++20 \
        -dynamiclib \
        -arch "$arch" \
        -isysroot "$(xcrun --sdk "$sdk_name" --show-sdk-path)" \
        "$min_flag" \
        -F "$(dirname "$support_framework_dir")" \
        -framework Foundation \
        -framework "${SUPPORT_FRAMEWORK_NAME}" \
        -I "${support_framework_dir}/Headers" \
        -Wl,-rpath,@executable_path/Frameworks \
        -install_name "@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" \
        "${ROOT_DIR}/RuntimeSources/Node/OllamaKitNodeRuntimeBridge.mm" \
        -o "${framework_root}/${FRAMEWORK_NAME}"
}

prepare_wrapper_framework \
    "$DEVICE_FRAMEWORK" \
    "$SUPPORT_DEVICE_FRAMEWORK" \
    "iphoneos" \
    "arm64" \
    "-mios-version-min=${IOS_MIN_OS_VERSION}" \
    "iPhoneOS" \
    "iphoneos" \
    "iphoneos${IOS_MIN_OS_VERSION}"

prepare_wrapper_framework \
    "$SIM_FRAMEWORK" \
    "$SUPPORT_SIM_FRAMEWORK" \
    "iphonesimulator" \
    "x86_64" \
    "-mios-simulator-version-min=${IOS_MIN_OS_VERSION}" \
    "iPhoneSimulator" \
    "iphonesimulator" \
    "iphonesimulator${IOS_MIN_OS_VERSION}"

xcodebuild -create-xcframework \
    -framework "$DEVICE_FRAMEWORK" \
    -framework "$SIM_FRAMEWORK" \
    -output "${OUTPUT_ROOT}/${FRAMEWORK_NAME}.xcframework"

echo "Built ${SUPPORT_FRAMEWORK_NAME}.xcframework and ${FRAMEWORK_NAME}.xcframework"
