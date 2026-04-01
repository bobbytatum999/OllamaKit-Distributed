#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <runtime-output-root>" >&2
    exit 1
fi

RUNTIME_ROOT="$1"

missing=()
for path in \
    "${RUNTIME_ROOT}/Python.xcframework" \
    "${RUNTIME_ROOT}/OllamaKitPythonRuntime.xcframework" \
    "${RUNTIME_ROOT}/NodeMobile.xcframework" \
    "${RUNTIME_ROOT}/OllamaKitNodeRuntime.xcframework" \
    "${RUNTIME_ROOT}/OllamaKitSwiftRuntime.xcframework" \
    "${RUNTIME_ROOT}/EmbeddedRuntimeManifest.json"
do
    if [[ ! -e "$path" ]]; then
        missing+=("$path")
    fi
done

if (( ${#missing[@]} > 0 )); then
    echo "Missing embedded runtime artifacts:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "Run Scripts/build-embedded-runtimes.sh before archiving or opening the Xcode target." >&2
    exit 1
fi

while IFS= read -r framework_dir; do
    binary_name="$(basename "$framework_dir" .framework)"
    binary_path="${framework_dir}/${binary_name}"
    if [[ ! -f "$binary_path" ]]; then
        missing+=("$binary_path")
    fi
done < <(find "${RUNTIME_ROOT}/OllamaKitPythonRuntime.xcframework" "${RUNTIME_ROOT}/OllamaKitNodeRuntime.xcframework" "${RUNTIME_ROOT}/OllamaKitSwiftRuntime.xcframework" -type d -name "*.framework" | sort)

while IFS= read -r framework_dir; do
    if [[ ! -f "${framework_dir}/Resources/EmbeddedRuntimeManifest.json" ]]; then
        missing+=("${framework_dir}/Resources/EmbeddedRuntimeManifest.json")
    fi
done < <(find "${RUNTIME_ROOT}/OllamaKitPythonRuntime.xcframework" "${RUNTIME_ROOT}/OllamaKitNodeRuntime.xcframework" "${RUNTIME_ROOT}/OllamaKitSwiftRuntime.xcframework" -type d -name "*.framework" | sort)

for support_framework in \
    "${RUNTIME_ROOT}/Python.xcframework" \
    "${RUNTIME_ROOT}/NodeMobile.xcframework"
do
    while IFS= read -r framework_dir; do
        binary_name="$(basename "$framework_dir" .framework)"
        binary_path="${framework_dir}/${binary_name}"
        if [[ ! -f "$binary_path" ]]; then
            missing+=("$binary_path")
        fi
    done < <(find "$support_framework" -type d -name "*.framework" | sort)
done

if (( ${#missing[@]} > 0 )); then
    echo "Embedded runtime artifact validation failed:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi
