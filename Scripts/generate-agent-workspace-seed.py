#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import hashlib
import subprocess
import sys
from pathlib import Path

MIRRORED_PREFIXES = (
    ".github/workflows/",
    "Relay/",
    "LiveContainerFix/",
    "Scripts/",
    "Sources/OllamaCore/",
    "Sources/OllamaKit/",
    "Tests/",
    "Vendor/anemll-swift-cli/",
    "OllamaKit.xcodeproj/",
    "README.md",
    "Package.swift",
    "LICENSE",
)

MIRRORED_EXACT_FILES = {
    "LICENSE",
    "Package.swift",
    "README.md",
    "OllamaKit.xcodeproj/project.pbxproj",
}

MIRRORED_TEXT_EXTENSIONS = {
    "c",
    "cc",
    "cfg",
    "cpp",
    "entitlements",
    "h",
    "htm",
    "html",
    "java",
    "js",
    "json",
    "m",
    "md",
    "pbxproj",
    "plist",
    "prompt",
    "py",
    "rb",
    "sh",
    "strings",
    "swift",
    "txt",
    "xcconfig",
    "xcscheme",
    "xml",
    "yaml",
    "yml",
}

TARGET_RELATIVE_PATH = "Sources/OllamaKit/Services/GeneratedAgentWorkspaceSeed.swift"
IGNORED_PATH_PARTS = {
    ".git",
    ".deps",
    "build",
    "DerivedData",
    "node_modules",
    "__pycache__",
}


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def iter_candidate_files(root: Path) -> list[str]:
    try:
        output = subprocess.check_output(
            ["git", "-C", str(root), "ls-files", "-z"],
            text=False,
        )
        candidates = [
            path.decode("utf-8")
            for path in output.split(b"\0")
            if path
        ]
    except (FileNotFoundError, subprocess.CalledProcessError):
        candidates = []

    if candidates:
        files: list[str] = []
        for relative_path in candidates:
            relative_parts = Path(relative_path).parts
            if any(part in IGNORED_PATH_PARTS for part in relative_parts):
                continue

            absolute_path = root / relative_path
            if absolute_path.is_file():
                files.append("/".join(relative_parts))
        return sorted(files)

    files: list[str] = []
    for absolute_path in root.rglob("*"):
        if not absolute_path.is_file():
            continue

        relative_parts = absolute_path.relative_to(root).parts
        if any(part in IGNORED_PATH_PARTS for part in relative_parts):
            continue

        files.append("/".join(relative_parts))

    return sorted(files)


def should_mirror(path: str) -> bool:
    normalized = path.replace("\\", "/").strip()
    if not normalized or normalized == TARGET_RELATIVE_PATH:
        return False

    if normalized in MIRRORED_EXACT_FILES:
        return True

    if not any(normalized == prefix or normalized.startswith(prefix) for prefix in MIRRORED_PREFIXES):
        return False

    extension = Path(normalized).suffix.lower().lstrip(".")
    if not extension:
        return normalized in MIRRORED_EXACT_FILES

    return extension in MIRRORED_TEXT_EXTENSIONS


def mirrored_files(root: Path) -> dict[str, str]:
    files: dict[str, str] = {}
    for relative_path in iter_candidate_files(root):
        if not should_mirror(relative_path):
            continue
        absolute_path = root / relative_path
        content = absolute_path.read_text(encoding="utf-8").replace("\r\n", "\n")
        files[relative_path.replace("\\", "/")] = content
    return files


def seed_version(files: dict[str, str]) -> str:
    digest = hashlib.sha256()
    for relative_path in sorted(files):
        digest.update(relative_path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(files[relative_path].encode("utf-8"))
        digest.update(b"\0")
    return f"sha256-{digest.hexdigest()[:16]}"


def render_seed_file(files: dict[str, str]) -> str:
    version = seed_version(files)
    lines = [
        "import Foundation",
        "",
        "enum AgentWorkspaceSeed {",
        f'    static let version = "{version}"',
        "",
        "    static let files: [String: String] = [",
    ]

    for relative_path in sorted(files):
        encoded = base64.b64encode(files[relative_path].encode("utf-8")).decode("ascii")
        lines.append(f'        "{relative_path}": decode("{encoded}"),')

    lines.extend(
        [
            "    ]",
            "",
            "    private static func decode(_ value: String) -> String {",
            '        String(data: Data(base64Encoded: value) ?? Data(), encoding: .utf8) ?? ""',
            "    }",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate or verify the embedded agent workspace seed.")
    parser.add_argument("--check", action="store_true", help="Verify the generated file matches the repo state.")
    parser.add_argument(
        "--output",
        default=TARGET_RELATIVE_PATH,
        help="Relative path to the generated Swift file.",
    )
    args = parser.parse_args()

    root = repo_root()
    output_path = root / args.output
    rendered = render_seed_file(mirrored_files(root))

    if args.check:
        existing = output_path.read_text(encoding="utf-8").replace("\r\n", "\n") if output_path.exists() else ""
        if existing != rendered:
            print(f"Agent workspace seed is out of date: {output_path}", file=sys.stderr)
            return 1
        return 0

    output_path.write_text(rendered, encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
