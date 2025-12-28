# App Store Submission Guide

This document contains the metadata and assets needed for App Store submission.

## App Information

### Basic Info
- **App Name**: Geistty
- **Subtitle**: SSH Terminal for iOS (30 char limit)
- **Bundle ID**: com.geistty.app
- **Primary Category**: Developer Tools
- **Secondary Category**: Utilities
- **Content Rating**: 4+ (No objectionable content)

### Version Info
- **Version**: 0.2.0
- **Build**: 2
- **Copyright**: © 2024 Geistty

## App Description

### Short Description (for search)
Professional SSH terminal client powered by Ghostty for iOS and iPad.

### Full Description (4000 char limit)

```
Geistty is a powerful SSH terminal client for iOS, bringing professional-grade terminal emulation to your iPhone and iPad.

POWERED BY GHOSTTY
Built on Ghostty's acclaimed terminal emulator core, Geistty delivers:
• Fast, accurate terminal emulation
• GPU-accelerated rendering
• Full Unicode and emoji support
• True color (24-bit) support
• Extensive color scheme library

PROFESSIONAL SSH CLIENT
• Save and manage multiple server connections
• SSH key authentication support
• Password authentication with secure Keychain storage
• Local network server discovery

CUSTOMIZABLE EXPERIENCE
• Multiple color themes (Dracula, Solarized, Nord, Tokyo Night, and more)
• Choice of monospace fonts (JetBrains Mono, Fira Code, SF Mono, and more)
• Adjustable font sizes
• Edit configuration directly in-app

DESIGNED FOR iOS
• Native SwiftUI interface
• iPad multi-window support
• Works with external keyboards
• Dark and light mode support

PRIVACY FOCUSED
• No analytics or tracking
• No data collection
• All credentials stored locally in iOS Keychain
• Open source core (Ghostty)

Perfect for developers, system administrators, and power users who need reliable SSH access on the go.
```

### Keywords (100 char limit)
```
ssh,terminal,console,remote,server,shell,command,cli,admin,devops,linux,unix,putty
```

### What's New (Version 0.2.0)
```
• Overhauled configuration system - config file is now source of truth
• Fixed theme selector to properly apply terminal colors
• Settings UI now follows selected theme
• Improved font configuration
• Added multiple new fonts
• Bug fixes and performance improvements
```

## Screenshots Required

### iPhone Screenshots (Required: 3-10)
Sizes needed:
- 6.7" (iPhone 15 Pro Max): 1290 x 2796 pixels
- 6.5" (iPhone 14 Plus): 1284 x 2778 pixels  
- 5.5" (iPhone 8 Plus): 1242 x 2208 pixels

Suggested screenshots:
1. Terminal connected to server (showing prompt)
2. Connection profiles list
3. Theme picker showing color options
4. Settings view
5. Multiple connections/tabs

### iPad Screenshots (Required if supporting iPad: 3-10)
Sizes needed:
- 12.9" iPad Pro: 2048 x 2732 pixels
- 11" iPad Pro: 1668 x 2388 pixels

Suggested screenshots:
1. Terminal full screen
2. Split view with multiple windows
3. Settings/preferences

### Capturing Screenshots

Using Xcode Simulator:
```bash
# iPhone 15 Pro Max
xcrun simctl io "iPhone 15 Pro Max" screenshot screenshot.png

# iPad Pro 12.9"
xcrun simctl io "iPad Pro (12.9-inch)" screenshot screenshot.png
```

Or use Cmd+S in Simulator to save to Desktop.

## App Preview Video (Optional)

- 15-30 seconds
- Show: connecting to server, typing commands, changing themes
- No audio required

## Privacy Policy

URL to host: Your GitHub Pages or website
Content: See PRIVACY.md in this repository

## Support URL

GitHub repository: https://github.com/yourusername/geistty
Or create a simple landing page

## App Review Information

### Demo Account (if needed)
If reviewers need to test SSH functionality, provide:
- A test server they can connect to, OR
- Note that the app requires user's own SSH server

### Review Notes
```
Geistty is an SSH terminal client that requires an SSH server to connect to. 
For testing, reviewers can:
1. Set up a local SSH server (if available)
2. Connect to a personal/test server

The app uses standard SSH protocol for secure connections. No special 
permissions are required beyond network access.
```

## Export Compliance

- **Uses Encryption**: Yes (SSH protocol via SwiftNIO-SSH)
- **Exempt**: Yes - Uses encryption solely for authentication and secure communications
- **ITSAppUsesNonExemptEncryption**: NO (exempt encryption)

SSH encryption qualifies for exemption under:
- ECCN 5D992 (mass market encryption)
- Uses standard protocols (SSH)
- No custom encryption implementations

## Age Rating

- No user-generated content: ✓
- No gambling: ✓
- No mature content: ✓
- **Recommended Rating**: 4+

## Pricing

- **Price Tier**: Free (or your chosen tier)
- **In-App Purchases**: None

## Territories

Available in all territories (or select specific ones)

---

## Pre-Submission Checklist

- [ ] App builds without errors
- [ ] All required screenshots captured
- [ ] Privacy policy hosted and accessible
- [ ] Support URL active
- [ ] App tested on physical devices
- [ ] Test on various iOS versions (iOS 15+)
- [ ] Test on iPhone and iPad
- [ ] Archive uploaded to App Store Connect
- [ ] Metadata filled in App Store Connect
- [ ] Build selected for submission
