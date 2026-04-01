#!/usr/bin/env bash

set -euo pipefail

json_field() {
    local config_path="$1"
    local runtime_id="$2"
    local field_name="$3"

    python3 - "$config_path" "$runtime_id" "$field_name" <<'PY'
import json
import sys

config_path, runtime_id, field_name = sys.argv[1:4]
with open(config_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

value = payload[runtime_id].get(field_name, "")
if isinstance(value, list):
    print("\n".join(str(item) for item in value))
elif value is None:
    print("")
else:
    print(str(value))
PY
}

clone_repo_at_ref() {
    local repository="$1"
    local ref="$2"
    local destination="$3"
    local expected_commit="${4:-}"

    rm -rf "$destination"
    git clone --depth 1 --branch "$ref" "$repository" "$destination"

    if [[ -n "$expected_commit" ]]; then
        local actual_commit
        actual_commit="$(git -C "$destination" rev-parse HEAD)"
        if [[ "$actual_commit" != "$expected_commit" ]]; then
            echo "Pinned source verification failed for $repository" >&2
            echo "Expected: $expected_commit" >&2
            echo "Actual:   $actual_commit" >&2
            exit 1
        fi
    fi
}

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
}

logical_cpu_count() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu
}

write_framework_info_plist() {
    local framework_dir="$1"
    local bundle_identifier="$2"
    local bundle_name="$3"
    local min_os="$4"
    local supported_platform="$5"
    local platform_name="$6"
    local sdk_name="$7"

    cat > "${framework_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${bundle_name}</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_identifier}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${bundle_name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${min_os}</string>
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
    <string>${sdk_name}</string>
</dict>
</plist>
EOF
}

prepare_framework_structure() {
    local framework_root="$1"
    local framework_name="$2"
    local public_header_source="$3"
    local module_name="${4:-$framework_name}"

    mkdir -p "${framework_root}/Headers" "${framework_root}/Modules" "${framework_root}/Resources"
    cp "$public_header_source" "${framework_root}/Headers/${framework_name}.h"
    cat > "${framework_root}/Modules/module.modulemap" <<EOF
framework module ${module_name} {
    umbrella header "${framework_name}.h"
    export *
}
EOF
}

copy_runtime_manifest_to_slices() {
    local manifest_path="$1"
    local xcframework_path="$2"

    while IFS= read -r framework_dir; do
        mkdir -p "${framework_dir}/Resources"
        cp "$manifest_path" "${framework_dir}/Resources/EmbeddedRuntimeManifest.json"
    done < <(find "$xcframework_path" -type d -name "*.framework" | sort)
}
