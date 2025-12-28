# Disconnection Handling Analysis

## Executive Summary

This document provides an in-depth analysis of connection state management in Geistty, examining the current implementation against SSH and tmux protocol standards, identifying gaps, and proposing modern approaches for iOS mobile SSH clients.

---

## Part 1: Current Implementation Analysis

### 1.1 How Geistty Currently Detects Disconnection

**Detection Method: EOF on Read**

The ONLY disconnection detection currently implemented is in `SSHConnection.readFromChannel()`:

```swift
// SSHConnection.swift:555-581
private func readFromChannel() {
    // ... read from channel ...
    
    if rc > 0 {
        // Normal data - process it
    } else if rc == 0 || rc == -1 {
        // Check for EOF - remote host closed the connection
        let isEof = libssh2_channel_eof(chan) != 0
        if isEof {
            logger.info("🔌 SSH channel EOF detected - remote host disconnected")
            // Clean up and notify delegate
            self.state = .disconnected
            self.delegate?.connectionDidClose(self, error: SSHError.channelError("Remote host closed connection"))
        }
    }
    // EAGAIN (-37) is normal in non-blocking mode - just continue
}
```

**What This Catches:**
- Server sends SSH_MSG_CHANNEL_CLOSE → EOF detected ✅
- Server sends SSH_MSG_CHANNEL_EOF → EOF detected ✅
- Server crashes and OS sends TCP RST → Eventually EOF ✅
- Graceful tmux `%exit` → Caught by TmuxControlClient ✅

**What This DOESN'T Catch:**
- Network disappears (WiFi off, cellular dead zone) ❌
- TCP connection stalls (half-open connection) ❌
- Router drops connection silently ❌
- Server becomes unresponsive but doesn't close ❌

### 1.2 How Geistty Currently Handles Writes During Disconnection

**Current Write Implementation:**

```swift
// SSHConnection.swift:453-480
public func write(_ data: Data) {
    guard state == .channelOpen, let chan = channel else { return }  // Silent return if not open
    
    sshQueue.async {
        data.withUnsafeBytes { buffer in
            // ...
            while written < total {
                let rc = libssh2_channel_write_ex(...)
                
                if rc < 0 {
                    if rc == -37 { // EAGAIN
                        usleep(1000)
                        continue
                    }
                    break  // Silent break on other errors!
                }
                written += rc
            }
        }
    }
}
```

**Critical Issues:**

1. **Fire-and-Forget**: Write errors are silently ignored
2. **No Return Value**: Caller has no way to know if write succeeded
3. **No Error Callback**: No notification when write fails
4. **TCP Buffering**: Data may "succeed" (goes to TCP buffer) even though network is down

### 1.3 Current Input Queueing Logic

**Where Queueing Happens:**

```swift
// SSHSession.swift:344-370
func write(_ data: Data) {
    // Queue if tmux control mode exists but isn't ready
    if let client = tmuxControlClient, client.isActive {
        client.sendKeys(data) { [weak self] command in
            self?.connection?.write(command)  // Fire-and-forget!
        }
        return
    }
    
    // Queue if in control mode but client not ready
    if tmuxMode == .controlMode {
        pendingInputQueue.append(data)
        updatePendingInputDisplay()
        return
    }
    
    connection?.write(data)  // Fire-and-forget!
}
```

**What Gets Queued:**
- Input before tmux control mode is ready (`client.isActive == false`)
- Input during reconnection (control mode is reset during reconnect)

**What Does NOT Get Queued:**
- Input when connection is "alive" but network is down
- Input when `client.isActive == true` but TCP is actually broken

### 1.4 The Core Problem

**Timeline of WiFi Disconnect:**

```
T+0:    User typing, connection "looks" alive
        - controlModeActive = true
        - tmuxControlClient.isActive = true
        - connection.state = .channelOpen
        
T+1:    WiFi turns off
        - TCP stack still has socket open (doesn't know yet)
        - connection.write() succeeds (data goes to TCP buffer)
        - No error anywhere!
        
T+2:    User types more
        - Still looks alive
        - write() still "succeeds" (TCP buffer isn't full)
        - Data accumulates in TCP send buffer
        
T+10:   TCP finally times out
        - readFromChannel() gets error
        - EOF detected (maybe, depends on how TCP fails)
        - Only NOW does app know connection is dead
        
T+10:   Auto-reconnect kicks in (if credentials stored)
        - Sets controlModeActive = false
        - NOW pendingInputQueue would be used
        - But all that input from T+0 to T+10 is LOST
```

---

## Part 2: Protocol Standards

### 2.1 SSH Protocol (RFC 4253/4254)

**SSH Disconnection Message (RFC 4253 §11.1):**

```
byte      SSH_MSG_DISCONNECT
uint32    reason code
string    description
string    language tag
```

- Either party can send to terminate connection
- Must be sent with old keys/algorithms
- No data should be sent/received after this

**SSH Keepalive (OpenSSH Extension, not in RFC):**

OpenSSH implements keepalive via SSH_MSG_IGNORE or SSH_MSG_GLOBAL_REQUEST:

```
ServerAliveInterval: seconds between keepalive probes
ServerAliveCountMax: number of missed probes before disconnect
```

libssh2 does NOT implement automatic keepalive. We would need to:
1. Send periodic SSH_MSG_IGNORE messages
2. Track response time
3. Declare dead after threshold

**SSH Channel Close (RFC 4254 §5.3):**

```
SSH_MSG_CHANNEL_EOF   - No more data from sender
SSH_MSG_CHANNEL_CLOSE - Channel terminated
```

- EOF doesn't close channel (more data can come other direction)
- CLOSE requires response with CLOSE
- This is what we currently detect

### 2.2 TCP Behavior

**TCP Does NOT Actively Probe:**

TCP is a "lazy" protocol - it only knows the connection is dead when:
1. It tries to send data and gets no ACK
2. It receives a RST packet
3. Keepalive timeout (if enabled, typically 2 hours!)

**TCP Send Buffer:**

When you `write()` to a socket:
1. Data goes to kernel TCP send buffer
2. `write()` returns success immediately
3. Kernel handles retransmissions
4. If no ACK after many retries (minutes!) → error

**iOS TCP Behavior:**

iOS may keep TCP connections in limbo for a long time:
- Designed for battery efficiency
- May not immediately fail on network change
- Can take 30-120 seconds to detect broken connection

### 2.3 tmux Control Mode Protocol

**Relevant Notifications:**

| Message | When Sent |
|---------|-----------|
| `%exit [reason]` | Control client should exit |
| `%pause %pane` | Pane paused (flow control) |
| `%continue %pane` | Pane resumed |

**What tmux Does:**
- tmux handles server-side persistence
- Control mode provides structured output
- Pause mode allows flow control

**What tmux Does NOT Do:**
- No heartbeat/keepalive in protocol
- No "are you still there?" mechanism
- Relies on TCP/SSH for connection health

---

## Part 3: Modern Approaches

### 3.1 Mosh (Mobile Shell) Approach

**State Synchronization Protocol (SSP):**

Mosh doesn't use TCP at all! Uses UDP with:
- Application-level keepalive (every ~3 seconds)
- Full state synchronization (not stream-based)
- Roaming support (IP changes don't break connection)
- Predictive local echo

**Relevant to Geistty:**
- Immediate feedback on connection loss
- Queued input shown differently (predictive echo in gray)
- Clear visual distinction between "sent" and "predicted"

### 3.2 iTerm2 Approach (tmux Integration)

iTerm2 (the tmux control mode reference implementation) handles disconnection by:

1. **Socket Watch:** Monitors socket health via kqueue
2. **tmux Exit Detection:** Parses `%exit` message
3. **State Preservation:** Keeps local terminal state after disconnect
4. **Reconnect:** Re-attaches to same tmux session

**UI Feedback:**
- Shows "(disconnected)" in tab title
- Preserves scrollback
- Allows copy from disconnected pane

### 3.3 SSH Keepalive Implementation

**What OpenSSH Does:**

```
# Client-side (ssh_config)
ServerAliveInterval 60   # Send probe every 60s
ServerAliveCountMax 3    # After 3 missed, disconnect
```

Sends `SSH_MSG_GLOBAL_REQUEST "keepalive@openssh.com"` or SSH_MSG_IGNORE.

**libssh2 Implementation Required:**

```swift
// Pseudo-code for SSH keepalive in Geistty
func startKeepalive(interval: TimeInterval, maxMissed: Int) {
    Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
        sendKeepaliveProbe()
        missedCount += 1
        if missedCount > maxMissed {
            declareConnectionDead()
        }
    }
}

func handleIncomingData() {
    missedCount = 0  // Any incoming data resets the counter
}
```

### 3.4 Network.framework (NWConnection) Approach

Apple's modern networking framework provides:

1. **Path Updates:** Callback when network path changes
2. **Viability:** Connection can report "not viable"
3. **Better Waiting:** Can wait for network without blocking

```swift
// Using NWConnection instead of raw sockets
let connection = NWConnection(host: host, port: port, using: .tcp)

connection.pathUpdateHandler = { path in
    if path.status == .unsatisfied {
        // Network not available
        handleNetworkLoss()
    }
}

connection.viabilityUpdateHandler = { viable in
    if !viable {
        // Connection no longer viable
        handleConnectionStale()
    }
}
```

**Limitation:** libssh2 uses raw sockets. Would need to either:
- Replace libssh2 with SwiftNIO-SSH
- Add NWPathMonitor for network changes (parallel detection)

---

## Part 4: Recommended Architecture for Geistty

### 4.1 Multi-Layer Detection Strategy

```
┌─────────────────────────────────────────────────────────────┐
│                    Detection Layers                          │
├─────────────────────────────────────────────────────────────┤
│ Layer 1: Network Path Monitor                               │
│   - NWPathMonitor watches network status                    │
│   - Immediate notification on WiFi/cellular change          │
│   - Fastest but may false-positive (cellular fallback)      │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: SSH Keepalive                                      │
│   - Send SSH_MSG_IGNORE every N seconds                     │
│   - Track round-trip acknowledgment                         │
│   - Declares dead after M missed probes                     │
├─────────────────────────────────────────────────────────────┤
│ Layer 3: Write Error Detection                              │
│   - Track pending write count                               │
│   - Callback on write failure                               │
│   - Timeout on unacknowledged writes                        │
├─────────────────────────────────────────────────────────────┤
│ Layer 4: EOF Detection (current)                            │
│   - Catches server-initiated disconnect                     │
│   - Catches TCP RST after long timeout                      │
│   - Last resort detection                                   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Connection State Machine

```
                    ┌──────────────┐
                    │ Disconnected │
                    └──────┬───────┘
                           │ connect()
                           ▼
                    ┌──────────────┐
                    │  Connecting  │
                    └──────┬───────┘
                           │ handshake complete
                           ▼
                    ┌──────────────┐
                    │  Connected   │ ◄────────┐
                    │  (healthy)   │          │
                    └──────┬───────┘          │
                           │ network event    │ reconnect
                           │ or missed probe  │ success
                           ▼                  │
                    ┌──────────────┐          │
                    │    Stale     │──────────┤
                    │ (suspected)  │          │
                    └──────┬───────┘          │
                           │ probe timeout    │
                           │ or write fail    │
                           ▼                  │
                    ┌──────────────┐          │
                    │     Dead     │──────────┘
                    │ (confirmed)  │
                    └──────────────┘
```

### 4.3 Input Handling Architecture

```swift
// Proposed data flow
enum InputDestination {
    case send(Data)           // Send immediately
    case queue(Data)          // Queue for later
    case display(Data)        // Show locally (predictive)
    case reject(reason: String) // Don't accept input
}

func routeInput(_ data: Data) -> InputDestination {
    switch connectionHealth {
    case .healthy:
        // Normal path - but track this write
        return .send(data)
        
    case .stale:
        // Network might be down - queue and display locally
        return .queue(data).and(.display(data))
        
    case .dead:
        // Connection is confirmed dead - queue only
        return .queue(data)
        
    case .reconnecting:
        // Reconnect in progress - queue
        return .queue(data)
    }
}
```

### 4.4 Visual Feedback Design

**Your Vision: "Organic blinking, unbecoming of typical terminal behavior"**

Options ranked by "organicness":

1. **Ghostty Preedit (Inverted Text)** ⭐ Currently Attempted
   - Uses `ghostty_surface_preedit()` API
   - Text appears inverted (fg/bg swapped)
   - Designed for IME but works for preview
   - Problem: Only works if TmuxSessionManager can route it

2. **Pulsing Opacity on Queued Line**
   - Render queued text with pulsing opacity (0.5 ↔ 1.0)
   - SwiftUI animation on overlay
   - More visible but requires overlay layer

3. **Cursor Style Change**
   - Change cursor to indicate "queued" mode
   - e.g., hollow block → filled, or color change
   - Requires Ghostty config change

4. **Inline with Different Color**
   - Write queued input to Ghostty with warning color
   - Clear and rewrite when connection resumes
   - Requires tracking what was "queued" vs "sent"

5. **Non-Terminal Overlay**
   - Small pill/badge showing pending count
   - Least organic but most reliable
   - Doesn't interfere with terminal state

---

## Part 5: Implementation Roadmap

### Phase 1: Proper Connection Health Tracking

```swift
// Add to SSHConnection
enum ConnectionHealth {
    case healthy
    case stale(since: Date)
    case dead(reason: String)
}

@Published var health: ConnectionHealth = .healthy

// Add write acknowledgment tracking
func write(_ data: Data, completion: ((Result<Void, Error>) -> Void)? = nil)
```

### Phase 2: SSH Keepalive

```swift
// Add keepalive using SSH_MSG_IGNORE
func sendKeepalive() {
    // libssh2_session_send_ignore()
    // or send any SSH message and track response time
}
```

### Phase 3: Network Path Monitoring

```swift
// Add NWPathMonitor as early warning system
let monitor = NWPathMonitor()
monitor.pathUpdateHandler = { path in
    if path.status == .satisfied {
        // Network available - check SSH health
    } else {
        // Network gone - mark connection stale immediately
    }
}
```

### Phase 4: Pending Input Display

Fix the current preedit approach:
1. Debug why `displayPendingInput` isn't showing
2. Ensure `focusedPaneId` is correct
3. Ensure surface lookup succeeds
4. Add logging to trace the path

Or implement alternative:
- SwiftUI overlay that shows pending input
- Separate from terminal rendering
- More reliable, less "organic"

---

## Part 6: Debugging the Current Implementation

### Why Preedit Might Not Be Showing

Trace through the call chain:

```
1. SSHSession.write() called
   ↓
2. tmuxControlClient.isActive? 
   - If TRUE: sendKeys() → connection.write() (fire-and-forget)
   - If FALSE: queue and updatePendingInputDisplay()
   ↓
3. When WiFi is off and we're typing:
   - Is client.isActive still TRUE?
   - If so, we're NOT queueing - we're fire-and-forgetting!
   ↓
4. The preedit only shows if we're queueing
   - Which only happens if isActive == FALSE
   - Which only happens BEFORE control mode starts
   - Or AFTER we reset it during reconnect
```

**The Bug:** When WiFi drops but we haven't detected it yet:
- `tmuxControlClient.isActive == true` (from before disconnect)
- Input goes through `sendKeys()` → `connection.write()`
- Write "succeeds" (data goes to TCP buffer)
- Nothing gets queued
- No preedit shown

**The Fix Required:**
- Detect stale connection BEFORE write
- Mark connection health immediately on network path change
- Queue input when health != .healthy

---

## Appendix: Key Files

| File | Responsibility |
|------|----------------|
| `SSHConnection.swift` | Low-level libssh2 wrapper, read loop, write |
| `SSHSession.swift` | High-level session, credentials, reconnect logic |
| `TmuxControlClient.swift` | tmux protocol parsing, isActive flag |
| `TmuxSessionManager.swift` | Multi-pane state, surface routing |
| `Ghostty.swift` | Terminal emulation, preedit API |

---

## Appendix: References

- [RFC 4253 - SSH Transport Layer Protocol](https://www.rfc-editor.org/rfc/rfc4253)
- [RFC 4254 - SSH Connection Protocol](https://www.rfc-editor.org/rfc/rfc4254)
- [tmux Control Mode Wiki](https://github.com/tmux/tmux/wiki/Control-Mode)
- [Mosh: Mobile Shell](https://mosh.org/)
- [Apple Network.framework](https://developer.apple.com/documentation/network)
- [libssh2 Documentation](https://www.libssh2.org/)
