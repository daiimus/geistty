# QA Checklist — Geistty

Manual test matrix for device testing. Run through before each release.

**Test Device:** ICarus (iPad Pro) — `<YOUR-DEVICE-UDID>`
**Connectivity:** USB, LAN, or Tailscale to Mac test server (localhost)

---

## Pre-Test Setup

- [ ] Build & install: `./ci.sh device-build && ./ci.sh install`
- [ ] Verify Mac SSH is enabled: System Settings > General > Sharing > Remote Login
- [ ] Verify tmux is installed on test server: `which tmux`
- [ ] Kill any leftover tmux sessions: `tmux kill-server`

---

## 1. Connection

### Password Auth
- [ ] Quick Connect with password — connects successfully
- [ ] Wrong password — shows error, does not crash
- [ ] Empty password field — handled gracefully
- [ ] Non-default port (e.g., 2222) — connects if server listening

### Key Auth
- [ ] Connect with Ed25519 key — connects successfully
- [ ] Connect with RSA key — connects successfully
- [ ] Key with passphrase — prompts for passphrase (or fails gracefully)
- [ ] Invalid/wrong key — shows error

### Saved Profiles
- [ ] Create new profile — saved and appears in list
- [ ] Edit existing profile — changes persist
- [ ] Delete profile — removed from list
- [ ] Connect via saved profile — connects successfully
- [ ] Duplicate profile (context menu) — creates copy
- [ ] Profile with tmux auto-attach — enters tmux on connect

### Quick Connect
- [ ] Quick Connect button — opens connection sheet
- [ ] Fill host/user/pass — connects
- [ ] Cmd+O shortcut — opens Quick Connect

### Disconnect & Reconnect
- [ ] Cmd+W — disconnects, returns to connection list
- [ ] Server-side kill (`kill -9` sshd child) — shows disconnected overlay
- [ ] Cmd+R — reconnects to same session
- [ ] Auto-reconnect on app resume after background — reconnects
- [ ] Reconnect button in disconnected overlay — works

### Connectivity Methods (ICarus)
- [ ] USB connection to Mac — connects via `localhost`
- [ ] LAN connection — connects via Mac's LAN IP
- [ ] Tailscale connection — connects via Tailscale IP

---

## 2. Terminal Rendering

### Basic Display
- [ ] Shell prompt renders correctly
- [ ] Command output displays properly
- [ ] Colors render (run `ls --color` or a color test script)
- [ ] Cursor visible and blinking (if configured)
- [ ] Long lines wrap correctly
- [ ] Unicode characters display (emoji, CJK, box drawing)

### Scrollback
- [ ] Touch scroll up — reveals scrollback history
- [ ] Touch scroll down — returns to bottom
- [ ] Momentum scrolling — smooth deceleration
- [ ] Scroll position indicator — visible during scroll
- [ ] Trackpad/mouse wheel scroll — works

### Programs
- [ ] `vim` — opens, renders, navigates, exits cleanly
- [ ] `htop` — renders, updates, exits
- [ ] `less` — pages, scrolls, quits
- [ ] `man ls` — displays, scrolls
- [ ] `nano` — opens, edits, saves
- [ ] `tmux` (standalone, not control mode) — splits render

### Search
- [ ] Cmd+F — opens search bar
- [ ] Type query — highlights matches, shows count
- [ ] Next/Previous — navigates between matches
- [ ] Dismiss search bar — search clears
- [ ] Search in tmux mode — uses Ghostty's built-in search (note: `captureTmuxPane()` for tmux-specific search is stubbed/non-functional)
- [ ] Alternate screen indicator — shows when in vim/tmux

---

## 3. Input

### Hardware Keyboard
- [ ] Letter keys — type correctly
- [ ] Number keys — type correctly
- [ ] Special characters (`!@#$%^&*`) — type correctly
- [ ] Arrow keys — navigate in shell/vim
- [ ] Ctrl+C — interrupts running process
- [ ] Ctrl+D — EOF / exit
- [ ] Ctrl+Z — suspend process
- [ ] Ctrl+L — clear screen
- [ ] Tab — autocomplete
- [ ] Escape — works in vim, cancels in shell
- [ ] Home/End — beginning/end of line
- [ ] Page Up/Page Down — scroll
- [ ] F1-F12 — function keys work
- [ ] Alt/Option as meta — works for vim/emacs bindings (`macos-option-as-alt`)
- [ ] Key repeat — holding a key repeats

### On-Screen Keyboard
- [ ] Keyboard appears on tap
- [ ] Keys type correctly
- [ ] Accessory bar: Esc — sends escape
- [ ] Accessory bar: Ctrl toggle — activates/deactivates (orange highlight)
- [ ] Accessory bar: Arrow keys — send arrows
- [ ] Accessory bar: Tab — sends tab
- [ ] Accessory bar: Pipe `|` and Tilde `~` — type correctly
- [ ] Dismiss keyboard button — hides keyboard

### Keyboard Shortcuts
- [ ] Cmd+C — copy selection (or interrupt if no selection)
- [ ] Cmd+V — paste
- [ ] Cmd+A — select all
- [ ] Cmd+K — clear screen
- [ ] Cmd+0 — reset font size
- [ ] Cmd++ — increase font size
- [ ] Cmd+- — decrease font size

### Selection & Clipboard
- [ ] Long press + drag — selects text
- [ ] Mouse/trackpad click-drag — selects text (instant)
- [ ] Double-tap — selects word
- [ ] Triple-tap — selects line
- [ ] Copy selected text — clipboard contains selection
- [ ] Paste — inserts clipboard content
- [ ] Bracketed paste in vim — pastes correctly

### Gestures
- [ ] Pinch to zoom — changes font size
- [ ] Two-finger double-tap — resets font size

---

## 4. tmux Control Mode

### Splits
- [ ] Cmd+D — horizontal split (pane appears to right)
- [ ] Cmd+Shift+D — vertical split (pane appears below)
- [ ] Each pane has independent terminal output
- [ ] Each pane accepts independent input

### Focus & Navigation
- [ ] Tap on pane — focuses it (border highlight changes)
- [ ] Cmd+] — next pane
- [ ] Cmd+[ — previous pane
- [ ] Cmd+Option+Arrow — navigate in direction
- [ ] Focus indicator — visible border on active pane
- [ ] Typing in a pane — updates focus to that pane

### Split Management
- [ ] Cmd+Shift+Enter — zoom/unzoom pane
- [ ] Cmd+Ctrl+= — equalize pane sizes
- [ ] Cmd+W — close current pane
- [ ] Close last pane — returns to single-pane mode
- [ ] Close one of two panes — remaining pane fills space

### Windows
- [ ] Cmd+T — new tmux window
- [ ] Cmd+1-9 — switch to window by number
- [ ] Cmd+Shift+] — next window
- [ ] Cmd+Shift+[ — previous window
- [ ] Window tab bar — shows all windows
- [ ] Swipe to close window tab — closes window
- [ ] Cmd+Shift+R — rename window

### Quad Split (Stress Test)
- [ ] Create 4 panes (2x2 grid) — all render correctly
- [ ] Type in each pane — independent input
- [ ] Navigate between all 4 — focus moves correctly
- [ ] Close panes one by one — layout adjusts

### Reconnection
- [ ] Disconnect during tmux session — shows overlay on each pane
- [ ] Reconnect — reattaches to tmux session
- [ ] Pane content restored — scrollback intact
- [ ] All panes reconnect — not just active one

---

## 5. Configuration

### Fonts (7 bundled + 2 system)
- [ ] Departure Mono — renders correctly (bundled)
- [ ] JetBrains Mono — renders correctly (bundled)
- [ ] Fira Code — renders correctly (bundled)
- [ ] Hack — renders correctly (bundled)
- [ ] Source Code Pro — renders correctly (bundled)
- [ ] IBM Plex Mono — renders correctly (bundled)
- [ ] Inconsolata — renders correctly (bundled)
- [ ] Menlo — renders correctly (system)
- [ ] Courier New — renders correctly (system)
- [ ] Font change applies live — no restart needed
- [ ] Font persists across app restart

### Font Size
- [ ] Slider changes size (8-32pt range)
- [ ] Size applies live
- [ ] Reset to default button works
- [ ] Size persists across app restart

### Themes
- [ ] Browse theme picker — previews show
- [ ] Select theme — applies immediately
- [ ] Theme persists across app restart
- [ ] Dark themes — background/foreground correct
- [ ] Light themes — background/foreground correct

### Config File
- [ ] In-app config editor — opens `ghostty.conf`
- [ ] Edit and save — changes apply
- [ ] Cmd+Shift+, — reload config from file
- [ ] Invalid config — handled gracefully (no crash)

### Settings Persistence
- [ ] Font choice survives app restart
- [ ] Theme survives app restart
- [ ] Font size survives app restart
- [ ] Connection profiles survive app restart

---

## 6. SSH Key Management

- [ ] Generate Ed25519 key — appears in key list
- [ ] Generate RSA key (2048-bit) — appears in key list
- [ ] View public key — displays correctly
- [ ] Copy public key — clipboard has key
- [ ] Delete key — removed from list
- [ ] Import key from Files — imports successfully
- [ ] Use generated key to connect — authenticates

---

## 7. Device-Specific

### Orientation
- [ ] Portrait — terminal fills screen
- [ ] Landscape — terminal fills screen
- [ ] Rotate during session — terminal resizes correctly
- [ ] Rotate with tmux splits — all panes resize

### Stage Manager
- [ ] Resize window — terminal resizes
- [ ] Multiple windows — each independent
- [ ] Window in background — session stays alive

### App Lifecycle
- [ ] Background app (home button) — session preserved
- [ ] Return from background — auto-reconnects if needed
- [ ] Force quit and relaunch — reconnects to saved profile
- [ ] Lock/unlock device — session resumes
- [ ] Long background (>5 min) — reconnects on return

### Keyboard Show/Hide
- [ ] Show keyboard — terminal resizes with animation
- [ ] Hide keyboard — terminal expands back
- [ ] Hardware keyboard attached — on-screen keyboard optional

### Menu Bar (iPadOS)
- [ ] File menu visible
- [ ] Edit menu — Copy/Paste/Select All
- [ ] View menu — font size controls
- [ ] Terminal menu — Clear Screen
- [ ] Keyboard shortcuts shown in menu items

---

## 8. Edge Cases & Error Handling

- [ ] Connect to non-existent host — shows error, no crash
- [ ] Connect to wrong port — shows error
- [ ] Connection timeout — shows error after timeout
- [ ] Server closes connection mid-session — disconnected overlay
- [ ] Paste very large text (>10KB) — handles without crash/hang
- [ ] Rapid typing — no dropped keys
- [ ] Rapid split/close — no crash
- [ ] Network change (WiFi to cellular) — handles gracefully

---

## Test Results

| Date | Tester | Build | Pass/Fail | Notes |
|------|--------|-------|-----------|-------|
|      |        |       |           |       |

---

## Notes

- UI tests (`./ci.sh ui-test`) cover some connection flows automatically
- Unit tests (`./ci.sh test`) cover parsers, fonts, and data models
- This checklist covers what automated tests cannot: visual rendering, gestures, device behavior
- File Provider is archived — skip SFTP/Files.app testing
