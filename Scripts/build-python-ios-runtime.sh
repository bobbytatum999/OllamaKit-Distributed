#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <cpython-source-dir> <output-root> <runtime-config-json>" >&2
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

FRAMEWORK_NAME="OllamaKitPythonRuntime"
SUPPORT_FRAMEWORK_NAME="$(json_field "$CONFIG_PATH" python supportFrameworkName)"
IOS_MIN_OS_VERSION="${IOS_MIN_OS_VERSION:-26.0}"
CPU_COUNT="$(logical_cpu_count)"
if [[ -n "${BUILD_PYTHON:-}" ]]; then
    BUILD_PYTHON="$BUILD_PYTHON"
elif command -v python3.13 >/dev/null 2>&1; then
    BUILD_PYTHON="$(command -v python3.13)"
else
    BUILD_PYTHON="$(command -v python3)"
fi
BUILD_TRIPLE="$(uname -m)-apple-darwin"
BUILD_ROOT="${SOURCE_DIR}/.ollamakit-build"
DEVICE_BUILD="${BUILD_ROOT}/device"
SIMULATOR_BUILD="${BUILD_ROOT}/simulator"
DEVICE_INSTALL="${BUILD_ROOT}/install-device"
SIMULATOR_INSTALL="${BUILD_ROOT}/install-simulator"
DEVICE_FRAMEWORK="${BUILD_ROOT}/wrapper-device/${FRAMEWORK_NAME}.framework"
SIM_FRAMEWORK="${BUILD_ROOT}/wrapper-simulator/${FRAMEWORK_NAME}.framework"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

export PATH="${SOURCE_DIR}/iOS/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin"

configure_python() {
    local host_triple="$1"
    local build_dir="$2"
    local install_dir="$3"
    local sdk_name="$4"

    rm -rf "$build_dir" "$install_dir"
    mkdir -p "$build_dir" "$install_dir"
    pushd "$build_dir" >/dev/null

    export SDKROOT="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
    export ac_cv_func_dup3="no"
    export ac_cv_func_pipe2="no"
    "${SOURCE_DIR}/configure" \
        --enable-framework="${install_dir}" \
        --with-framework-name="${SUPPORT_FRAMEWORK_NAME}" \
        --host="${host_triple}" \
        --build="${BUILD_TRIPLE}" \
        --with-build-python="${BUILD_PYTHON}" \
        --without-ensurepip

    make -j"${CPU_COUNT}"
    make install
    popd >/dev/null
}

configure_python "arm64-apple-ios${IOS_MIN_OS_VERSION}" "$DEVICE_BUILD" "$DEVICE_INSTALL" "iphoneos"
configure_python "x86_64-apple-ios${IOS_MIN_OS_VERSION}-simulator" "$SIMULATOR_BUILD" "$SIMULATOR_INSTALL" "iphonesimulator"

rm -rf "${OUTPUT_ROOT}/${SUPPORT_FRAMEWORK_NAME}.xcframework" "${OUTPUT_ROOT}/${FRAMEWORK_NAME}.xcframework"
mkdir -p "$OUTPUT_ROOT"

xcodebuild -create-xcframework \
    -framework "${DEVICE_INSTALL}/${SUPPORT_FRAMEWORK_NAME}.framework" \
    -framework "${SIMULATOR_INSTALL}/${SUPPORT_FRAMEWORK_NAME}.framework" \
    -output "${OUTPUT_ROOT}/${SUPPORT_FRAMEWORK_NAME}.xcframework"

while IFS= read -r framework_dir; do
    slice_root="$(dirname "$framework_dir")"
    install_root="$DEVICE_INSTALL"
    if [[ "$slice_root" == *simulator* ]]; then
        install_root="$SIMULATOR_INSTALL"
    fi

    cp -R "${install_root}/bin" "$slice_root/"
    cp -R "${install_root}/lib" "$slice_root/"
done < <(find "${OUTPUT_ROOT}/${SUPPORT_FRAMEWORK_NAME}.xcframework" -type d -name "${SUPPORT_FRAMEWORK_NAME}.framework" | sort)

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
        "${ROOT_DIR}/RuntimeSources/Python/OllamaKitPythonRuntimeBridge.h"

    write_framework_info_plist \
        "$framework_root" \
        "com.ollamakit.runtime.python" \
        "$FRAMEWORK_NAME" \
        "$IOS_MIN_OS_VERSION" \
        "$supported_platform" \
        "$platform_name" \
        "$sdk_display_name"

    mkdir -p "${framework_root}/Resources/OllamaKitPython/Home"
    cp "${ROOT_DIR}/RuntimeSources/Python/bootstrap.py" "${framework_root}/Resources/OllamaKitPython/bootstrap.py"
    cp "${ROOT_DIR}/RuntimeSources/Python/native-extension-allowlist.json" "${framework_root}/Resources/OllamaKitPython/native-extension-allowlist.json"
    cp -R "${support_framework_dir%/}/../bin" "${framework_root}/Resources/OllamaKitPython/Home/"
    cp -R "${support_framework_dir%/}/../lib" "${framework_root}/Resources/OllamaKitPython/Home/"

    xcrun clang \
        -fobjc-arc \
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
        "${ROOT_DIR}/RuntimeSources/Python/OllamaKitPythonRuntimeBridge.m" \
        -o "${framework_root}/${FRAMEWORK_NAME}"
}

prepare_wrapper_framework \
    "$DEVICE_FRAMEWORK" \
    "${DEVICE_INSTALL}/${SUPPORT_FRAMEWORK_NAME}.framework" \
    "iphoneos" \
    "arm64" \
    "-mios-version-min=${IOS_MIN_OS_VERSION}" \
    "iPhoneOS" \
    "iphoneos" \
    "iphoneos${IOS_MIN_OS_VERSION}"

prepare_wrapper_framework \
    "$SIM_FRAMEWORK" \
    "${SIMULATOR_INSTALL}/${SUPPORT_FRAMEWORK_NAME}.framework" \
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
