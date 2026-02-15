# Disconnection Handling Analysis

> **Status (Dec 2025):** This document is **partially historical**. Geistty migrated from libssh2 to
> SwiftNIO-SSH in Dec 2024, and from TmuxControlClient to actor-based TmuxGateway in Dec 2025.
> 
> **Still Relevant:**
> - Part 4+ architecture recommendations (connection health, command queue pause/resume)
> - The SwiftNIO-SSH + Network.framework path monitoring approach
> - ConnectionHealth enum (`healthy`, `stale`, `dead`) - now implemented
> 
> **Historical (for reference only):**
> - libssh2 code examples in Parts 1-3
> - SSHConnection class (replaced by NIOSSHConnection)
> - TmuxControlClient (replaced by TmuxGateway actor)

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

**Status:** ✅ SwiftNIO-SSH migration complete! Now using `NIOTSEventLoopGroup` which wraps
`NWConnection` and provides native path/viability updates.

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
| `NIOSSHConnection.swift` | SwiftNIO-SSH wrapper, async channel I/O |
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
- [SwiftNIO-SSH](https://github.com/apple/swift-nio-ssh) - Pure Swift SSH implementation
---

## Part 10: File Provider Extension Analysis (Dec 2025)

### 10.1 Problem Statement

The iOS File Provider extension shows "Content Unavailable" when browsing SFTP connections. Debug logs reveal:

1. SSH connection succeeds ✅
2. SFTP subsystem initializes (VERSION exchange works) ✅
3. SFTP OPENDIR request sent ✅
4. Server response (17 bytes) starts arriving ✅
5. **Extension process killed before response processed** ❌

**Critical Log Pattern:**
```
[06:40:43Z] SFTPChannel: SFTP request 1: type=11           ← OPENDIR sent
[06:40:43Z] SFTPChannel: channelRead: received 17 bytes    ← Response arrived!
[06:40:43Z] SFTPChannel: processBuffer: buffer has 17 bytes
[06:40:43Z] Extension init for domain: geistty             ← Process killed/restarted
```

The response physically arrives but the extension is killed before `handleIncomingData` can resume the continuation waiting for it.

### 10.2 Root Cause Analysis

**iOS File Provider Extension Lifecycle:**
- Extensions run in a separate process from the main app
- iOS aggressively manages extension memory and lifetime
- When enumeration "completes" (observer.finishEnumerating), iOS may kill the process
- Network I/O in progress is terminated without cleanup

**Our Architecture Issue:**
- `SFTPConnectionManager` actor holds connection state in memory
- When extension process is killed, all actor state is lost
- SwiftNIO event loop is destroyed mid-operation
- Continuations waiting for responses are never resumed

**Key Insight:** The issue isn't that we're slow - we're actually receiving the response! The process is killed **immediately** after receiving data, before our code can process it.

### 10.3 Reference Implementation: Blink Shell (blinksh/blink)

[Blink Shell](https://github.com/blinksh/blink) is a production iOS SSH terminal app with a **working `NSFileProviderReplicatedExtension` for SFTP** (added ~11 months ago). This is the most relevant reference because it solves the exact same problem we have.

**Key Architecture:**

**1. SQLite Database via [SQLite.swift](https://github.com/stephencelis/SQLite.swift)**
```swift
// WorkingSetDatabase.swift - persisted state survives process restarts
public class WorkingSetDatabase {
    private let db: Connection
    private let stateTable = Table("State")
    
    // Schema
    let itemKey          = Expression<String>("Item")
    let containerKey     = Expression<String>("Container")
    let versionKey       = Expression<Data>("Version")
    let isContainerKey   = Expression<Bool>("isContainer")
    let anchorKey        = Expression<Int>("Anchor")
    let nameKey          = Expression<String>("Name")
    let containerPathKey = Expression<String>("ContainerPath")
}
```

**2. WorkingSet + Polling for Changes**
```swift
// WorkingSet polls for changes every 5 seconds
DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) {
    self.workingSet.resumeChangesTimerEvery(seconds: 5)
}

// Timer triggers prepareChangesAndSignalEnumerator()
func prepareChangesAndSignalEnumerator() {
    prepareChanges { changes in
        if !changes.isEmpty {
            self.anchorIteration += 1
            self.changes = changes
            self.signalEnumerator()  // ← Notifies system
        }
    }
}
```

**3. Network I/O Happens During Enumeration (Critical Difference!)**
Unlike our assumption, Blink **does** do SFTP during enumeration:
```swift
// FileProviderReplicatedEnumerator.swift
public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    enumerateItemsCancellable = self.allItems()  // ← SFTP call here!
        .tryMap { itemsAttributes -> [FileProviderItem] in
            try workingSet.commitItemsInContainer(self.blinkIdentifier, itemsAttributes: itemsAttributes)
        }
        .sink(...)
}

func allItems() -> AnyPublisher<[BlinkFiles.FileAttributes], Error> {
    itemTranslator
        .flatMap { $0.isDirectory ? $0.directoryFilesAndAttributesWithTargetLinks() : ... }
        .eraseToAnyPublisher()
}
```

**4. Combine Publishers (not async/await)**
- Uses Combine `AnyPublisher` throughout
- `AnyCancellable` for lifecycle management
- Avoids Swift concurrency actor isolation issues

**5. BlinkFiles Translator Pattern**
- `Translator` protocol abstracts SFTP/Local filesystem
- `cloneWalkTo(path)` navigates directories
- `stat()`, `directoryFilesAndAttributesWithTargetLinks()` for metadata

**Why Blink Works But We Don't:**

| Aspect | Blink Shell | Geistty |
|--------|-------------|---------|
| SSH Library | libssh2 (C) | SwiftNIO-SSH (Swift) |
| Async Model | Combine Publishers | Swift async/await + Actors |
| Event Loop | libssh2's blocking calls | SwiftNIO EventLoopFuture |
| Process Lifetime | Extension survives long enough | Extension killed mid-NIO-callback |

The key insight: **libssh2 is blocking** - when Blink calls SFTP, it blocks until complete. SwiftNIO is **async** - our code receives data, but the continuation is never resumed because the process is killed before the event loop can schedule it.

### 10.4 Reference Implementation: Cryptomator iOS

[Cryptomator](https://github.com/cryptomator/ios) uses HTTP APIs (not SFTP), but shows good patterns:

**1. GRDB (SQLite) for persistence**
**2. Promise-based async (not async/await)**
**3. Task tracking in database (survives restarts)**
**4. FileProviderAdapter pattern**

### 10.5 Why SFTP Is Harder (Updated)

**Correction:** Blink Shell proves SFTP **can** work in a File Provider extension. The issue is our async model, not the protocol.

**Blink (libssh2) - Blocking I/O:**
```
Thread: enumerateItems() called
Thread: SFTP opendir() - blocks thread until response
Thread: SFTP readdir() - blocks thread until response  
Thread: observer.didEnumerate(items)
Thread: observer.finishEnumerating()
```

**Geistty (SwiftNIO-SSH) - Async I/O:**
```
Thread 1: enumerateItems() called
Thread 1: SFTP opendir() - schedules on EventLoop, returns immediately
Thread 1: Returns from enumerateItems() ← Extension thinks we're done
Thread 2 (EventLoop): Receives OPENDIR response
Thread 2: Process killed before continuation resumed ← CRASH
```

### 10.6 Proposed Solutions (Revised)

**Option A: Use libssh2 Instead of SwiftNIO-SSH**

Pros:
- Proven to work (Blink Shell uses it)
- Blocking I/O keeps thread alive until complete
- No actor/continuation issues

Cons:
- C library, harder to maintain
- Would need to rebuild SSH layer
- Loses SwiftNIO benefits (Network.framework, async/await)

**Option B: Keep SwiftNIO but Move SFTP to Main App (Original Recommendation)**

```
Main App                          File Provider Extension
─────────                         ─────────────────────────
SFTP connection (long-lived)
        │
        ▼
Sync to SwiftData cache
        │
        ▼
                                  enumerateItems() called
                                          │
                                          ▼
                                  Read from SwiftData (no network)
                                          │
                                          ▼
                                  Return cached items immediately
```

**Option C: Block the Thread During SFTP Operations**

Use `DispatchSemaphore` or `RunLoop` to block enumeration until SFTP completes:

```swift
public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    let semaphore = DispatchSemaphore(value: 0)
    var result: [FileProviderItem]?
    var error: Error?
    
    Task {
        do {
            result = try await sftpClient.listDirectory(path)
        } catch {
            error = err
        }
        semaphore.signal()
    }
    
    // Block until SFTP completes (like libssh2 does)
    semaphore.wait()
    
    if let items = result {
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    } else {
        observer.finishEnumeratingWithError(error ?? ...)
    }
}
```

**Option D: Use Combine Publishers Like Blink**

Replace Swift async/await with Combine:

```swift
// Current (async/await - broken)
func listDirectory(_ path: String) async throws -> [FileAttributes]

// Blink-style (Combine - works)
func listDirectory(_ path: String) -> AnyPublisher<[FileAttributes], Error>
```

### 10.7 Recommended Path Forward

**Immediate Fix (Option C):** Add thread-blocking wrapper around SwiftNIO async calls. This mirrors how libssh2 behaves and should keep the extension alive.

**Long-term (Option D):** Refactor SFTP layer to use Combine publishers, matching Blink's proven architecture.

**Alternative (Option B):** If blocking doesn't work due to NIO EventLoop constraints, move SFTP entirely to main app.

### 10.8 Blink Shell Architecture Details

**Database Location:**
```swift
// BlinkPaths.m
+ (NSURL *)fileProviderReplicatedURL {
    NSString *fileProviderPath = [[self groupContainerPath] 
        stringByAppendingPathComponent:@"FileProviderReplicated"];
    return [NSURL fileURLWithPath:fileProviderPath];
}
// Database: <AppGroup>/FileProviderReplicated/<reference>.db
```

**WorkingSet Lifecycle:**
```swift
// FileProviderReplicatedExtension.swift
public required init(domain: NSFileProviderDomain) {
    // 1. Create database path from domain
    let dbPath = fileProviderURL.appendingPathComponent("\(domainReference).db")
    
    // 2. Initialize WorkingSet with database
    let db = try WorkingSetDatabase(path: dbPath.path(), reset: false)
    self.workingSet = try WorkingSet(domain: domain, db: db, logger: logger)
    
    // 3. Start polling timer after 5 seconds
    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) {
        self.workingSet.resumeChangesTimerEvery(seconds: 5)
    }
}
```

**Enumeration Flow:**
```
1. enumerateItems() called by system
2. FileProviderReplicatedEnumerator.allItems() → itemTranslator (SFTP call)
3. SFTP directoryFilesAndAttributes() via Combine publisher
4. Results stored: workingSet.commitItemsInContainer()
5. observer.didEnumerate(items)
6. observer.finishEnumerating()
7. Enumerator added to WorkingSet's active enumerators
8. Timer polls every 5s: prepareChangesAndSignalEnumerator()
9. Changes detected → fpm.signalEnumerator()
```

**Key Files to Study:**
- `BlinkFileProvider/FileProviderReplicatedExtension.swift` - Main extension
- `BlinkFileProvider/FileProviderReplicatedEnumerator.swift` - Enumeration + WorkingSet
- `BlinkFileProvider/WorkingSetDatabase.swift` - SQLite persistence
- `BlinkFileProvider/FilesTranslatorConnection.swift` - SFTP connection wrapper
- `BlinkFiles/` - SFTP protocol implementation (Translator pattern)

### 10.9 Implementation Checklist (Revised)

Based on Blink Shell's architecture:

- [ ] **Switch from SwiftData to SQLite.swift** - More control, proven in File Provider
- [ ] **Add thread-blocking wrapper** - Keep extension alive during SFTP
- [ ] **Implement WorkingSet pattern** - Track active enumerators, poll for changes
- [ ] **Use Combine instead of async/await** - Match Blink's proven async model
- [ ] **Add polling timer** - Detect remote changes every N seconds
- [ ] **Implement signalEnumerator()** - Notify system of changes

### 10.10 Lessons Learned (Updated)

1. **Blink Shell proves SFTP File Provider works** - The protocol isn't the problem
2. **SwiftNIO async + File Provider = Trouble** - Extension killed before event loop completes
3. **Blocking I/O survives extension lifecycle** - libssh2's blocking model works
4. **SQLite.swift > SwiftData for File Provider** - More predictable, no actor isolation
5. **Combine > async/await** - Publishers have clearer cancellation/lifecycle
6. **Study working implementations** - Blink Shell is the gold standard reference