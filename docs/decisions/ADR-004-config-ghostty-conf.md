# ADR-004: Config — ghostty.conf as Source of Truth, Not UserDefaults

**Status:** Accepted  
**Date:** 2026-02-19  
**Context:** Sessions 33-35 (config system implementation)

## Problem

iOS apps conventionally use `UserDefaults` for preferences. Ghostty uses a plain text config file (`ghostty.conf`). We need to decide which is the source of truth for terminal configuration (theme, font, cursor style, keybindings, etc.).

## Decision

**`ghostty.conf` is the source of truth for all Ghostty-related configuration.**

The config file lives at the app's documents directory and uses the same format as desktop Ghostty. This means:
- Users who know Ghostty can edit the file directly
- Config options map 1:1 to upstream Ghostty documentation
- No translation layer between "our settings" and "Ghostty settings"

### How it works

1. **Config loading**: `Ghostty.Config` reads `ghostty.conf` via `ghostty_config_load_file()`, then finalizes
2. **In-app changes**: When the user changes a setting (theme, font, etc.) via UI, we:
   - Update `ghostty.conf` on disk
   - Create a new `Ghostty.Config` from the updated file
   - Call `ghostty_surface_update_config()` for live update
3. **Config sync**: `ConfigSyncManager` handles the bidirectional flow:
   - File → Ghostty (on load, on Cmd+Shift+, reload)
   - UI → File → Ghostty (on setting change)
4. **Config introspection**: `ghostty_config_get()` reads values back from the finalized config for UI display

### What uses UserDefaults

Only iOS-specific settings that have no Ghostty equivalent:
- Saved connection profiles (host, port, username, auth method)
- Connection favorites and ordering
- App-level preferences (not terminal configuration)

### What uses ghostty.conf

All terminal configuration:
- `font-family`, `font-size`
- `theme`
- `cursor-style`, `cursor-style-blink`
- `scrollback-limit`
- `window-padding-*`
- Keybindings
- Any other Ghostty config option

## Consequences

- Power users can edit `ghostty.conf` directly (via Files.app or the in-app editor)
- Config is portable — copy your desktop `ghostty.conf` to your iPad
- We automatically support new Ghostty config options on rebase without code changes
- No impedance mismatch between "what the UI shows" and "what Ghostty uses"
- Trade-off: slightly more complex than `UserDefaults` for simple settings, but the 1:1 mapping with upstream is worth it

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|-------------|
| UserDefaults for everything | Translation layer between UserDefaults keys and Ghostty config; wouldn't support new options without code changes |
| UserDefaults + sync to ghostty.conf | Two sources of truth, sync bugs inevitable |
| In-memory only (no persistence) | Terrible UX — settings reset on every launch |
| JSON/plist config | Non-standard for Ghostty ecosystem, no portability |
