#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <llama.cpp-source-dir> <output-xcframework-path>"
    exit 1
fi

SOURCE_DIR="$1"
OUTPUT_PATH="$2"

IOS_MIN_OS_VERSION="${IOS_MIN_OS_VERSION:-16.4}"
FRAMEWORK_NAME="llama"

COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DBUILD_SHARED_LIBS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_BLAS_DEFAULT=ON
    -DGGML_METAL_USE_BF16=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DLLAMA_OPENSSL=OFF
)

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
COMMON_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"

check_required_tool() {
    local tool="$1"

    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool"
        exit 1
    fi
}

check_required_tool cmake
check_required_tool xcrun

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
OUTPUT_PATH="$(python3 - <<'PY' "$OUTPUT_PATH"
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
)"
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"

SIM_BUILD_DIR="${SOURCE_DIR}/build-ios-sim"
DEVICE_BUILD_DIR="${SOURCE_DIR}/build-ios-device"

cleanup() {
    rm -rf "$SIM_BUILD_DIR" "$DEVICE_BUILD_DIR" "${SOURCE_DIR}/build-apple"
}

setup_framework_structure() {
    local build_dir="$1"
    local supported_platform="$2"
    local platform_name="$3"
    local sdk_name="$4"

    mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers"
    mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Modules"

    cp "${SOURCE_DIR}/include/llama.h" "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
    cp "${SOURCE_DIR}/ggml/include/ggml.h" "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
    cp "${SOURCE_DIR}/ggml/include/ggml-opt.h" "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
    cp "${SOURCE_DIR}/ggml/include/ggml-alloc.h" "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
    cp "${SOURCE_DIR}/ggml/include/ggml-backend.h" "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
    cp "${SOURCE_DIR}/ggml/include/ggml-metal.h" "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
    cp "${SOURCE_DIR}/ggml/include/ggml-cpu.h" "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
    cp "${SOURCE_DIR}/ggml/include/ggml-blas.h" "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
    cp "${SOURCE_DIR}/ggml/include/gguf.h" "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"

    cat > "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Modules/module.modulemap" <<'EOF'
framework module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
EOF

    cat > "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${IOS_MIN_OS_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${supported_platform}</string>
    </array>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>DTPlatformName</key>
    <string>${platform_name}</string>
    <key>DTSDKName</key>
    <string>${sdk_name}${IOS_MIN_OS_VERSION}</string>
</dict>
</plist>
EOF
}

create_dynamic_framework() {
    local build_dir="$1"
    local release_dir="$2"
    local sdk="$3"
    local archs="$4"
    local min_version_flag="$5"

    local output_lib="${build_dir}/framework/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
    local temp_dir="${build_dir}/temp"

    mkdir -p "$temp_dir"

    resolve_static_lib() {
        local library_name="$1"
        local expected_path="$2"

        if [[ -f "$expected_path" ]]; then
            printf '%s\n' "$expected_path"
            return 0
        fi

        local resolved_path
        resolved_path="$(find "$build_dir" -name "$library_name" -type f | sort | head -n 1)"
        if [[ -n "$resolved_path" ]]; then
            printf '%s\n' "$resolved_path"
            return 0
        fi

        echo "Missing required static library: $library_name" >&2
        echo "Expected path: $expected_path" >&2
        echo "Available static libraries under $build_dir:" >&2
        find "$build_dir" -name '*.a' -type f | sort >&2 || true
        exit 1
    }

    local libs=(
        "$(resolve_static_lib libllama.a "${build_dir}/src/${release_dir}/libllama.a")"
        "$(resolve_static_lib libggml.a "${build_dir}/ggml/src/${release_dir}/libggml.a")"
        "$(resolve_static_lib libggml-base.a "${build_dir}/ggml/src/${release_dir}/libggml-base.a")"
        "$(resolve_static_lib libggml-cpu.a "${build_dir}/ggml/src/${release_dir}/libggml-cpu.a")"
        "$(resolve_static_lib libggml-metal.a "${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a")"
        "$(resolve_static_lib libggml-blas.a "${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a")"
    )

    echo "Combining static libraries:"
    printf '  %s\n' "${libs[@]}"
    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}"

    local arch_flags=()
    for arch in $archs; do
        arch_flags+=(-arch "$arch")
    done

    xcrun -sdk "$sdk" clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        "${arch_flags[@]}" \
        "$min_version_flag" \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation \
        -framework Metal \
        -framework Accelerate \
        -install_name "@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" \
        -o "$output_lib"

    if [[ "$sdk" == "iphoneos" ]] && xcrun -f vtool >/dev/null 2>&1; then
        xcrun vtool -set-build-version ios "${IOS_MIN_OS_VERSION}" "${IOS_MIN_OS_VERSION}" -replace \
            -output "$output_lib" "$output_lib"
    fi

    rm -rf "$temp_dir"
}

cleanup

cmake -B "$SIM_BUILD_DIR" -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_MIN_OS_VERSION}" \
    -DIOS=ON \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphonesimulator \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -S "$SOURCE_DIR"

cmake --build "$SIM_BUILD_DIR" --config Release -- -quiet

cmake -B "$DEVICE_BUILD_DIR" -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_MIN_OS_VERSION}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -S "$SOURCE_DIR"

cmake --build "$DEVICE_BUILD_DIR" --config Release -- -quiet

setup_framework_structure "$SIM_BUILD_DIR" "iPhoneSimulator" "iphonesimulator" "iphonesimulator"
setup_framework_structure "$DEVICE_BUILD_DIR" "iPhoneOS" "iphoneos" "iphoneos"

create_dynamic_framework "$SIM_BUILD_DIR" "Release-iphonesimulator" "iphonesimulator" "arm64 x86_64" "-mios-simulator-version-min=${IOS_MIN_OS_VERSION}"
create_dynamic_framework "$DEVICE_BUILD_DIR" "Release-iphoneos" "iphoneos" "arm64" "-mios-version-min=${IOS_MIN_OS_VERSION}"

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_PATH"

xcrun xcodebuild -create-xcframework \
    -framework "${SIM_BUILD_DIR}/framework/${FRAMEWORK_NAME}.framework" \
    -framework "${DEVICE_BUILD_DIR}/framework/${FRAMEWORK_NAME}.framework" \
    -output "$OUTPUT_PATH"

echo "Created XCFramework at $OUTPUT_PATH"
