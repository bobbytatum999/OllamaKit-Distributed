# OllamaKit

A powerful iOS app for running local Large Language Models (LLMs) with an OpenAI-compatible API server. Built with iOS 26 Liquid Glass design principles.

> [!IMPORTANT]
> The app now expects a linked `llama.cpp` XCFramework for real on-device GGUF inference.
> GitHub Actions builds that runtime automatically from the pinned upstream `llama.cpp` tag before archiving the unsigned IPA.

![Platform](https://img.shields.io/badge/platform-iOS%2026.0+-blue.svg)
![Swift](https://img.shields.io/badge/swift-5.9-orange.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

## Features

### Core Functionality
- **Local LLM Inference** - Run GGUF models on-device through a linked `llama.cpp` runtime with streaming token output
- **Hugging Face Integration** - Browse and download models from Hugging Face Hub with device-aware suggestions and post-download validation
- **OpenAI-Compatible API Surface** - Use `/v1/models`, `/v1/completions`, `/v1/chat/completions`, and `/v1/responses` with existing OpenAI clients
- **Background Server Wakeups** - Best-effort background task restarts within iOS limits
- **Chat Interface** - Beautiful chat UI with markdown rendering and streaming responses

### Model Support
- GGUF format models (Q2_K to FP32 quantization)
- Context lengths up to 32K tokens
- GPU layer offloading for Metal performance
- Memory mapping and locking options
- Flash Attention support

### Server Features
- Configurable port (default: 11434)
- Local-only, local-network, managed-public-relay, and custom-public-URL exposure modes
- Automatic API-key enforcement for public exposure modes
- Live structured server logs with request, response, auth, model-load, and stream details
- Background task management
- Capability-aware Ollama-style and OpenAI-style routes, including `/api/show` and `/v1/responses`
- Power-agent control routes under `/api/agent/*`

### Sideload Power Agent
- Built-in mutable OllamaKit workspace mirror stored under app support, with the installed app bundle kept read-only
- Deterministic embedded workspace seed generated from tracked text files, with CI drift detection
- Extra internal workspaces for mutable data, downloaded pages/assets, and GitHub-backed repo clones
- Workspace tools for listing, reading, searching, diffing, writing, moving, deleting, activating, cloning, and resetting files
- Automatic checkpoints before destructive agent operations, with manual restore points from the UI
- Embedded browser sessions with DOM reading, link extraction, screenshots, page saving, downloads, and approval-gated form actions
- Agent tab for runtime context, approvals, checkpoints, browser tabs, GitHub auth/search/actions flows, preview status, bundle patch history, and live agent logs
- Local static web preview scaffolding plus JavaScriptCore-backed script execution
- Bridge-based embedded runtime slots for Python, Node.js, and Swift/SwiftPM with runtime inventory reporting
- GitHub repository metadata, repo/code search, issues, pull requests, workflow-run lookup, workspace refresh, repo snapshot clone, branch creation, PR creation, and branch snapshot push support
- Explicit tool inventory with approval-gated write and network-side-effect actions
- Conservative per-model agent capability defaults, with manual override controls in the model catalog
- Browser, workspace, GitHub, runtime, and remote-CI tools only expose themselves when the active model is allowed to use them
- Optional live-bundle workspace on writable jailbreak-style installs, with per-file backups and restart-oriented patch history
- Manual release smoke checklist in `Scripts/release-smoke-checklist.md`

> [!NOTE]
> The current power-agent build ships the workspace, checkpoint, browser, GitHub, restricted shell-style, JavaScript, preview, managed-relay plumbing, and `/api/agent/*` surfaces now. Python, Node.js, and Swift runtime tools only become available when their embedded bridge frameworks are actually bundled into the build, and the UI/API report that runtime truth explicitly.

### iOS 26 Liquid Glass Design
- Animated mesh gradient backgrounds
- Ultra-thin material cards
- Smooth transitions and effects
- Dark mode optimized
- Haptic feedback throughout

## Screenshots

| Chat | Models | Server | Settings |
|------|--------|--------|----------|
| ![Chat](screenshots/chat.png) | ![Models](screenshots/models.png) | ![Server](screenshots/server.png) | ![Settings](screenshots/settings.png) |

## Requirements

- iOS 26.0 or later
- iPhone or iPad with A12 chip or newer (for best performance)
- At least 4GB RAM (8GB+ recommended for larger models)
- Free storage space for models (2-8GB per model)

## Installation

This project is aimed at sideloaded installs. The power-agent functionality is designed for that profile and is not constrained to an App Store-safe feature set.
GitHub Actions now produces two unsigned IPA variants from the same codebase: `stockSideload` and `jailbreak`.

### Download Pre-built IPA

1. Go to the [Releases](https://github.com/NightVibes3/OllamaKit/releases) page
2. Download either `OllamaKit-stockSideload-unsigned.ipa` or `OllamaKit-jailbreak-unsigned.ipa`
3. Sign and install using one of the methods below

### Sign with AltStore

1. Install [AltStore](https://altstore.io) on your device
2. Download the IPA to your device
3. Open AltStore → My Apps
4. Tap the "+" button and select the IPA
5. Enter your Apple ID when prompted

### Sign with Sideloadly

1. Download and install [Sideloadly](https://sideloadly.io) on your computer
2. Connect your iOS device
3. Drag the IPA into Sideloadly
4. Enter your Apple ID credentials
5. Click "Start" to install

### Sign with TrollStore (if supported)

1. Install TrollStore on your device
2. Download the IPA
3. Share the file to TrollStore
4. The app will be installed permanently

## Building from Source

### Prerequisites

- macOS 15.0 or later
- Xcode 26.0 or later
- iOS 26.0+ SDK
- CMake 3.28.0 or later
- Active Apple Developer account (for device testing)

### Clone and Build

```bash
# Clone the repository
git clone https://github.com/NightVibes3/OllamaKit.git
cd OllamaKit

# Build the llama.cpp iOS XCFramework
git clone --depth 1 --branch b8548 https://github.com/ggml-org/llama.cpp.git .deps/llama.cpp
bash Scripts/build-llama-ios-xcframework.sh ./.deps/llama.cpp ./Vendor/llama.xcframework

# Open in Xcode
open OllamaKit.xcodeproj

# Or build from command line
xcodebuild -project OllamaKit.xcodeproj -scheme OllamaKit -configuration Release
```

### Build Variants

The app now uses one codebase with two release variants:

- `stockSideload` for the normal sideload profile
- `jailbreak` for builds that are allowed to expose the live bundle workspace

The active variant is embedded into the app bundle as `OllamaKitBuildVariant` and is also surfaced through the agent/server context endpoints.

## Agent API

The server now exposes a small power-agent control surface alongside the Ollama-style and OpenAI-style routes:

- `GET /api/agent/context`
- `GET /api/agent/tools`
- `GET /api/agent/workspaces`
- `GET /api/agent/checkpoints`
- `GET /api/agent/approvals`
- `POST /api/agent/execute`
- `POST /api/agent/approvals/approve`
- `POST /api/agent/approvals/reject`

These routes are intended for explicit tool execution and approval handling against the mutable workspace mirror, not for direct mutation of the installed app bundle.
Browser navigation, GitHub search, workflow inspection, bundle patch history, repo cloning, and all other power-agent actions are exposed through the `tool` values accepted by `POST /api/agent/execute`. `GET /api/agent/context` and `GET /api/agent/tools` include the active agent model plus the effective model-gated capability set that controls browser, coding, GitHub, and remote-CI access.

### Build Unsigned IPA

```bash
# Keep the embedded workspace seed in sync
python3 Scripts/generate-agent-workspace-seed.py --check

# Build the llama.cpp iOS XCFramework
git clone --depth 1 --branch b8548 https://github.com/ggml-org/llama.cpp.git .deps/llama.cpp
bash Scripts/build-llama-ios-xcframework.sh ./.deps/llama.cpp ./Vendor/llama.xcframework

# Build stock sideload archive
xcodebuild archive \
  -project OllamaKit.xcodeproj \
  -scheme OllamaKit \
  -configuration Release \
  -sdk iphoneos \
  -archivePath build/OllamaKit-stock.xcarchive \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  OLLAMAKIT_BUILD_VARIANT=stockSideload \
  OTHER_SWIFT_FLAGS="$(inherited) -D OLLAMAKIT_VARIANT_STOCK_SIDELOAD"

# Build jailbreak archive
xcodebuild archive \
  -project OllamaKit.xcodeproj \
  -scheme OllamaKit \
  -configuration Release \
  -sdk iphoneos \
  -archivePath build/OllamaKit-jailbreak.xcarchive \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  OLLAMAKIT_BUILD_VARIANT=jailbreak \
  OTHER_SWIFT_FLAGS="$(inherited) -D OLLAMAKIT_VARIANT_JAILBREAK" \
  PRODUCT_BUNDLE_IDENTIFIER=com.ollamakit.app.jailbreak \
  PRODUCT_NAME=OllamaKitJailbreak

# Create stock IPA
mkdir -p build/Payload
cp -R build/OllamaKit-stock.xcarchive/Products/Applications/OllamaKit.app build/Payload/
cd build && zip -r OllamaKit-stockSideload-unsigned.ipa Payload
```

Repeat the `Payload` packaging step for `build/OllamaKit-jailbreak.xcarchive/Products/Applications/OllamaKitJailbreak.app` to create `OllamaKit-jailbreak-unsigned.ipa`.

## Usage

### First Launch

1. Open OllamaKit
2. Go to the **Models** tab
3. Search for a GGUF chat model on Hugging Face
4. Select a quantization level (Q4_K_M recommended for balance)
5. Download the model
6. Wait for the app to validate that the downloaded GGUF actually loads on your device before using it in chat or through the server

### Chatting

1. Go to the **Chat** tab
2. Tap the compose button to start a new chat
3. Select your downloaded model
4. Choose a system prompt or customize your own
5. Start chatting!

### Using the API Server

1. Go to the **Server** tab
2. Start the server (or enable auto-start)
3. Note the connection URL (default: `http://127.0.0.1:11434`)
4. Use with any OpenAI-compatible client:

```bash
# List validated server-runnable models
curl http://localhost:11434/api/tags

# Generate completion
curl -X POST http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "MODEL_ID_FROM_/api/tags",
    "prompt": "Why is the sky blue?"
  }'

# Chat completion
curl -X POST http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "MODEL_ID_FROM_/api/tags",
    "messages": [
      {"role": "user", "content": "Hello!"}
    ]
  }'
```

When multiple downloaded files come from the same Hugging Face repo, use the exact identifier returned by `/api/tags` or `/v1/models`. The app exposes a composite identifier so API clients can target a specific downloaded quantization/file. These routes only advertise models that are both installed and validated as runnable on the current device.

### Connecting from Other Devices

1. Choose an exposure mode in the **Server** tab:
   - `Local Only` for loopback clients
   - `Local Network` for other devices on the same reachable network
   - `Managed Public URL` to keep a device tunnel open to the configured OllamaKit relay service
   - `Custom Public URL` for your own tunnel or reverse proxy URL
2. For `Local Network`, use the Network URL shown in the Server tab.
3. For `Managed Public URL`, enter the relay service URL. The app will register the device and show the assigned public endpoint once the relay connects.
4. For `Custom Public URL`, enter the external `http://` or `https://` URL from your tunnel or reverse proxy. OllamaKit does not create the tunnel in that mode.
5. Include the API key in requests whenever authentication is enabled. Public exposure modes always require an API key:

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" \
  http://DEVICE_IP:11434/api/tags
```

## Settings Reference

### Model Parameters
| Setting | Default | Description |
|---------|---------|-------------|
| Temperature | 0.7 | Randomness of output (0-2) |
| Top P | 0.9 | Nucleus sampling threshold |
| Top K | 40 | Top-k sampling limit |
| Repeat Penalty | 1.1 | Penalty for repetition |
| Context Length | 4096 | Maximum context tokens |
| Max Tokens | -1 | Max generation tokens (-1 = unlimited) |

### Performance Settings
| Setting | Default | Description |
|---------|---------|-------------|
| CPU Threads | Auto | Number of inference threads |
| Batch Size | 512 | Processing batch size |
| GPU Layers | 0 | Layers to offload to GPU |
| Flash Attention | Off | Enable faster attention |
| TurboQuant Mode | Disabled | Google TurboQuant-inspired KV presets (experimental) |
| KV Cache Type (K) | F16 | Experimental K-cache precision selector |
| KV Cache Type (V) | F16 | Experimental V-cache precision selector |

### Memory Management
| Setting | Default | Description |
|---------|---------|-------------|
| Memory Mapping | On | Map model files to memory |
| Lock Memory | Off | Prevent swapping to disk |
| Keep Model Loaded | Off | Don't unload after generation |
| Auto-offload Delay | 5 min | Minutes before unloading |

## Recommended Models

The app now generates recommendations on-device instead of relying on a static list. Suggested downloads are filtered against the real iPhone or iPad runtime profile and favor repositories that look like actual chat/text-generation GGUF models. Manual search remains broad, but downloaded GGUF models must pass validation before they are treated as runnable.

## Troubleshooting

### Model downloads but is not usable
- Check the validation status in the Models tab
- Try a smaller quantization or a smaller model
- Import or pull the full model again if the payload is incomplete
- Use the in-app Revalidate action after changing device conditions or app settings

### Model fails to load
- Check available RAM (Settings → General → iPhone Storage)
- Try a smaller model or higher quantization (Q4 vs Q8)
- Reduce context length in settings
- Enable memory mapping

### Slow generation
- Increase GPU layers (if device supports Metal)
- Reduce context length
- Use a smaller model
- Enable Flash Attention

### Server not accessible
- Check if server is running in the Server tab
- Verify port is not blocked by another app
- Try a different port number
- Check firewall settings for external connections

### App crashes
- Ensure sufficient free RAM (close other apps)
- Try a smaller model
- Reset settings to defaults
- Check iOS version compatibility

## Architecture

```
Sources/OllamaKit/
├── OllamaKitApp.swift           # App entry point
├── AppModels.swift              # SwiftData models + app settings
├── Views/
│   ├── ContentView.swift
│   ├── ChatSessionsView.swift
│   ├── ChatView.swift
│   ├── ModelsView.swift
│   ├── ServerView.swift
│   └── SettingsView.swift
├── Services/
│   ├── ModelRunner.swift        # llama.cpp integration
│   ├── HuggingFaceService.swift
│   ├── ServerManager.swift      # HTTP API server
│   └── BackgroundTaskManager.swift
├── Info.plist
├── OllamaKit.entitlements
├── Assets.xcassets/
└── OllamaKit.xcodeproj/
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/tags` | List validated server-runnable models with capabilities |
| POST | `/api/show` | Show model validation and capability detail |
| POST | `/api/generate` | Generate completion with capability checks |
| POST | `/api/chat` | Chat completion with capability checks |
| POST | `/api/pull` | Download model and validate it |
| DELETE | `/api/delete` | Delete model |
| GET | `/api/ps` | List running models |
| GET | `/v1/models` | OpenAI-compatible model list with capabilities |
| POST | `/v1/completions` | OpenAI-compatible completions |
| POST | `/v1/chat/completions` | OpenAI-compatible chat completions |
| POST | `/v1/responses` | OpenAI-style rich responses |

`/api/embed` and `/v1/embeddings` are capability-gated. If the selected model does not advertise embeddings, the server returns an explicit unsupported-capability error. Embeddings are still not implemented by the local runtime in this build.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp) - The inference engine
- [Ollama](https://ollama.ai) - API inspiration
- [Hugging Face](https://huggingface.co) - Model hosting
- [SwiftUI](https://developer.apple.com/xcode/swiftui/) - UI framework

## Disclaimer

This app is not affiliated with Ollama or Hugging Face. Use at your own risk. Running large language models on mobile devices may impact battery life and device performance.

## Support

- [GitHub Issues](https://github.com/NightVibes3/OllamaKit/issues)
- [Discussions](https://github.com/NightVibes3/OllamaKit/discussions)

---

Built for local AI on iPhone and iPad
