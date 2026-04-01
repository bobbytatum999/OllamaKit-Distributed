#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <runtime-config-json> <output-root>" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_PATH="$(python3 - <<'PY' "$1"
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
DEPS_ROOT="${ROOT_DIR}/.deps/runtime-sources"
MANIFEST_OUTPUT="${OUTPUT_ROOT}/EmbeddedRuntimeManifest.json"

source "${ROOT_DIR}/Scripts/runtime-build-common.sh"

require_tool git
require_tool python3
require_tool xcodebuild
require_tool xcrun
require_tool clang
require_tool clang++
require_tool swiftc

mkdir -p "$OUTPUT_ROOT" "$DEPS_ROOT"
rm -rf "${OUTPUT_ROOT}/Python.xcframework" \
       "${OUTPUT_ROOT}/OllamaKitPythonRuntime.xcframework" \
       "${OUTPUT_ROOT}/NodeMobile.xcframework" \
       "${OUTPUT_ROOT}/OllamaKitNodeRuntime.xcframework" \
       "${OUTPUT_ROOT}/OllamaKitSwiftRuntime.xcframework"

python_repo="$(json_field "$CONFIG_PATH" python repository)"
python_ref="$(json_field "$CONFIG_PATH" python ref)"
python_commit="$(json_field "$CONFIG_PATH" python commit)"
clone_repo_at_ref "$python_repo" "$python_ref" "${DEPS_ROOT}/cpython" "$python_commit"

node_repo="$(json_field "$CONFIG_PATH" node repository)"
node_ref="$(json_field "$CONFIG_PATH" node ref)"
node_commit="$(json_field "$CONFIG_PATH" node commit)"
clone_repo_at_ref "$node_repo" "$node_ref" "${DEPS_ROOT}/nodejs-mobile" "$node_commit"

bash "${ROOT_DIR}/Scripts/build-python-ios-runtime.sh" \
    "${DEPS_ROOT}/cpython" \
    "$OUTPUT_ROOT" \
    "$CONFIG_PATH"

bash "${ROOT_DIR}/Scripts/build-node-ios-runtime.sh" \
    "${DEPS_ROOT}/nodejs-mobile" \
    "$OUTPUT_ROOT" \
    "$CONFIG_PATH"

bash "${ROOT_DIR}/Scripts/build-swift-ios-runtime.sh" \
    "${ROOT_DIR}/RuntimeSources/Swift" \
    "$OUTPUT_ROOT" \
    "$CONFIG_PATH"

python3 "${ROOT_DIR}/Scripts/generate-embedded-runtime-manifest.py" \
    --config "$CONFIG_PATH" \
    --output "$MANIFEST_OUTPUT"

copy_runtime_manifest_to_slices "$MANIFEST_OUTPUT" "${OUTPUT_ROOT}/OllamaKitPythonRuntime.xcframework"
copy_runtime_manifest_to_slices "$MANIFEST_OUTPUT" "${OUTPUT_ROOT}/OllamaKitNodeRuntime.xcframework"
copy_runtime_manifest_to_slices "$MANIFEST_OUTPUT" "${OUTPUT_ROOT}/OllamaKitSwiftRuntime.xcframework"

echo "Embedded runtimes built under ${OUTPUT_ROOT}"
