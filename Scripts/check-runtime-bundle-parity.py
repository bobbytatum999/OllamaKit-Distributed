#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
from pathlib import Path


WRAPPER_FRAMEWORKS = {
    "python": "OllamaKitPythonRuntime.framework",
    "node": "OllamaKitNodeRuntime.framework",
    "swift": "OllamaKitSwiftRuntime.framework",
}


def manifest_for_framework(app_path: Path, framework_name: str) -> dict | None:
    framework_root = app_path / "Frameworks" / framework_name
    manifest_path = framework_root / "Resources" / "EmbeddedRuntimeManifest.json"
    if not manifest_path.exists():
        return None
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def runtime_record(app_path: Path, runtime_id: str) -> dict:
    wrapper_name = WRAPPER_FRAMEWORKS[runtime_id]
    wrapper_root = app_path / "Frameworks" / wrapper_name
    binary_path = wrapper_root / wrapper_name.removesuffix(".framework")
    manifest = manifest_for_framework(app_path, wrapper_name)
    manifest_entry = None
    if manifest:
        manifest_entry = next((entry for entry in manifest.get("runtimes", []) if entry.get("id") == runtime_id), None)

    resource_bundle_present = False
    support_frameworks_present = False
    supported_operations: list[str] = []
    version = ""

    if manifest_entry:
        version = manifest_entry.get("version", "")
        supported_operations = manifest_entry.get("supportedOperations", [])
        resource_bundle_present = all((wrapper_root / relative_path).exists() for relative_path in manifest_entry.get("requiredResources", []))
        support_frameworks_present = all((app_path / "Frameworks" / name).exists() for name in manifest_entry.get("supportFrameworks", []))

    return {
        "wrapper_present": binary_path.exists(),
        "manifest_present": manifest_entry is not None,
        "resource_bundle_present": resource_bundle_present,
        "support_frameworks_present": support_frameworks_present,
        "version": version,
        "supported_operations": supported_operations,
    }


def inspect_app_bundle(app_path: Path) -> dict:
    return {runtime_id: runtime_record(app_path, runtime_id) for runtime_id in WRAPPER_FRAMEWORKS}


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: check-runtime-bundle-parity.py <stock_app_path> <jailbreak_app_path>", file=sys.stderr)
        return 2

    stock_app = Path(sys.argv[1])
    jailbreak_app = Path(sys.argv[2])

    if not stock_app.exists():
        print(f"missing app bundle: {stock_app}", file=sys.stderr)
        return 2
    if not jailbreak_app.exists():
        print(f"missing app bundle: {jailbreak_app}", file=sys.stderr)
        return 2

    inventories = {
        "stockSideload": inspect_app_bundle(stock_app),
        "jailbreak": inspect_app_bundle(jailbreak_app),
    }

    print(json.dumps(inventories, indent=2, sort_keys=True))

    if inventories["stockSideload"] != inventories["jailbreak"]:
        print("embedded runtime inventory differs between stockSideload and jailbreak archives", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
