#!/bin/bash
#
# ci.sh - Continuous Integration script for Geistty
#
# This script builds and validates the project without requiring a device.
# Useful for automated testing and agent-driven development.
#
# Usage:
#   ./ci.sh build              - Build for simulator
#   ./ci.sh test               - Run unit tests on simulator  
#   ./ci.sh ui-test            - Run UI tests on iPhone simulator
#   ./ci.sh ui-test-ipad       - Run UI tests on iPad Pro simulator
#   ./ci.sh visual-test        - Run visual regression tests (screenshot comparison)
#   ./ci.sh update-snapshots   - Record new reference screenshots
#   ./ci.sh screenshots        - Extract screenshots from the latest xcresult bundle
#   ./ci.sh lint               - Check for Swift warnings/errors
#   ./ci.sh sync-ghostty       - Rebuild and sync GhosttyKit from ghostty fork
#   ./ci.sh local-validate     - Full pipeline: rebuild GhosttyKit + build + test
#   ./ci.sh all                - Run all checks (build + test + lint)
#   ./ci.sh device-build       - Build for device (uses CI keychain for signing)
#   ./ci.sh install DEVICE     - Install and run on device
#   ./ci.sh deploy [DEVICE]    - Build, install, and launch with console output
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="Geistty.xcodeproj"
SCHEME="Geistty"
SIMULATOR="platform=iOS Simulator,name=iPhone 17 Pro"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/Geistty-ci"
CI_KEYCHAIN="$HOME/Library/Keychains/ci.keychain-db"
CI_KEYCHAIN_PASSWORD_FILE="$HOME/.config/geistty/ci-keychain-password"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Unlock the CI keychain for code signing (device builds only).
# Uses a dedicated keychain with only the signing cert — the login
# keychain (with personal passwords) is never touched.
unlock_ci_keychain() {
    if [ ! -f "$CI_KEYCHAIN" ]; then
        log_error "CI keychain not found at $CI_KEYCHAIN"
        log_info "See AGENTS.md for CI keychain setup instructions"
        return 1
    fi

    if [ ! -f "$CI_KEYCHAIN_PASSWORD_FILE" ]; then
        log_error "CI keychain password file not found at $CI_KEYCHAIN_PASSWORD_FILE"
        return 1
    fi

    local PASSWORD
    PASSWORD=$(head -1 "$CI_KEYCHAIN_PASSWORD_FILE")

    security unlock-keychain -p "$PASSWORD" "$CI_KEYCHAIN" 2>/dev/null
    if [ $? -eq 0 ]; then
        log_info "CI keychain unlocked"
    else
        log_error "Failed to unlock CI keychain"
        return 1
    fi

    # Ensure CI keychain is FIRST in the search list so codesign
    # finds our unlocked cert before the (potentially locked) login keychain
    local CURRENT_KEYCHAINS
    CURRENT_KEYCHAINS=$(security list-keychains -d user | tr -d '"' | tr -d ' ')
    security list-keychains -d user -s \
        "$CI_KEYCHAIN" \
        ~/Library/Keychains/login.keychain-db \
        /Library/Keychains/System.keychain
    log_info "CI keychain set as primary in search list"
}

# Resolve packages first (one time)
resolve_packages() {
    log_info "Resolving Swift packages..."
    xcodebuild -resolvePackageDependencies -project "$PROJECT" 2>&1 | head -20
}

# Build for simulator (no code signing required)
build_simulator() {
    log_info "Building for iOS Simulator..."
    
    xcodebuild build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$SIMULATOR" \
        -derivedDataPath "$DERIVED_DATA" \
        -configuration Debug \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | tee /tmp/geistty_build.log | tail -30
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_info "✅ Build succeeded"
        return 0
    else
        log_error "❌ Build failed"
        echo "Full log: /tmp/geistty_build.log"
        return 1
    fi
}

# Build for device
build_device() {
    unlock_ci_keychain || return 1

    log_info "Building for iOS Device..."
    
    local DEVICE_NAME="${1:-iPad}"
    
    # If a CoreDevice UUID was passed, resolve it to a device name
    if [[ "$DEVICE_NAME" =~ ^[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}$ ]]; then
        local RESOLVED
        RESOLVED=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_NAME" | awk '{print $1}')
        if [ -n "$RESOLVED" ]; then
            DEVICE_NAME="$RESOLVED"
        fi
    fi
    
    log_info "Building for device: $DEVICE_NAME"
    
    xcodebuild build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "platform=iOS,name=$DEVICE_NAME" \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        2>&1 | tee /tmp/geistty_device_build.log | tail -30
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_info "✅ Device build succeeded"
        return 0
    else
        log_error "❌ Device build failed"
        return 1
    fi
}

# Install on device
install_device() {
    unlock_ci_keychain || return 1

    local DEVICE_NAME="${1:-iPad}"
    local DEVICE_UUID
    DEVICE_UUID=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_NAME" | awk '{print $3}')

    if [ -z "$DEVICE_UUID" ]; then
        log_error "No device found matching '$DEVICE_NAME'"
        return 1
    fi
    
    # Find the built app in the CI derived data directory
    APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/Geistty.app"
    
    if [ ! -d "$APP_PATH" ]; then
        log_error "No built app found at $APP_PATH. Run 'device-build' first."
        return 1
    fi
    
    log_info "Installing $APP_PATH on $DEVICE_NAME ($DEVICE_UUID)..."
    xcrun devicectl device install app --device "$DEVICE_UUID" "$APP_PATH" 2>&1
    
    log_info "Launching app..."
    xcrun devicectl device process launch --device "$DEVICE_UUID" com.geistty.app 2>&1
}

# Build, install, and launch with console output (full deploy workflow)
deploy_device() {
    local DEVICE_NAME="${1:-iPad}"
    local DEVICE_UUID
    DEVICE_UUID=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_NAME" | awk '{print $3}')

    if [ -z "$DEVICE_UUID" ]; then
        log_error "No device found matching '$DEVICE_NAME'"
        return 1
    fi

    # Build
    resolve_packages
    build_device "$DEVICE_NAME" || return 1

    # Find the built app in the CI derived data directory
    APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/Geistty.app"

    if [ ! -d "$APP_PATH" ]; then
        log_error "No built app found at $APP_PATH after successful build"
        return 1
    fi

    # Install
    log_info "Installing on $DEVICE_NAME ($DEVICE_UUID)..."
    xcrun devicectl device install app --device "$DEVICE_UUID" "$APP_PATH" 2>&1

    # Launch with console
    log_info "Launching with console output (Ctrl+C to detach)..."
    xcrun devicectl device process launch --device "$DEVICE_UUID" --console com.geistty.app 2>&1
}

# Run unit tests (if test target exists)
run_tests() {
    log_info "Running unit tests..."
    
    # Remove old test results
    rm -rf "$SCRIPT_DIR/test_results/unit_tests.xcresult" 2>/dev/null || true
    mkdir -p "$SCRIPT_DIR/test_results"
    
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$SIMULATOR" \
        -only-testing:GeisttyTests \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$SCRIPT_DIR/test_results/unit_tests.xcresult" \
        2>&1 | tee /tmp/geistty_tests.log | tail -60
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_info "✅ Tests passed"
    else
        log_error "❌ Tests failed"
        log_info "Full log: /tmp/geistty_tests.log"
        return 1
    fi
}

# Run UI tests
run_ui_tests() {
    local DEST="${1:-$SIMULATOR}"
    local RESULT_NAME="${2:-ui_tests}"
    log_info "Running UI tests on: $DEST"
    
    # Remove stale result bundle (xcodebuild won't overwrite)
    rm -rf "$SCRIPT_DIR/test_results/${RESULT_NAME}.xcresult" 2>/dev/null || true
    
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DEST" \
        -only-testing:GeisttyUITests \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$SCRIPT_DIR/test_results/${RESULT_NAME}.xcresult" \
        -parallel-testing-enabled NO \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | tee /tmp/geistty_ui_tests.log | tail -50
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_info "✅ UI Tests passed"
    else
        log_error "❌ UI Tests failed"
        return 1
    fi
}

# Run UI tests on iPad simulator
run_ui_tests_ipad() {
    local IPAD_SIMULATOR="platform=iOS Simulator,name=iPad Pro 13-inch (M5)"
    log_info "Running UI tests on iPad Pro 13-inch (M5)..."
    run_ui_tests "$IPAD_SIMULATOR" "ui_tests_ipad"
}

# Run visual regression tests (screenshot comparison mode)
run_visual_tests() {
    local DEST="${1:-$SIMULATOR}"
    local RESULT_NAME="${2:-visual_tests}"
    log_info "Running visual regression tests on: $DEST"
    
    # Remove stale result bundle
    rm -rf "$SCRIPT_DIR/test_results/${RESULT_NAME}.xcresult" 2>/dev/null || true
    
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DEST" \
        -only-testing:GeisttyUITests \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$SCRIPT_DIR/test_results/${RESULT_NAME}.xcresult" \
        -parallel-testing-enabled NO \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | tee /tmp/geistty_visual_tests.log | tail -50
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_info "✅ Visual tests passed"
        extract_screenshots "$SCRIPT_DIR/test_results/${RESULT_NAME}.xcresult"
    else
        log_error "❌ Visual tests failed"
        extract_screenshots "$SCRIPT_DIR/test_results/${RESULT_NAME}.xcresult"
        return 1
    fi
}

# Update reference screenshots (record mode)
update_snapshots() {
    local DEST="${1:-$SIMULATOR}"
    log_info "Recording reference screenshots on: $DEST"
    
    rm -rf "$SCRIPT_DIR/test_results/snapshot_record.xcresult" 2>/dev/null || true
    
    RECORD_SNAPSHOTS=1 xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DEST" \
        -only-testing:GeisttyUITests \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$SCRIPT_DIR/test_results/snapshot_record.xcresult" \
        -parallel-testing-enabled NO \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | tee /tmp/geistty_snapshot_record.log | tail -50
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_info "✅ Reference screenshots updated"
    else
        log_error "❌ Snapshot recording failed"
        return 1
    fi
}

# Lint/analyze
lint() {
    log_info "Analyzing code..."
    
    xcodebuild analyze \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$SIMULATOR" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | grep -E "(warning:|error:|note:)" | head -50
    
    # Count warnings
    WARNINGS=$(xcodebuild analyze \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$SIMULATOR" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | grep -c "warning:" || true)
    
    log_info "Found $WARNINGS warnings"
}

# Quick syntax check (faster than full build)
syntax_check() {
    log_info "Checking Swift syntax..."
    
    # Find all Swift files
    find Sources -name "*.swift" | while read file; do
        swiftc -parse "$file" 2>&1 || echo "Syntax error in: $file"
    done
}

# Ensure TestConfig.local.swift exists (required by project.pbxproj).
# If missing, copies from the example template so fresh clones can build.
ensure_test_config() {
    local CONFIG_DIR="$SCRIPT_DIR/GeisttyUITests"
    local LOCAL_CONFIG="$CONFIG_DIR/TestConfig.local.swift"
    local EXAMPLE_CONFIG="$CONFIG_DIR/TestConfig.example.swift"

    if [ -f "$LOCAL_CONFIG" ]; then
        log_info "TestConfig.local.swift already exists"
        return 0
    fi

    if [ ! -f "$EXAMPLE_CONFIG" ]; then
        log_error "TestConfig.example.swift not found at $EXAMPLE_CONFIG"
        return 1
    fi

    log_warn "TestConfig.local.swift missing — creating from TestConfig.example.swift"
    log_warn "UI tests will skip (isConfigured = false). Edit TestConfig.local.swift to enable them."
    cp "$EXAMPLE_CONFIG" "$LOCAL_CONFIG"
    log_info "Created $LOCAL_CONFIG"
}

# Sync GhosttyKit xcframework from ghostty fork
sync_ghostty() {
    local GHOSTTY_DIR="$SCRIPT_DIR/../../ghostty"

    if [ ! -d "$GHOSTTY_DIR" ]; then
        log_error "Ghostty repo not found at $GHOSTTY_DIR"
        return 1
    fi

    log_info "Building GhosttyKit xcframework..."
    (cd "$GHOSTTY_DIR" && zig build -Demit-xcframework=true -Dxcframework-target=universal 2>&1) | tail -20

    if [ ! -d "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" ]; then
        log_error "xcframework not found after build"
        return 1
    fi

    log_info "Copying xcframework to Geistty..."
    rm -rf "$SCRIPT_DIR/Frameworks/GhosttyKit.xcframework"
    cp -R "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" "$SCRIPT_DIR/Frameworks/"

    # Remove the macOS slice — Geistty is iOS-only.
    log_info "Removing macOS slice (iOS-only app)..."
    rm -rf "$SCRIPT_DIR/Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64"
    # Update Info.plist to remove the macOS library entry
    python3 -c "
import plistlib, pathlib
p = pathlib.Path('$SCRIPT_DIR/Frameworks/GhosttyKit.xcframework/Info.plist')
d = plistlib.loads(p.read_bytes())
d['AvailableLibraries'] = [l for l in d['AvailableLibraries'] if 'macos' not in l.get('LibraryIdentifier', '')]
p.write_bytes(plistlib.dumps(d))
"

    # Strip debug symbols to reduce binary size.
    # Developers who need symbols can rebuild locally without -S.
    log_info "Stripping debug symbols from .a files..."
    find "$SCRIPT_DIR/Frameworks/GhosttyKit.xcframework" -name '*.a' -exec strip -S {} \;

    log_info "Renaming module maps (module.modulemap -> GhosttyKit.modulemap)..."
    for dir in "$SCRIPT_DIR/Frameworks/GhosttyKit.xcframework"/*/Headers/; do
        if [ -f "${dir}module.modulemap" ]; then
            mv "${dir}module.modulemap" "${dir}GhosttyKit.modulemap"
        fi
    done

    # Report final sizes
    log_info "Final xcframework sizes:"
    find "$SCRIPT_DIR/Frameworks/GhosttyKit.xcframework" -name '*.a' -exec ls -lh {} \;

    log_info "Verifying build with new xcframework..."
    resolve_packages
    build_simulator

    log_info "✅ GhosttyKit sync complete"
}

# Extract screenshots from xcresult bundles.
# xcresult stores attachments inside per-test summaryRef objects, so we must:
#   1. Get the top-level testsRef to find all test metadata
#   2. Collect each test's summaryRef ID
#   3. Fetch each summary and extract attachment payloadRef IDs
#   4. Export each attachment as a raw PNG
extract_screenshots() {
    local RESULT_BUNDLE="${1:-$SCRIPT_DIR/test_results/ui_tests.xcresult}"
    local OUTPUT_DIR="$SCRIPT_DIR/test_results/screenshots"

    if [ ! -d "$RESULT_BUNDLE" ]; then
        log_error "No xcresult bundle found at $RESULT_BUNDLE"
        log_info "Run './ci.sh ui-test' first to generate test results"
        return 1
    fi

    log_info "Extracting screenshots from $(basename "$RESULT_BUNDLE")..."

    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"

    # Step 1: Get top-level result and find testsRef
    local TOP_JSON
    TOP_JSON=$(xcrun xcresulttool get --legacy --format json --path "$RESULT_BUNDLE" 2>/dev/null)

    if [ -z "$TOP_JSON" ]; then
        log_error "Failed to read xcresult bundle"
        return 1
    fi

    local TESTS_REF
    TESTS_REF=$(echo "$TOP_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for action in data.get('actions', {}).get('_values', []):
    ref = action.get('actionResult', {}).get('testsRef', {}).get('id', {}).get('_value', '')
    if ref:
        print(ref)
        break
" 2>/dev/null)

    if [ -z "$TESTS_REF" ]; then
        log_warn "No test action found in xcresult bundle"
        return 0
    fi

    # Step 2: Get test details and collect all per-test summaryRef IDs
    local TEST_DETAILS
    TEST_DETAILS=$(xcrun xcresulttool get --legacy --format json --path "$RESULT_BUNDLE" --id "$TESTS_REF" 2>/dev/null)

    if [ -z "$TEST_DETAILS" ]; then
        log_warn "No test details found"
        return 0
    fi

    local SUMMARY_REFS
    SUMMARY_REFS=$(echo "$TEST_DETAILS" | python3 -c "
import sys, json

def find_summary_refs(obj):
    \"\"\"Recursively find ActionTestMetadata nodes and extract summaryRef + test name.\"\"\"
    results = []
    if isinstance(obj, dict):
        type_name = obj.get('_type', {}).get('_name', '')
        if type_name == 'ActionTestMetadata':
            name = obj.get('name', {}).get('_value', 'unknown')
            ref = obj.get('summaryRef', {}).get('id', {}).get('_value', '')
            if ref:
                safe_name = name.replace('/', '_').replace(' ', '_').replace('()', '')
                results.append((safe_name, ref))
        for val in obj.values():
            results.extend(find_summary_refs(val))
    elif isinstance(obj, list):
        for item in obj:
            results.extend(find_summary_refs(item))
    return results

data = json.load(sys.stdin)
for name, ref_id in find_summary_refs(data):
    print(f'{name}|||{ref_id}')
" 2>/dev/null)

    if [ -z "$SUMMARY_REFS" ]; then
        log_warn "No test summaries found"
        return 0
    fi

    # Step 3: For each test summary, fetch it and extract attachment payloadRefs
    local COUNT=0
    local TOTAL_TESTS=0
    while IFS= read -r summary_line; do
        local TEST_NAME="${summary_line%%|||*}"
        local SUMMARY_ID="${summary_line##*|||}"
        TOTAL_TESTS=$((TOTAL_TESTS + 1))

        [ -z "$SUMMARY_ID" ] && continue

        local SUMMARY_JSON
        SUMMARY_JSON=$(xcrun xcresulttool get --legacy --format json --path "$RESULT_BUNDLE" --id "$SUMMARY_ID" 2>/dev/null)
        [ -z "$SUMMARY_JSON" ] && continue

        # Extract attachments from this test summary
        local ATTACHMENTS
        ATTACHMENTS=$(echo "$SUMMARY_JSON" | python3 -c "
import sys, json

def find_attachments(obj):
    results = []
    if isinstance(obj, dict):
        type_name = obj.get('_type', {}).get('_name', '')
        if type_name == 'ActionTestAttachment':
            name = obj.get('name', {}).get('_value', 'unknown')
            payload_ref = obj.get('payloadRef', {}).get('id', {}).get('_value', '')
            if payload_ref:
                safe = name.replace('/', '_').replace(' ', '_')
                results.append((safe, payload_ref))
        for val in obj.values():
            results.extend(find_attachments(val))
    elif isinstance(obj, list):
        for item in obj:
            results.extend(find_attachments(item))
    return results

data = json.load(sys.stdin)
for name, ref_id in find_attachments(data):
    print(f'{name}|||{ref_id}')
" 2>/dev/null)

        [ -z "$ATTACHMENTS" ] && continue

        # Step 4: Export each attachment
        while IFS= read -r att_line; do
            local ATT_NAME="${att_line%%|||*}"
            local ATT_REF="${att_line##*|||}"

            if [ -n "$ATT_REF" ] && [ -n "$ATT_NAME" ]; then
                local OUT_FILE="$OUTPUT_DIR/${TEST_NAME}_${ATT_NAME}.png"
                xcrun xcresulttool get --legacy --format raw --path "$RESULT_BUNDLE" --id "$ATT_REF" > "$OUT_FILE" 2>/dev/null
                if [ -s "$OUT_FILE" ]; then
                    COUNT=$((COUNT + 1))
                else
                    rm -f "$OUT_FILE"
                fi
            fi
        done <<< "$ATTACHMENTS"
    done <<< "$SUMMARY_REFS"

    log_info "✅ Extracted $COUNT screenshots from $TOTAL_TESTS tests to $OUTPUT_DIR"
    if [ "$COUNT" -gt 0 ]; then
        ls -la "$OUTPUT_DIR" 2>/dev/null | head -30
    fi
}

# Full local validation: rebuild GhosttyKit from source, then build + test Geistty.
# This is the primary workflow while CI is frozen (no LFS, no remote artifacts).
# GhosttyKit is a generated artifact (gitignored), so building in-place is safe.
local_validate() {
    log_info "=== Local Validate: full pipeline ==="

    # Step 1: Ensure TestConfig.local.swift exists
    log_info "--- Step 1/3: Ensure test config ---"
    ensure_test_config

    # Step 2: Build GhosttyKit from sibling ghostty repo, resolve, and build
    # sync_ghostty handles: zig build → copy → strip → modulemap rename → resolve → build
    log_info "--- Step 2/3: Build and sync GhosttyKit ---"
    sync_ghostty

    # Step 3: Run tests
    log_info "--- Step 3/3: Run tests ---"
    run_tests

    log_info "=== Local Validate: all steps passed ==="
}

# Run all checks
run_all() {
    resolve_packages
    build_simulator
    run_tests
    lint
    log_info "✅ All CI checks passed!"
}

# Show help
show_help() {
    echo "Geistty CI Script"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  build              Build for iOS Simulator (no signing required)"
    echo "  device-build       Build for iOS device (auto-unlocks CI keychain)"
    echo "  install [NAME]     Install and launch on device (default: iPad)"
    echo "  deploy [NAME]      Build, install, and launch with console output"
    echo "  test               Run unit tests on simulator"
    echo "  ui-test            Run UI tests on iPhone simulator"
    echo "  ui-test-ipad       Run UI tests on iPad Pro simulator"
    echo "  visual-test        Run visual regression tests (screenshot comparison)"
    echo "  update-snapshots   Record new reference screenshots for visual tests"
    echo "  screenshots [PATH] Extract screenshots from xcresult bundle"
    echo "  lint               Analyze code for warnings"
    echo "  sync-ghostty       Rebuild and sync GhosttyKit xcframework from ghostty fork"
    echo "  local-validate     Full pipeline: rebuild GhosttyKit + build + test"
    echo "  all                Run all CI checks"
    echo "  help               Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 build                    # Build for simulator"
    echo "  $0 ui-test                  # Run UI tests on iPhone 17 Pro"
    echo "  $0 ui-test-ipad             # Run UI tests on iPad Pro 13-inch"
    echo "  $0 visual-test              # Run visual regression tests"
    echo "  $0 update-snapshots         # Record new reference screenshots"
    echo "  $0 sync-ghostty             # Rebuild GhosttyKit from ghostty fork"
    echo "  $0 local-validate           # Full pipeline (rebuild + build + test)"
    echo "  $0 all                      # Full CI run"
}

# Create test results directory
mkdir -p "$SCRIPT_DIR/test_results"

# Main command dispatch
case "${1:-help}" in
    build)
        resolve_packages
        build_simulator
        ;;
    device-build)
        resolve_packages
        build_device "${2:-}"
        ;;
    install)
        install_device "${2:-}"
        ;;
    deploy)
        deploy_device "${2:-}"
        ;;
    test)
        run_tests
        ;;
    ui-test)
        run_ui_tests
        ;;
    ui-test-ipad)
        run_ui_tests_ipad
        ;;
    visual-test)
        run_visual_tests
        ;;
    update-snapshots)
        update_snapshots
        ;;
    screenshots)
        extract_screenshots "${2:-}"
        ;;
    lint)
        lint
        ;;
    syntax)
        syntax_check
        ;;
    sync-ghostty)
        sync_ghostty
        ;;
    local-validate)
        local_validate
        ;;
    all)
        run_all
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
