# TestFlight Distribution Guide

This guide covers distributing Geistty via TestFlight for beta testing.

## Prerequisites

1. **Apple Developer Account** ($99/year)
   - Enroll at: https://developer.apple.com/programs/enroll/

2. **App Store Connect Access**
   - https://appstoreconnect.apple.com

3. **Xcode** with valid signing certificate

## Initial Setup

### 1. Create App in App Store Connect

1. Go to App Store Connect → My Apps → "+"
2. Select "New App"
3. Fill in:
   - Platform: iOS
   - Name: Geistty
   - Primary Language: English (US)
   - Bundle ID: com.geistty.app
   - SKU: geistty-001 (unique identifier)
   - User Access: Full Access

### 2. Configure Signing in Xcode

1. Open `Geistty.xcodeproj` in Xcode
2. Select Geistty target → Signing & Capabilities
3. Team: Select your Apple Developer team
4. Enable "Automatically manage signing"
5. Bundle Identifier: com.geistty.app

## Building for TestFlight

### Archive the App

```bash
# Using Xcode GUI (Recommended)
1. Product → Destination → Any iOS Device (arm64)
2. Product → Archive
3. Wait for archive to complete
```

Or via command line:
```bash
xcodebuild -project Geistty/Geistty.xcodeproj \
    -scheme Geistty \
    -sdk iphoneos \
    -configuration Release \
    -archivePath build/Geistty.xcarchive \
    archive
```

### Upload to App Store Connect

#### Via Xcode Organizer (Recommended)
1. Window → Organizer
2. Select the archive
3. Click "Distribute App"
4. Select "App Store Connect"
5. Select "Upload"
6. Follow prompts (signing, etc.)

#### Via Command Line
```bash
xcodebuild -exportArchive \
    -archivePath build/Geistty.xcarchive \
    -exportPath build/export \
    -exportOptionsPlist ExportOptions.plist
```

Then upload via `xcrun altool` or Transporter app.

## TestFlight Configuration

### 1. Test Information

In App Store Connect → TestFlight → Test Information:

- **Beta App Description**: 
  ```
  Geistty is an SSH terminal app for iOS powered by Ghostty.
  Test features include: SSH connections, theme customization,
  and terminal configuration.
  ```

- **Feedback Email**: your-email@example.com

- **What to Test**:
  ```
  - Connect to an SSH server using password or key authentication
  - Try different color themes in Settings
  - Test font changes and sizes
  - Edit the ghostty.conf configuration
  - Test keyboard input and terminal escape sequences
  ```

### 2. Internal Testing

Internal testers (up to 100) receive builds automatically.

1. Go to TestFlight → Internal Testing
2. Add testers by Apple ID email
3. Testers receive email invite
4. Builds appear automatically after processing

### 3. External Testing (Public Beta)

External testers (up to 10,000) require App Review.

1. Go to TestFlight → External Testing
2. Create a group (e.g., "Beta Testers")
3. Add testers by email or public link
4. Submit build for Beta App Review
5. Review typically takes 24-48 hours

### 4. Public Link

For wider distribution:
1. TestFlight → External Groups → Your Group
2. Enable "Public Link"
3. Share the link (up to 10,000 testers)

## Build Management

### Build Numbers

Each upload needs a unique build number:

```bash
# In project.pbxproj
CURRENT_PROJECT_VERSION = 3  # Increment for each upload
MARKETING_VERSION = 0.2.0    # User-facing version
```

### Automatic Processing

After upload:
1. Processing (10-30 minutes)
2. Compliance review (automatic for exempt encryption)
3. Available for internal testing
4. Submit for external review (if needed)

## Testing Workflow

### Recommended Flow

1. **Development**: Build locally, test on device
2. **Internal Alpha**: Upload to TestFlight, test with team
3. **External Beta**: Submit for review, wider testing
4. **Release**: Submit to App Store

### Version Progression

```
0.1.0 (build 1) - Initial internal test
0.1.0 (build 2) - Bug fixes
0.2.0 (build 3) - New features, external beta
0.2.0 (build 4) - Beta feedback fixes
1.0.0 (build 5) - Release candidate
1.0.0 (build 6) - App Store release
```

## Troubleshooting

### "Missing Compliance" Warning
- Already fixed: ITSAppUsesNonExemptEncryption = NO in Info.plist

### "Invalid Binary" 
- Check minimum iOS version matches capabilities
- Ensure all required icons are present
- Verify code signing

### Build Stuck Processing
- Usually resolves in 30 minutes
- If >1 hour, try re-uploading

### Testers Not Receiving Builds
- Check TestFlight app is installed
- Verify email address is correct
- Check for invite in email spam

## Collecting Feedback

TestFlight provides:
- Crash reports
- Screenshots from testers
- Tester feedback via TestFlight app

Access in App Store Connect → TestFlight → Crashes/Feedback

## Quick Reference

| Task | Location |
|------|----------|
| Upload build | Xcode → Organizer → Distribute |
| Add testers | App Store Connect → TestFlight |
| View crashes | App Store Connect → TestFlight → Crashes |
| Expire build | TestFlight → Build → Expire Build |
| Release to Store | App Store Connect → App Store → Submit |

---

## Checklist Before TestFlight

- [ ] Valid Apple Developer account
- [ ] App created in App Store Connect
- [ ] Signing certificates configured
- [ ] Build number incremented
- [ ] Archive successful
- [ ] Upload completed
- [ ] Test information filled
- [ ] Testers added
- [ ] (External) Submitted for Beta App Review
