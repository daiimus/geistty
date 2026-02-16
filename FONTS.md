# Font Strategy

## Overview

Terminal fonts are critical to the user experience. This document covers Geistty's font configuration, bundled fonts, and mapping system.

## Current State (v0.1-stable)

### Bundled Fonts (8 families)

| Font | License | Files | Notes |
|------|---------|-------|-------|
| **Departure Mono** | OFL 1.1 | `DepartureMono-Regular.otf` | Default font. Clean monospace with good glyph coverage. |
| **JetBrains Mono** | OFL 1.1 | `JetBrainsMono-Regular.ttf`, `-Bold.ttf` | Popular developer font, excellent ligatures |
| **Fira Code** | OFL 1.1 | `FiraCode-Regular.ttf`, `-Bold.ttf` | Programming ligatures, wide glyph coverage |
| **Hack** | MIT | `Hack-Regular.ttf`, `-Bold.ttf` | Classic, clean monospace |
| **Source Code Pro** | OFL 1.1 | `SourceCodePro-Regular.otf`, `-Bold.otf` | Adobe's monospace, great readability |
| **IBM Plex Mono** | OFL 1.1 | `IBMPlexMono-Regular.ttf`, `-Bold.ttf` | IBM's monospace, distinctive character |
| **Inconsolata** | OFL 1.1 | `Inconsolata-Regular.ttf`, `-Bold.ttf` | Lightweight, clean |
| **Atkinson Hyperlegible Mono** | OFL 1.1 | `AtkinsonHyperlegibleMono-Regular.ttf`, `-Bold.ttf` | Designed for low vision readers, high character distinction |

### System Fonts (2)

| Font | Notes |
|------|-------|
| **Menlo** | macOS/iOS classic monospace (always available) |
| **Courier New** | Universal fallback |

**Note:** SF Mono is excluded because it's a system UI font that cannot be accessed by name via CoreText -- it requires special system font APIs.

### Font Picker (SettingsView)

The in-app font picker offers all 10 fonts in the order listed above.

Font selection is persisted to `ghostty.conf` via the `font-family` config key.
Live updates use `ghostty_surface_update_config()`.

### Font Mapping

Font name translation between GUI display names and CoreText/Ghostty identifiers is centralized in `Sources/Ghostty/FontMapping.swift`:

```swift
// GUI name -> Ghostty config value (examples)
"Departure Mono" -> "Departure Mono"
"JetBrains Mono" -> "JetBrains Mono"
"Fira Code"      -> "Fira Code"
"Hack"           -> "Hack"
"Source Code Pro" -> "Source Code Pro"
"IBM Plex Mono"  -> "IBM Plex Mono"
"Inconsolata"    -> "Inconsolata"
"Atkinson Hyperlegible Mono" -> "Atkinson Hyperlegible Mono"
"Menlo"          -> "Menlo"
"Courier New"    -> "Courier New"
```

Each font also has `allNames` for reverse mapping from config files (e.g., `"DepartureMono-Regular"` -> `"Departure Mono"`).

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

Users who need Powerline/Nerd Font symbols should install a patched font via iOS Settings or use one of the bundled fonts that includes glyph coverage.

---

## Future Considerations

### User-Provided Fonts

iOS supports installing custom fonts via Settings > General > Fonts. Users could install Nerd Font variants for full icon coverage.

### Font Cascade / Fallback

Ghostty doesn't currently support font cascading on iOS -- a symbols-only Nerd Font as fallback isn't possible yet. If upstream adds font fallback support, we could add a symbols-only font for Powerline glyphs without requiring full Nerd Font variants.

---

## Licensing

| Font | License | Attribution Required |
|------|---------|---------------------|
| Departure Mono | OFL 1.1 | In app credits (see LICENSES.md) |
| JetBrains Mono | OFL 1.1 | In app credits |
| Fira Code | OFL 1.1 | In app credits |
| Hack | MIT | In app credits |
| Source Code Pro | OFL 1.1 | In app credits |
| IBM Plex Mono | OFL 1.1 | In app credits |
| Inconsolata | OFL 1.1 | In app credits |
| Atkinson Hyperlegible Mono | OFL 1.1 | In app credits |

**OFL 1.1 Requirements**: Include copyright notice, include license text, don't sell the font standalone, don't use reserved font names in derivatives.

---

## Resources

- **Departure Mono**: https://departuremono.com/
- **JetBrains Mono**: https://www.jetbrains.com/lp/mono/
- **Fira Code**: https://github.com/tonsky/FiraCode
- **Hack**: https://sourcefoundry.org/hack/
- **Source Code Pro**: https://github.com/adobe-fonts/source-code-pro
- **IBM Plex Mono**: https://github.com/IBM/plex
- **Inconsolata**: https://levien.com/type/myfonts/inconsolata.html
- **Atkinson Hyperlegible Mono**: https://brailleinstitute.org/freefont
- **Nerd Fonts**: https://www.nerdfonts.com/
