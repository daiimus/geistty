# Font Strategy

## Overview

Terminal fonts are critical to the user experience. This document covers Geistty's font configuration, bundled fonts, and future plans.

## Current State (v0.1-stable)

### Bundled Font

| Font | License | File | Notes |
|------|---------|------|-------|
| **Departure Mono** | OFL 1.1 | `Resources/Fonts/DepartureMono-Regular.otf` | Default font. Clean monospace with good glyph coverage. |

### System Fonts (Available)

| Font | Notes |
|------|-------|
| **Menlo** | macOS/iOS classic monospace |
| **Courier New** | Universal fallback |

### Font Picker (SettingsView)

The in-app font picker offers: **Departure Mono**, **Menlo**, **Courier New**.

Font selection is persisted to `ghostty.conf` via the `font-family` config key.
Live updates use `ghostty_surface_update_config()`.

### Font Mapping

Font name translation between GUI display names and CoreText/Ghostty identifiers is centralized in `Sources/Ghostty/FontMapping.swift`:

```swift
// GUI name → Ghostty config value
"Departure Mono" → "DepartureMono-Regular"
"Menlo"          → "Menlo"
"Courier New"    → "Courier New"
```

---

## Nerd Fonts (Future)

[Nerd Fonts](https://www.nerdfonts.com/) patches popular programming fonts with 10,000+ icons (Powerline, Font Awesome, Material Design, Devicons, etc.). These are important for users with fancy shell prompts (Starship, Powerlevel10k).

### Why We Don't Bundle Nerd Fonts Yet

1. **App size**: Each Nerd Font family adds ~2-5MB
2. **Departure Mono works well**: Good baseline for most users
3. **No fallback chain**: Ghostty doesn't support font cascading on iOS yet — a symbols-only Nerd Font as fallback isn't currently possible

### Top Candidates (When Ready)

| Font | License | Notes |
|------|---------|-------|
| JetBrainsMono Nerd Font Mono | OFL | Great ligatures, most popular |
| Hack Nerd Font Mono | MIT | Classic, clean |
| FiraCode Nerd Font Mono | OFL | Popular, excellent ligatures |

### Bundle Strategy Options

1. **Bundle full Nerd Font** — largest app size, best UX
2. **Symbols-only fallback font** — requires font cascade support in Ghostty
3. **User-provided fonts** — via iOS Settings → General → Fonts

---

## Powerline Symbols Reference

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

Users who need these symbols should install a Nerd Font via iOS Settings or wait for bundled Nerd Font support.

---

## Licensing

| Font | License | Attribution Required |
|------|---------|---------------------|
| Departure Mono | OFL 1.1 | In app credits (see LICENSES.md) |

**OFL 1.1 Requirements**: Include copyright notice, include license text, don't sell the font standalone, don't use reserved font names in derivatives.

---

## Resources

- **Departure Mono**: https://departuremono.com/
- **Nerd Fonts**: https://www.nerdfonts.com/
- **Nerd Fonts Cheat Sheet**: https://www.nerdfonts.com/cheat-sheet
- **Nerd Font Downloads**: https://www.nerdfonts.com/font-downloads
