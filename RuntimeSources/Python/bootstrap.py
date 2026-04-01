import contextlib
import importlib.machinery
import io
import json
import os
import sys
import traceback
from pathlib import Path


def load_allowlist(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return {"allowed_modules": []}


def main() -> int:
    script_path = Path(os.environ["OLLAMAKIT_SCRIPT_PATH"])
    input_path = Path(os.environ["OLLAMAKIT_INPUT_PATH"])
    result_path = Path(os.environ["OLLAMAKIT_RESULT_PATH"])
    workspace_root = Path(os.environ.get("OLLAMAKIT_WORKSPACE_ROOT", "")).resolve()
    allowlist_path = os.environ.get("OLLAMAKIT_PYTHON_ALLOWLIST_PATH", "")

    payload = {
        "success": False,
        "stdout": "",
        "stderr": "",
        "exitCode": 1,
        "durationMs": 0,
        "result": None,
        "artifacts": [],
        "error": None,
    }

    input_value = None
    if input_path.exists():
        try:
            input_value = json.loads(input_path.read_text(encoding="utf-8"))
        except Exception as exc:
            payload["error"] = f"Failed to decode input JSON: {exc}"
            result_path.write_text(json.dumps(payload), encoding="utf-8")
            return 0

    allowlist = load_allowlist(allowlist_path) if allowlist_path else {"allowed_modules": []}
    if not allowlist.get("allowed_modules"):
        try:
            importlib.machinery.EXTENSION_SUFFIXES[:] = []
        except Exception:
            pass

    if workspace_root and workspace_root.exists():
        os.chdir(workspace_root)
        sys.path.insert(0, str(workspace_root))
        for candidate in [
            workspace_root / "site-packages",
            workspace_root / ".venv" / "lib",
            *sorted((workspace_root / ".venv" / "lib").glob("python*/site-packages")),
        ]:
            if candidate.exists():
                sys.path.insert(0, str(candidate))

    stdout_capture = io.StringIO()
    stderr_capture = io.StringIO()
    globals_dict = {
        "__name__": "__main__",
        "__file__": str(script_path),
        "input": input_value,
        "workspace_root": str(workspace_root),
        "result": None,
        "artifacts": [],
    }

    try:
        code = script_path.read_text(encoding="utf-8")
        with contextlib.redirect_stdout(stdout_capture), contextlib.redirect_stderr(stderr_capture):
            exec(compile(code, str(script_path), "exec"), globals_dict, globals_dict)
        payload["success"] = True
        payload["exitCode"] = 0
        payload["result"] = globals_dict.get("result")
        payload["artifacts"] = globals_dict.get("artifacts") or []
    except BaseException as exc:  # noqa: BLE001
        stderr_capture.write(traceback.format_exc())
        payload["error"] = str(exc)
        payload["exitCode"] = 1

    payload["stdout"] = stdout_capture.getvalue()
    payload["stderr"] = stderr_capture.getvalue()
    result_path.write_text(json.dumps(payload), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
