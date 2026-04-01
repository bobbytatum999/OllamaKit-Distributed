#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def build_manifest(config: dict) -> dict:
    runtimes = []
    for runtime_id in ("python", "node", "swift"):
        entry = config[runtime_id]
        runtimes.append(
            {
                "id": entry["id"],
                "title": entry["title"],
                "frameworkName": entry["bridgeFrameworkName"],
                "version": entry["version"],
                "bundled": True,
                "bridgeSymbol": entry["bridgeSymbol"],
                "resourceBundlePresent": True,
                "supportedOperations": entry.get("supportedOperations", []),
                "requiredResources": entry.get("requiredResources", []),
                "supportFrameworks": entry.get("supportFrameworks", []),
            }
        )

    return {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "runtimes": runtimes,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    config_path = Path(args.config)
    output_path = Path(args.output)

    config = json.loads(config_path.read_text(encoding="utf-8"))
    manifest = build_manifest(config)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
