"use strict";

const fs = require("fs");
const path = require("path");
const Module = require("module");

const scriptPath = process.env.OLLAMAKIT_SCRIPT_PATH;
const inputPath = process.env.OLLAMAKIT_INPUT_PATH;
const resultPath = process.env.OLLAMAKIT_RESULT_PATH;
const workspaceRoot = process.env.OLLAMAKIT_WORKSPACE_ROOT || process.cwd();
const allowlistPath = process.env.OLLAMAKIT_NODE_ALLOWLIST_PATH || "";

function loadAllowlist() {
  try {
    if (!allowlistPath) {
      return { allowedAddons: [] };
    }
    return JSON.parse(fs.readFileSync(allowlistPath, "utf8"));
  } catch {
    return { allowedAddons: [] };
  }
}

function blockRestrictedModules(allowlist) {
  const blocked = new Set(["child_process", "cluster", "worker_threads"]);
  const originalLoad = Module._load;
  Module._load = function patchedLoad(request, parent, isMain) {
    if (blocked.has(request)) {
      throw new Error(`Module '${request}' is unavailable inside the embedded Node runtime.`);
    }
    if (request.endsWith(".node")) {
      if (!allowlist.allowedAddons || !allowlist.allowedAddons.includes(path.basename(request))) {
        throw new Error(`Native addon '${request}' is not allowlisted in this build.`);
      }
    }
    return originalLoad.call(this, request, parent, isMain);
  };
  Module._extensions[".node"] = function nativeAddonLoader(_module, filename) {
    if (!allowlist.allowedAddons || !allowlist.allowedAddons.includes(path.basename(filename))) {
      throw new Error(`Native addon '${filename}' is not allowlisted in this build.`);
    }
    throw new Error("Allowlisted native addons are not wired yet in the embedded runtime.");
  };
}

async function main() {
  const stdoutLines = [];
  const stderrLines = [];
  const originalLog = console.log;
  const originalError = console.error;

  console.log = (...args) => stdoutLines.push(args.map((value) => String(value)).join(" "));
  console.error = (...args) => stderrLines.push(args.map((value) => String(value)).join(" "));

  let payload = {
    success: false,
    stdout: "",
    stderr: "",
    exitCode: 1,
    durationMs: 0,
    result: null,
    artifacts: [],
    error: null,
  };

  try {
    const allowlist = loadAllowlist();
    blockRestrictedModules(allowlist);
    process.chdir(workspaceRoot);

    const inputValue = inputPath ? JSON.parse(fs.readFileSync(inputPath, "utf8")) : null;
    const source = fs.readFileSync(scriptPath, "utf8");
    const syntheticEntry = path.join(workspaceRoot, "__ollamakit__.js");
    const localRequire = Module.createRequire(syntheticEntry);
    const dirname = path.dirname(scriptPath);
    const moduleShim = { exports: {} };
    const executionContext = {
      artifacts: [],
      result: undefined,
    };
    const originalResult = globalThis.result;
    const originalArtifacts = globalThis.artifacts;
    globalThis.result = undefined;
    globalThis.artifacts = executionContext.artifacts;
    const runner = new Function(
      "input",
      "workspaceRoot",
      "require",
      "module",
      "exports",
      "__filename",
      "__dirname",
      "context",
      `${source}
return typeof globalThis.result === "undefined" ? module.exports : globalThis.result;`
    );
    try {
      const result = await runner(
        inputValue,
        workspaceRoot,
        localRequire,
        moduleShim,
        moduleShim.exports,
        scriptPath,
        dirname,
        executionContext
      );

      payload.success = true;
      payload.exitCode = 0;
      payload.result = result;
      payload.artifacts = Array.isArray(globalThis.artifacts) ? globalThis.artifacts : executionContext.artifacts;
    } finally {
      if (typeof originalResult === "undefined") {
        delete globalThis.result;
      } else {
        globalThis.result = originalResult;
      }

      if (typeof originalArtifacts === "undefined") {
        delete globalThis.artifacts;
      } else {
        globalThis.artifacts = originalArtifacts;
      }
    }
  } catch (error) {
    stderrLines.push(error && error.stack ? error.stack : String(error));
    payload.error = error ? String(error.message || error) : "Unknown embedded Node failure.";
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }

  payload.stdout = stdoutLines.join("\n");
  payload.stderr = stderrLines.join("\n");
  fs.writeFileSync(resultPath, JSON.stringify(payload));
}

main().then(
  () => process.exit(0),
  (error) => {
    const payload = {
      success: false,
      stdout: "",
      stderr: error && error.stack ? error.stack : String(error),
      exitCode: 1,
      durationMs: 0,
      result: null,
      artifacts: [],
      error: error ? String(error.message || error) : "Unknown embedded Node failure.",
    };
    fs.writeFileSync(resultPath, JSON.stringify(payload));
    process.exit(1);
  }
);
