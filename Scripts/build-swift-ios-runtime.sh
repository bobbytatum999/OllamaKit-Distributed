#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <swift-runtime-source-dir> <output-root> <runtime-config-json>" >&2
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

FRAMEWORK_NAME="OllamaKitSwiftRuntime"
IOS_MIN_OS_VERSION="${IOS_MIN_OS_VERSION:-26.0}"
BUILD_ROOT="${OUTPUT_ROOT}/.swift-runtime-build"
DEVICE_FRAMEWORK="${BUILD_ROOT}/device/${FRAMEWORK_NAME}.framework"
SIM_FRAMEWORK="${BUILD_ROOT}/simulator/${FRAMEWORK_NAME}.framework"

rm -rf "$BUILD_ROOT" "${OUTPUT_ROOT}/${FRAMEWORK_NAME}.xcframework"
mkdir -p "$BUILD_ROOT" "$OUTPUT_ROOT"

build_framework() {
    local framework_root="$1"
    local sdk_name="$2"
    local target_triple="$3"
    local supported_platform="$4"
    local platform_name="$5"
    local sdk_display_name="$6"

    rm -rf "$framework_root"
    prepare_framework_structure "$framework_root" "$FRAMEWORK_NAME" \
        "${SOURCE_DIR}/OllamaKitSwiftRuntime.h" \
        "$FRAMEWORK_NAME"

    write_framework_info_plist \
        "$framework_root" \
        "com.ollamakit.runtime.swift" \
        "$FRAMEWORK_NAME" \
        "$IOS_MIN_OS_VERSION" \
        "$supported_platform" \
        "$platform_name" \
        "$sdk_display_name"

    mkdir -p "${framework_root}/Resources/OllamaKitSwift/Templates"
    cp -R "${SOURCE_DIR}/Templates/." "${framework_root}/Resources/OllamaKitSwift/Templates/"

    swiftc \
        -parse-as-library \
        -emit-library \
        -module-name "$FRAMEWORK_NAME" \
        -sdk "$(xcrun --sdk "$sdk_name" --show-sdk-path)" \
        -target "$target_triple" \
        -Xlinker -install_name \
        -Xlinker "@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" \
        -o "${framework_root}/${FRAMEWORK_NAME}" \
        "${SOURCE_DIR}/OllamaKitSwiftRuntime.swift"
}

build_framework \
    "$DEVICE_FRAMEWORK" \
    "iphoneos" \
    "arm64-apple-ios${IOS_MIN_OS_VERSION}" \
    "iPhoneOS" \
    "iphoneos" \
    "iphoneos${IOS_MIN_OS_VERSION}"

build_framework \
    "$SIM_FRAMEWORK" \
    "iphonesimulator" \
    "x86_64-apple-ios${IOS_MIN_OS_VERSION}-simulator" \
    "iPhoneSimulator" \
    "iphonesimulator" \
    "iphonesimulator${IOS_MIN_OS_VERSION}"

xcodebuild -create-xcframework \
    -framework "$DEVICE_FRAMEWORK" \
    -framework "$SIM_FRAMEWORK" \
    -output "${OUTPUT_ROOT}/${FRAMEWORK_NAME}.xcframework"

rm -rf "$BUILD_ROOT"
echo "Built ${FRAMEWORK_NAME}.xcframework"
