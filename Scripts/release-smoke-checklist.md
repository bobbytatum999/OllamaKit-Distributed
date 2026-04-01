# OllamaKit Release Smoke Checklist

Use this checklist for both `stockSideload` and `jailbreak` builds before calling a release candidate shippable.

## CI Gates

- `python3 Scripts/generate-agent-workspace-seed.py --check` passes
- `swift test` passes
- GitHub Actions archives both unsigned IPAs:
  - `OllamaKit-stockSideload-unsigned.ipa`
  - `OllamaKit-jailbreak-unsigned.ipa`
- Variant build logs are uploaded for both archives

## Common App Smoke

- Launch the app and confirm SwiftData storage initializes without crashing
- Open each tab and confirm the app remains responsive
- Open Settings and confirm persisted values survive app restart
- Confirm the active/default model selection survives app restart

## Model and Runtime Smoke

- Browse suggested Hugging Face models and confirm recommendations match the real device profile
- Search Hugging Face manually and confirm results load without fake placeholder defaults
- Download a GGUF model and confirm post-download validation runs automatically
- Import a local GGUF file and confirm validation status updates
- Import a CoreML/ANEMLL package and confirm incomplete imports surface an actionable error
- Delete a model and confirm stale default-model references are cleared
- Create a chat, send a message, stream a response, and stop generation mid-stream

## API Server Smoke

- Start the API server and confirm the root route responds
- Confirm `/api/tags`, `/api/show`, `/api/chat`, `/api/generate`, `/v1/models`, `/v1/chat/completions`, and `/v1/responses` behave correctly for the selected validated model
- Confirm unsupported capability/model combinations return explicit errors
- Confirm public URL mode enforces API-key auth and surfaces canonical URL health
- Confirm live server logs show request routing, auth, model resolution, and response details

## Power Agent Smoke

- Open the Agent tab and refresh context
- Confirm the reported build variant and runtime tier are correct
- Read a workspace file, create a checkpoint, edit a file, and restore the checkpoint
- Confirm approval-gated actions require confirmation before mutating state
- Open the embedded browser, navigate to a page, read content, query DOM, and capture a screenshot
- Confirm browser form actions and downloads require approval
- Confirm tool availability changes when the active model lacks agent/browser/coding capabilities
- Confirm unavailable runtimes such as Python or Node fail explicitly instead of hanging

## GitHub Smoke

- Complete GitHub device flow authentication
- Search repositories or code and fetch a file successfully
- Refresh the built-in workspace from GitHub and confirm mirrored files stay text-safe
- Push a workspace snapshot and confirm the action is approval-gated
- Inspect workflow runs and fetch workflow logs or artifacts

## Variant-Specific Smoke

### stockSideload

- Confirm no live bundle workspace is registered
- Confirm bundle patch history and jailbreak-only bundle-edit tools are not exposed
- Confirm agent capability UI reports bundle editing as unavailable

### jailbreak

- Confirm `bundleLive` appears only when the installed bundle is actually writable
- Edit an allowed bundle resource/text asset and confirm a backup record is created
- Restore a bundle-backed checkpoint and confirm the original file returns
- Confirm restart-required messaging appears after live bundle mutations
- Confirm binary framework or Mach-O mutation remains blocked

## Release Notes Check

- README build instructions match the current workflow and artifact names
- The documented server/API behavior matches the current app behavior
- Any remaining non-blocking issues are documented with severity and reproduction notes
