# Font Strategy

## Overview

Terminal fonts are critical to the user experience. This document covers font options, licensing, and implementation strategy.

## Goals

1. **Readability**: Clear distinction between similar characters (0/O, 1/l/I)
2. **Icon Support**: Powerline symbols, Nerd Font icons for modern shell prompts
3. **Performance**: Fast rendering with ligature support
4. **Licensing**: Fonts we can bundle legally

---

## Recommended Fonts

### Tier 1: Nerd Fonts Variants (Primary)

[Nerd Fonts](https://www.nerdfonts.com/) patches popular programming fonts with 10,000+ icons including:
- Powerline symbols
- Font Awesome
- Material Design Icons
- Octicons
- Devicons
- Weather Icons

#### Top Picks

| Font | Original | License | Notes |
|------|----------|---------|-------|
| **JetBrainsMono Nerd Font** | JetBrains Mono | OFL | Best overall; great ligatures |
| **FiraCode Nerd Font** | Fira Code | OFL | Popular; excellent ligatures |
| **CaskaydiaCove Nerd Font** | Cascadia Code | OFL | Microsoft's font; modern |
| **Hack Nerd Font** | Hack | MIT | Classic, clean |
| **SauceCodePro Nerd Font** | Source Code Pro | OFL | Adobe quality |
| **Meslo Nerd Font** | Meslo LG | Apache 2.0 | Apple-style |
| **Iosevka Nerd Font** | Iosevka | OFL | Narrow; good for small screens |

#### Installation (macOS for Development)

```bash
# Via Homebrew
brew install font-jetbrains-mono-nerd-font
brew install font-fira-code-nerd-font
brew install font-cascadia-code-nerd-font
```

#### Direct Download

From https://www.nerdfonts.com/font-downloads:
- Select font family
- Download `.tar.xz` archive
- Contains `.ttf` or `.otf` files

### Tier 2: System Fonts (Fallback)

iOS/iPadOS includes these monospace fonts:

| Font | Bundle ID | Notes |
|------|-----------|-------|
| **SF Mono** | System | Apple's programming font |
| **Menlo** | System | macOS classic |
| **Courier New** | System | Universal fallback |

**Limitation**: System fonts lack Powerline/Nerd Font icons. Users with fancy prompts will see missing glyphs (□).

### Tier 3: Bundled Standard Fonts

Fonts commonly bundled with terminal apps:

| Font | License | File Size | Notes |
|------|---------|-----------|-------|
| Source Code Pro | OFL | ~750KB | Adobe; SwiftTermApp bundles this |
| Fira Mono | OFL | ~280KB | Clean without ligatures |
| IBM Plex Mono | OFL | ~300KB | Modern IBM design |

---

## Nerd Fonts Deep Dive

### What's Included

Nerd Fonts patches each font with:

```
10,390+ icons from these sets:
├── Powerline & Powerline Extra (arrows, branch symbols)
├── Font Awesome (general icons)
├── Material Design Icons (Google style)
├── Weather Icons
├── Devicons (programming language icons)
├── Octicons (GitHub icons)
├── Font Logos (OS logos)
├── Pomicons (Pomodoro)
└── Codicons (VS Code icons)
```

### Font Variants

Each Nerd Font comes in variants:

| Variant | Suffix | Use Case |
|---------|--------|----------|
| Regular | `Nerd Font` | Variable-width icons |
| Mono | `Nerd Font Mono` | **Recommended** - Fixed-width icons |
| Propo | `Nerd Font Propo` | Proportional, non-monospace |

For terminal use, always use **Mono** variants.

### File Naming

Example: JetBrains Mono
```
JetBrainsMonoNerdFont-Regular.ttf
JetBrainsMonoNerdFont-Bold.ttf
JetBrainsMonoNerdFont-Italic.ttf
JetBrainsMonoNerdFont-BoldItalic.ttf
JetBrainsMonoNerdFontMono-Regular.ttf   # <-- Use this for terminal
JetBrainsMonoNerdFontMono-Bold.ttf
...
```

---

## Icon Reference

### Powerline Symbols

Essential for oh-my-zsh, Starship, Powerlevel10k prompts:

| Glyph | Codepoint | Name |
|-------|-----------|------|
|  | U+E0B0 | Left hard divider |
|  | U+E0B1 | Left soft divider |
|  | U+E0B2 | Right hard divider |
|  | U+E0B3 | Right soft divider |
|  | U+E0A0 | Branch |
|  | U+E0A1 | Line number |
|  | U+E0A2 | Padlock |

### Common Dev Icons

| Glyph | Name |
|-------|------|
|  | Git branch |
|  | Folder |
|  | JavaScript |
|  | Python |
|  | Apple |
|  | Linux |
|  | Docker |

### Searchable Reference

https://www.nerdfonts.com/cheat-sheet - Searchable database of all icons

---

## iOS Bundle Strategy

### Option 1: Bundle Nerd Fonts (Recommended)

Include TTF files in app bundle:

```swift
// Info.plist
<key>UIAppFonts</key>
<array>
    <string>JetBrainsMonoNerdFontMono-Regular.ttf</string>
    <string>JetBrainsMonoNerdFontMono-Bold.ttf</string>
    <string>JetBrainsMonoNerdFontMono-Italic.ttf</string>
    <string>FiraCodeNerdFontMono-Regular.ttf</string>
    <string>FiraCodeNerdFontMono-Bold.ttf</string>
</array>
```

Usage:
```swift
let font = UIFont(name: "JetBrainsMonoNerdFontMono-Regular", size: 14)
```

**Pros**: Full icon support, consistent experience
**Cons**: Larger app size (~2-5MB per font family)

### Option 2: System Fonts + Symbol Font Fallback

Use Nerd Fonts' `SymbolsOnly` font as fallback:

```swift
// Primary: System font
// Fallback: Nerd Fonts Symbols for icons
let descriptor = UIFontDescriptor(fontAttributes: [
    .family: "SF Mono",
    .cascadeList: [
        UIFontDescriptor(fontAttributes: [.family: "Symbols Nerd Font Mono"])
    ]
])
```

**Pros**: Smaller app, uses Apple's optimized fonts
**Cons**: Symbol alignment can be inconsistent

### Option 3: User-Provided Fonts

Let users install fonts via iOS Settings → General → Fonts:

```swift
// Query available fonts
let families = UIFont.familyNames.filter { $0.contains("Nerd") }
```

**Pros**: No bundle size increase, user choice
**Cons**: Complex UX, not all users know how to install fonts

---

## Implementation Plan

### Phase 1: Bundled Defaults

Bundle these fonts initially:
1. **JetBrainsMono Nerd Font Mono** - Primary default
2. **Hack Nerd Font Mono** - Alternative
3. **System fallback** - SF Mono / Menlo

### Phase 2: Font Settings UI

```swift
struct FontSettings: View {
    @State var selectedFont = "JetBrainsMonoNerdFontMono-Regular"
    @State var fontSize: CGFloat = 14
    
    var body: some View {
        Form {
            Picker("Font", selection: $selectedFont) {
                Text("JetBrains Mono").tag("JetBrainsMonoNerdFontMono-Regular")
                Text("Hack").tag("HackNerdFontMono-Regular")
                Text("SF Mono").tag("SFMono-Regular")
                Text("Menlo").tag("Menlo-Regular")
            }
            
            Stepper("Size: \(Int(fontSize))", value: $fontSize, in: 8...24)
        }
    }
}
```

### Phase 3: User-Installable Fonts

Add support for:
- Detecting user-installed fonts
- Font preview in picker
- Per-host font override

---

## Licensing Summary

All recommended fonts are freely distributable:

| Font | License | Attribution Required |
|------|---------|---------------------|
| JetBrains Mono | OFL 1.1 | In app credits |
| Fira Code | OFL 1.1 | In app credits |
| Cascadia Code | OFL 1.1 | In app credits |
| Hack | MIT | In app credits |
| Source Code Pro | OFL 1.1 | In app credits |

**OFL 1.1 Requirements**:
- Include copyright notice
- Include license text
- Don't sell the font standalone
- Don't use reserved font names in derivatives

---

## Resources

- **Nerd Fonts**: https://www.nerdfonts.com/
- **Font Downloads**: https://www.nerdfonts.com/font-downloads
- **Icon Cheat Sheet**: https://www.nerdfonts.com/cheat-sheet
- **GitHub Repo**: https://github.com/ryanoasis/nerd-fonts
- **Font Patcher** (to create your own): https://github.com/ryanoasis/nerd-fonts#font-patcher
