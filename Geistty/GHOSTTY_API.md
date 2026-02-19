# Ghostty API Parity

This document tracks the implementation status of Ghostty C APIs in Geistty.

## Legend
- ✅ Implemented and tested
- 🟡 Implemented, needs testing
- ❌ Not applicable for iOS
- ⏳ Future feature

## Core APIs

### Initialization
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_init` | ✅ | `App.initializeRuntime()` |
| `ghostty_info` | 🟡 | `Ghostty.info()` |
| `ghostty_translate` | 🟡 | `Ghostty.translate(_:)` |
| `ghostty_string_free` | 🟡 | `Ghostty.freeString(_:)` |
| `ghostty_benchmark_cli` | ❌ | CLI only |
| `ghostty_cli_try_action` | ❌ | CLI only |

### Config APIs
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_config_new` | ✅ | `Config.init()` |
| `ghostty_config_clone` | 🟡 | `Config.clone(_:)` |
| `ghostty_config_free` | ✅ | `Config.deinit` |
| `ghostty_config_load_cli_args` | 🟡 | `Config.loadCLIArgs(_:)` |
| `ghostty_config_load_default_files` | 🟡 | `Config.loadDefaultFiles(_:)` |
| `ghostty_config_load_recursive_files` | 🟡 | `Config.loadRecursiveFiles(_:)` |
| `ghostty_config_load_file` | 🟡 | `Config.loadFile(_:path:)` |
| `ghostty_config_load_string` | ✅ | `Config.loadString(_:content:)` |
| `ghostty_config_finalize` | ✅ | In `Config.init()` |
| `ghostty_config_get` | 🟡 | `Config.get(_:key:result:)` |
| `ghostty_config_trigger` | 🟡 | `Config.getTrigger(_:action:)` |
| `ghostty_config_diagnostics_count` | 🟡 | `Config.diagnosticsCount(_:)` |
| `ghostty_config_get_diagnostic` | 🟡 | `Config.getDiagnostic(_:index:)` |
| `ghostty_config_open_path` | 🟡 | `Config.openPath()` |

### App APIs
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_app_new` | ✅ | `App.init()` |
| `ghostty_app_free` | ✅ | `App.deinit` |
| `ghostty_app_tick` | ✅ | `App.tick()` |
| `ghostty_app_set_focus` | ✅ | Lifecycle observers |
| `ghostty_app_key` | 🟡 | `App.sendKey(_:)` |
| `ghostty_app_key_is_binding` | 🟡 | `App.keyIsBinding(_:)` |
| `ghostty_app_keyboard_changed` | 🟡 | `App.keyboardChanged()` |
| `ghostty_app_open_config` | 🟡 | `App.openConfig()` |
| `ghostty_app_update_config` | 🟡 | `App.updateConfig(_:)` |
| `ghostty_app_needs_confirm_quit` | 🟡 | `App.needsConfirmQuit()` |
| `ghostty_app_has_global_keybinds` | 🟡 | `App.hasGlobalKeybinds()` |
| `ghostty_app_set_color_scheme` | 🟡 | `App.setColorScheme(_:)` |
| `ghostty_app_userdata` | 🟡 | `App.getUserdata()` |
| `ghostty_set_window_background_blur` | ❌ | Desktop only |

### Surface APIs - Core
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_config_new` | ✅ | `SurfaceConfiguration` |
| `ghostty_surface_new` | ✅ | `SurfaceView.init(_:)` |
| `ghostty_surface_free` | ✅ | `SurfaceView.deinit` |
| `ghostty_surface_app` | 🟡 | `SurfaceView.getApp()` |
| `ghostty_surface_userdata` | ✅ | Used in callbacks |
| `ghostty_surface_inherited_config` | 🟡 | `SurfaceView.getInheritedConfig()` |
| `ghostty_surface_needs_confirm_quit` | 🟡 | `SurfaceView.needsConfirmQuit()` |
| `ghostty_surface_process_exited` | 🟡 | `SurfaceView.processExited()` |

### Surface APIs - Rendering
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_refresh` | 🟡 | `SurfaceView.refresh()` |
| `ghostty_surface_draw` | 🟡 | `SurfaceView.draw()` |
| `ghostty_surface_set_content_scale` | ✅ | In `layoutSubviews()` |
| `ghostty_surface_set_size` | ✅ | In `layoutSubviews()` |
| `ghostty_surface_size` | ✅ | Used for size queries |
| `ghostty_surface_set_focus` | ✅ | In focus handling |
| `ghostty_surface_set_occlusion` | ✅ | Lifecycle handling |
| `ghostty_surface_set_color_scheme` | ✅ | Dark mode handling |
| `ghostty_surface_set_display_id` | 🟡 | `SurfaceView.setDisplayId(_:)` |
| `ghostty_surface_update_config` | ✅ | Font/theme updates |

### Surface APIs - Input
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_key` | ✅ | Hardware keyboard |
| `ghostty_surface_key_is_binding` | 🟡 | `SurfaceView.keyIsBinding(_:)` |
| `ghostty_surface_key_translation_mods` | 🟡 | `SurfaceView.keyTranslationMods()` |
| `ghostty_surface_text` | ✅ | Software keyboard |
| `ghostty_surface_preedit` | 🟡 | `SurfaceView.preedit(_:)` |
| `ghostty_surface_mouse_button` | ✅ | Tap gestures |
| `ghostty_surface_mouse_pos` | ✅ | Hover/pan gestures |
| `ghostty_surface_mouse_scroll` | ✅ | Scroll gestures |
| `ghostty_surface_mouse_captured` | 🟡 | `SurfaceView.isMouseCaptured()` |
| `ghostty_surface_mouse_pressure` | 🟡 | `SurfaceView.mousePressure(stage:pressure:)` |

### Surface APIs - External Backend (iOS)
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_write_output` | ✅ | SSH data input |
| `write_callback` | ✅ | SSH data output |

### Surface APIs - Clipboard
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_has_selection` | ✅ | Selection check |
| `ghostty_surface_read_selection` | ✅ | Copy to clipboard |
| `ghostty_surface_complete_clipboard_request` | ✅ | OSC 52 support |
| `ghostty_surface_read_text` | 🟡 | `SurfaceView.readText(selection:)` |
| `ghostty_surface_free_text` | 🟡 | Used in readText |

### Surface APIs - Actions
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_binding_action` | ✅ | Keyboard shortcuts |
| `ghostty_surface_commands` | 🟡 | `SurfaceView.getCommands()` |
| `ghostty_surface_request_close` | 🟡 | `SurfaceView.requestClose()` |
| `ghostty_surface_ime_point` | 🟡 | `SurfaceView.imePoint()` |

### Surface APIs - tmux (iOS fork)
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_tmux_pane_count` | ✅ | `SurfaceView.tmuxPaneCount()` |
| `ghostty_surface_tmux_pane_ids` | ✅ | `SurfaceView.tmuxPaneIds()` |
| `ghostty_surface_tmux_set_active_pane` | ✅ | `SurfaceView.tmuxSetActivePane(_:)` — swaps renderer + input routing + registers observer |
| `ghostty_surface_tmux_set_active_pane_input_only` | ✅ | `SurfaceView.tmuxSetActivePaneInputOnly(_:)` — input routing only, no renderer swap |
| `ghostty_surface_tmux_reset_active_pane` | ✅ | `SurfaceView.tmuxResetActivePane()` |
| `ghostty_surface_tmux_window_count` | ✅ | `SurfaceView.tmuxWindowCount()` |
| `ghostty_surface_tmux_window_info` | ✅ | `SurfaceView.tmuxWindowInfo(at:)` |
| `ghostty_surface_tmux_window_layout` | ✅ | `SurfaceView.tmuxWindowLayout(at:)` |
| `ghostty_surface_tmux_active_window_id` | ✅ | `SurfaceView.tmuxActiveWindowId()` |
| `ghostty_surface_tmux_window_focused_pane_id` | ✅ | `SurfaceView.tmuxWindowFocusedPaneId(at:)` |

### Surface APIs - Search
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_search_start` | ✅ | Search overlay |
| `ghostty_surface_search_next` | ✅ | Search overlay |
| `ghostty_surface_search_prev` | ✅ | Search overlay |
| `ghostty_surface_search_end` | ✅ | Search overlay |

### Surface APIs - Split Panes (Future)
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_split` | ⏳ | `SurfaceView.split(direction:)` |
| `ghostty_surface_split_equalize` | ⏳ | `SurfaceView.splitEqualize()` |
| `ghostty_surface_split_focus` | ⏳ | `SurfaceView.splitFocus(direction:)` |
| `ghostty_surface_split_resize` | ⏳ | `SurfaceView.splitResize(direction:amount:)` |

### Surface APIs - Quick Look (macOS)
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_quicklook_word` | 🟡 | `SurfaceView.quickLookWord()` |
| `ghostty_surface_quicklook_font` | 🟡 | `SurfaceView.quickLookFont()` |

### Inspector APIs (Debug)
| C API | Status | Swift Wrapper |
|-------|--------|---------------|
| `ghostty_surface_inspector` | 🟡 | `Inspector.init(surface:)` |
| `ghostty_inspector_free` | 🟡 | `Inspector.deinit` |
| `ghostty_inspector_metal_init` | 🟡 | `Inspector.metalInit(device:)` |
| `ghostty_inspector_metal_shutdown` | 🟡 | `Inspector.metalShutdown()` |
| `ghostty_inspector_metal_render` | 🟡 | `Inspector.metalRender(...)` |
| `ghostty_inspector_set_content_scale` | 🟡 | `Inspector.setContentScale(x:y:)` |
| `ghostty_inspector_set_size` | 🟡 | `Inspector.setSize(width:height:)` |
| `ghostty_inspector_set_focus` | 🟡 | `Inspector.setFocus(_:)` |
| `ghostty_inspector_text` | 🟡 | `Inspector.text(_:)` |
| `ghostty_inspector_key` | 🟡 | `Inspector.key(_:)` |
| `ghostty_inspector_mouse_button` | 🟡 | `Inspector.mouseButton(...)` |
| `ghostty_inspector_mouse_pos` | 🟡 | `Inspector.mousePos(x:y:)` |
| `ghostty_inspector_mouse_scroll` | 🟡 | `Inspector.mouseScroll(x:y:)` |

## Action Callbacks (Runtime)

All action callbacks are handled in `App.action(_:target:action:)`:

| Action | Status | Description |
|--------|--------|-------------|
| `GHOSTTY_ACTION_SET_TITLE` | ✅ | Window title change |
| `GHOSTTY_ACTION_RING_BELL` | ✅ | Haptic feedback |
| `GHOSTTY_ACTION_SCROLLBAR` | ✅ | Scroll indicator update |
| `GHOSTTY_ACTION_MOUSE_OVER_LINK` | ✅ | URL hover |
| `GHOSTTY_ACTION_OPEN_URL` | ✅ | Open URL in browser |
| `GHOSTTY_ACTION_PWD` | ✅ | Working directory change |
| `GHOSTTY_ACTION_CELL_SIZE` | ✅ | Grid cell dimensions |
| `GHOSTTY_ACTION_MOUSE_SHAPE` | ✅ | Cursor shape |
| `GHOSTTY_ACTION_MOUSE_VISIBILITY` | ✅ | Cursor visibility |
| `GHOSTTY_ACTION_RENDERER_HEALTH` | ✅ | Renderer status |
| `GHOSTTY_ACTION_COLOR_CHANGE` | ✅ | Palette change |
| `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` | ✅ | Local notification |
| `GHOSTTY_ACTION_START_SEARCH` | ✅ | Begin search mode |
| `GHOSTTY_ACTION_END_SEARCH` | ✅ | End search mode |
| `GHOSTTY_ACTION_SEARCH_TOTAL` | ✅ | Search result count |
| `GHOSTTY_ACTION_SEARCH_SELECTED` | ✅ | Selected result index |
| `GHOSTTY_ACTION_TMUX_STATE_CHANGED` | ✅ | tmux window/pane count changed |
| `GHOSTTY_ACTION_TMUX_EXIT` | ✅ | tmux control mode exited |
| `GHOSTTY_ACTION_TMUX_READY` | ✅ | tmux viewer ready (capture-pane complete) |
| `GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY` | ✅ | Toggle background opacity |

## Helper Types

All Ghostty types have Swift equivalents:

| C Type | Swift Type |
|--------|------------|
| `ghostty_input_mods_e` | `Ghostty.Modifiers` |
| `ghostty_color_scheme_e` | `Ghostty.ColorScheme` |
| `ghostty_action_split_direction_e` | `Ghostty.SplitDirection` |
| `ghostty_action_goto_split_e` | `Ghostty.GotoSplit` |
| `ghostty_action_resize_split_direction_e` | `Ghostty.ResizeSplitDirection` |
| `ghostty_point_s` | `Ghostty.Point` |
| `ghostty_selection_s` | `Ghostty.Selection` |
| `ghostty_command_s` | `Ghostty.GhosttyCommand` |

## Files

- `Ghostty.swift` - SurfaceView: Metal rendering, keyboard input, gestures, write callback, tmux C API wrappers
- `Ghostty.App.swift` - App lifecycle, runtime init, action callback dispatch (handles all actions above)
- `Ghostty.Config.swift` - Config wrapper (create, load, finalize)
- `Ghostty.SearchState.swift` - Search overlay state model
- `Ghostty.SurfaceConfiguration.swift` - Surface init configuration
- `GhosttyInput.swift` - UIKit key event translation to Ghostty input
- `FontMapping.swift` - Font name translation (GUI names <> CoreText names, 9 fonts)
- `ConfigSyncManager.swift` - ghostty.conf <> Ghostty Config synchronization
- `SurfaceSearchOverlay.swift` - Search bar UI overlay
- `TmuxSurfaceProtocol.swift` - Protocol abstraction for tmux C API queries (enables mock testing)
- `CommandPaletteView.swift` - Command palette UI (Cmd+Shift+P) — uses `ghostty_surface_commands` and `ghostty_surface_binding_action`

## Usage Examples

### Get Ghostty Version
```swift
let info = Ghostty.info()
print("Ghostty \(info.version) (\(info.buildMode))")
```

### Check Config Diagnostics
```swift
let diagnostics = Ghostty.Config.getAllDiagnostics(config)
for error in diagnostics {
    print("Config error: \(error)")
}
```

### Get Available Commands
```swift
let commands = surfaceView.getCommands()
for cmd in commands {
    print("\(cmd.title): \(cmd.description)")
}
```

### Check Mouse Capture
```swift
if surfaceView.isMouseCaptured() {
    // Terminal app is handling mouse input
}
```

### IME Support
```swift
// Send preedit text for IME composition
surfaceView.preedit("日本")

// Get IME candidate window position  
let (x, y, w, h) = surfaceView.imePoint()

// Clear preedit when composition is done
surfaceView.clearPreedit()
```

### Split Panes (Future)
```swift
// Split the current pane
surfaceView.split(direction: .right)

// Navigate between splits
surfaceView.splitFocus(direction: .left)

// Resize a split
surfaceView.splitResize(direction: .right, amount: 10)
```
