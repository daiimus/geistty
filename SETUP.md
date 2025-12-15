# Environment Setup Guide

## Current Status

**⚠️ BLOCKER: Full Xcode Required**

The system currently has only Command Line Tools installed. Building the iOS
app and xcframework requires the full Xcode.app installation.

### Verified ✅
- **Zig**: 0.15.2 (compatible with ghostty v1.2.3 requirement of ≥0.14.1)
- **Homebrew**: 4.5.10
- **Ghostty repo**: Cloned at ~/Projects/Repositories/ghostty (v1.2.3)
- **SwiftTermApp**: Cloned at ~/Projects/Repositories/SwiftTermApp

### Missing ❌
- **Xcode.app**: Not installed (only Command Line Tools present)
- **iOS SDK**: Cannot locate `iphoneos` SDK
- **iOS Simulator**: Not available
- **Metal Toolchain**: Unavailable without Xcode

---

## Step 1: Install Xcode

1. Open the **Mac App Store**
2. Search for "Xcode"
3. Click **Get** / **Install** (~35GB download)
4. Wait for installation to complete

Or use `mas` (Mac App Store CLI):
```bash
brew install mas
mas install 497799835  # Xcode
```

## Step 2: Configure Xcode

After Xcode installation:

```bash
# Select full Xcode instead of Command Line Tools
sudo xcode-select --switch /Applications/Xcode.app

# Accept license agreement
sudo xcodebuild -license accept

# Verify installation
xcodebuild -version
# Should show: Xcode 15.x or 16.x

# Verify iOS SDK
xcrun --sdk iphoneos --show-sdk-path
# Should show: /Applications/Xcode.app/Contents/.../iPhoneOS.sdk

# Verify simulator SDK
xcrun --sdk iphonesimulator --show-sdk-path
# Should show: /Applications/Xcode.app/Contents/.../iPhoneSimulator.sdk
```

## Step 3: Build GhosttyKit XCFramework

```bash
cd ~/Projects/Repositories/ghostty

# Build the universal xcframework (macOS + iOS + iOS Simulator)
zig build -Demit-xcframework

# Output location
ls -la macos/GhosttyKit.xcframework/
```

The xcframework will contain:
- `macos-arm64_x86_64/` - Universal macOS (Apple Silicon + Intel)
- `ios-arm64/` - Physical iOS devices
- `ios-arm64-simulator/` - iOS Simulator

## Step 4: Create iOS Project

```bash
cd ~/Projects/Repositories/geistty

# Create Xcode project (via Xcode GUI or swift package)
mkdir -p Geistty
cd Geistty

# Initialize Swift Package (alternative to Xcode project)
swift package init --type executable --name Geistty
```

Or create via Xcode:
1. File → New → Project
2. iOS → App
3. Product Name: Geistty
4. Interface: SwiftUI
5. Language: Swift
6. Minimum Deployment: iOS 17.0

## Step 5: Link GhosttyKit

1. Drag `GhosttyKit.xcframework` into Xcode project
2. Add to "Frameworks, Libraries, and Embedded Content"
3. Set "Embed" to "Embed & Sign"

## Troubleshooting

### "SDK iphoneos cannot be located"
```bash
# Ensure full Xcode is selected
xcode-select -p
# Should show: /Applications/Xcode.app/Contents/Developer
# NOT: /Library/Developer/CommandLineTools
```

### "Xcode not fully installed"
Full Xcode.app must be downloaded from App Store, not just Command Line Tools.

### Build fails with Metal errors
Metal shader compiler requires Xcode with iOS SDK. Ensure:
```bash
xcrun --sdk iphoneos metal --version
```

---

## Version Compatibility Matrix

| Ghostty Version | Required Zig | Required Xcode | Notes |
|----------------|--------------|----------------|-------|
| v1.2.3 (current) | ≥0.14.1 | 15+ | Stable, recommended |
| v1.1.x | ≥0.13.0 | 15+ | |
| v1.0.x | ≥0.13.0 | 15+ | |
| main (tip) | ≥0.14.1 | 26 (beta) | macOS 26 SDK prep |

We are using **v1.2.3** which works with standard Xcode 15/16.

---

## Next Steps After Xcode Install

Once Xcode is installed and configured, continue with:
1. Build xcframework: `zig build -Demit-xcframework`
2. Create iOS app project
3. Integrate SSH library (libssh2)
4. Bridge SSH I/O to Ghostty surface
5. Test on Simulator
6. Deploy to device
