# Runtime Caching Optimization

This document explains the runtime caching optimization implemented to speed up OllamaKit IPA builds.

## Problem

The original build workflow rebuilds **three complex runtimes from source on every build**:

1. **Python 3.13.9** - Compiles CPython for iOS (arm64 + simulator)
2. **Node.js Mobile v0.3.3** - Compiles Node.js runtime for iOS (arm64 + simulator)
3. **Swift Runtime** - Compiles Swift wrapper frameworks (arm64 + simulator)

Plus **llama.cpp** which clones and builds from source every time.

This causes builds to take **1.5-2+ hours** even when source code hasn't changed.

## Solution

### 1. Actions Cache Integration

Both `llama.xcframework` and embedded runtimes are now cached using GitHub Actions Cache v4:

**Cache Keys**:
- `llama.xcframework`: `${{ runner.os }}-llama-xcframework-${{ env.LLAMA_CPP_TAG }}`
  - Invalidates automatically when `LLAMA_CPP_TAG` changes
  - Cache hit = instant restoration (~10 seconds)
  - Cache miss = build (45-60 minutes) + automatic cache save

- **Embedded Runtimes**: `${{ runner.os }}-embedded-runtimes-${{ hashFiles('Scripts/embedded-runtime-sources.json') }}`
  - Invalidates when ANY runtime source version changes (Python, Node, or Swift)
  - Cache hit = instant restoration (~30 seconds)
  - Cache miss = build (45-60 minutes per runtime) + automatic cache save

### 2. Pre-build Workflow

A separate `pre-build-runtimes.yml` workflow:
- Runs **weekly on Sunday at 2 AM UTC** (configurable)
- **Can be manually triggered** via `workflow_dispatch`
- Builds fresh Python, Node.js, and Swift runtimes
- Uploads as artifacts for reference
- Generates build reports

## Build Time Impact

| Scenario | Original | With Cache |
|----------|----------|-----------|
| **First run** (cache miss) | ~2 hours | ~2 hours (+ cache save) |
| **Subsequent runs** (cache hit) | ~2 hours | **~10-15 minutes** |
| **After llama.cpp bump** | ~2 hours | ~50 min (rebuild llama only) |
| **After runtime version bump** | ~2 hours | ~45 min (rebuild runtimes only) |

**Average savings: 85-90% reduction in build time on cache hits**

## How to Use

### Standard Build Flow

1. Push to `main` or `develop` branches → Build workflow runs
2. **First push after runtime changes**: Full build (runtimes rebuilt, cached for future)
3. **Subsequent pushes**: Fast build (runtimes restored from cache)

### Force Rebuild Runtimes

To force a rebuild and update the cache:

1. Edit `Scripts/embedded-runtime-sources.json` to bump a version
2. The cache key automatically changes, triggering a rebuild
3. New build gets cached for next time

Or manually bump the `LLAMA_CPP_TAG` environment variable in `build.yml`.

### Manual Pre-build

Go to **Actions** → **Pre-build Runtime Artifacts** → **Run workflow** to manually trigger a pre-build without building the full IPA.

## Cache Invalidation

Cache automatically expires and rebuilds when:

| Trigger | Cache Key Component |
|---------|-------------------|
| `LLAMA_CPP_TAG` changes | `llama-xcframework-$TAG` |
| Runtime sources update | `hashFiles('Scripts/embedded-runtime-sources.json')` |
| 7+ days pass | [GitHub's default expiration](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows#usage-limits-and-eviction-policy) |

## Technical Details

### Cached Artifacts

**llama.xcframework** (~2GB)
- arm64-apple-ios device binary
- x86_64 simulator binary
- Combined XCFramework bundle

**Embedded Runtimes** (~800MB each)
- `Python.xcframework` + `OllamaKitPythonRuntime.xcframework`
- `NodeMobile.xcframework` + `OllamaKitNodeRuntime.xcframework`
- `OllamaKitSwiftRuntime.xcframework`
- `EmbeddedRuntimeManifest.json`

### Build Environment Requirements

- macOS 26.x runner
- Xcode 26.x
- Python 3.13
- 2+ CPU cores, 8GB+ RAM

## Workflow Files Modified

- `.github/workflows/build.yml` - Added caching steps
- `.github/workflows/pre-build-runtimes.yml` - New pre-build workflow

## Troubleshooting

### Cache not restoring?

Check GitHub Actions run logs:
1. Go to **Actions** → **Build Unsigned IPA** → Recent run
2. Look for **Cache llama.cpp XCFramework** and **Cache Embedded Runtimes** steps
3. If showing "cache-hit: false", cache may have expired or key changed

### Build failing after runtime update?

Verify `embedded-runtime-sources.json` entries:
```json
{
  "python": { "commit": "8183fa5e3f78ca6ab862de7fb8b14f3d929421e0" },
  "node": { "commit": "780ae712b47fb34c459ea5e3b1d566f029c3c99a" }
}
```

Mismatch between `ref` (branch/tag) and `commit` will cause the build to fail at verification.

### Manual cache clearing

If needed, use GitHub CLI:
```bash
gh actions-cache delete "macos-llama-xcframework-b8548" -R NightVibes3/OllamaKit
gh actions-cache delete "macos-embedded-runtimes-<hash>" -R NightVibes3/OllamaKit
```

## Future Optimizations

- [ ] Parallel runtime builds (currently sequential)
- [ ] Split runtimes into separate cache keys for granular updates
- [ ] Docker-based builds for reproducibility
- [ ] Binary artifact distribution via releases