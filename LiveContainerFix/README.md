# LiveContainer Fix for OllamaKit "Bad file descriptor" Error

## Problem
When running OllamaKit IPA inside LiveContainer, the error occurs:
```
Failed to map /var/mobile/Containers/Data/Application/.../Documents/Applications/Unknown.app/(null): Bad file descriptor
```

This happens because:
1. The OllamaKit IPA has a malformed Info.plist missing `CFBundleExecutable`
2. The app gets installed as "Unknown.app" (missing CFBundleIdentifier)
3. The executable path becomes "(null)" causing the mmap to fail

## Solution
The fix adds validation at multiple points:

### 1. LCMachOUtils.m - LCParseMachO function
- Added path validation to detect "(null)" in paths
- Added proper error checking for open(), fstat() calls
- Added file size validation before mmap

### 2. LCAppInfo.m - patchExecAndSignIfNeedWithCompletionHandler
- Added validation for CFBundleExecutable before attempting to patch/sign
- Returns clear error message if executable is missing

### 3. LCAppInfo.h
- Added infoPlist method to expose the Info.plist dictionary

### 4. LCAppListView.swift - installIpa function
- Added validation for CFBundleIdentifier during installation
- Added validation for CFBundleExecutable during installation
- Prevents installation of corrupted IPAs

### 5. LCBootstrap.m - invokeAppMain function
- Added validation for CFBundleExecutable before launching
- Added validation for executable path validity

## Files Modified
- LiveContainer/LCMachOUtils.m
- LiveContainerSwiftUI/Models/LCAppInfo.m
- LiveContainerSwiftUI/Models/LCAppInfo.h
- LiveContainerSwiftUI/Views/AppList/LCAppListView.swift
- LiveContainer/LCBootstrap.m

## Testing
After applying this fix:
1. Installing OllamaKit IPA will show a clear error about missing CFBundleExecutable
2. Other corrupted IPAs will be rejected during installation
3. Apps already installed with issues will show better error messages when launched
