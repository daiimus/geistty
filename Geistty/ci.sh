#!/bin/bash
#
# ci.sh - Continuous Integration script for Geistty
#
# This script builds and validates the project without requiring a device.
# Useful for automated testing and agent-driven development.
#
# Usage:
#   ./ci.sh build          - Build for simulator
#   ./ci.sh test           - Run unit tests on simulator  
#   ./ci.sh lint           - Check for Swift warnings/errors
#   ./ci.sh sync-ghostty   - Rebuild and sync GhosttyKit from ghostty fork
#   ./ci.sh all            - Run all checks (build + test + lint)
#   ./ci.sh device-build   - Build for device (requires signing)
#   ./ci.sh install DEVICE - Install and run on device
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="Geistty.xcodeproj"
SCHEME="Geistty"
SIMULATOR="platform=iOS Simulator,name=iPhone 17 Pro"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/Geistty-ci"

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
    log_info "Building for iOS Device..."
    
    local DEVICE_ID="${1:-}"
    if [ -z "$DEVICE_ID" ]; then
        # Find first connected device
        DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | grep -E "^[0-9A-F-]+" | head -1 | awk '{print $1}')
    fi
    
    if [ -z "$DEVICE_ID" ]; then
        log_error "No device found. Connect a device or provide DEVICE_ID"
        return 1
    fi
    
    log_info "Building for device: $DEVICE_ID"
    
    xcodebuild build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "id=$DEVICE_ID" \
        -allowProvisioningUpdates \
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
    local DEVICE_ID="${1:-}"
    if [ -z "$DEVICE_ID" ]; then
        DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | grep -E "^[0-9A-F-]+" | head -1 | awk '{print $1}')
    fi
    
    if [ -z "$DEVICE_ID" ]; then
        log_error "No device found"
        return 1
    fi
    
    # Find the built app
    APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "Geistty.app" -path "*/Debug-iphoneos/*" 2>/dev/null | head -1)
    
    if [ -z "$APP_PATH" ]; then
        log_error "No built app found. Run 'build_device' first."
        return 1
    fi
    
    log_info "Installing $APP_PATH on $DEVICE_ID..."
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1
    
    log_info "Launching app..."
    xcrun devicectl device process launch --device "$DEVICE_ID" com.geistty.app 2>&1
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
    log_info "Running UI tests..."
    
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$SIMULATOR" \
        -only-testing:GeisttyUITests \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$SCRIPT_DIR/test_results/ui_tests.xcresult" \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | tee /tmp/geistty_ui_tests.log | tail -50
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_info "✅ UI Tests passed"
    else
        log_error "❌ UI Tests failed"
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

    log_info "Renaming module maps (module.modulemap -> GhosttyKit.modulemap)..."
    for dir in "$SCRIPT_DIR/Frameworks/GhosttyKit.xcframework"/*/Headers/; do
        if [ -f "${dir}module.modulemap" ]; then
            mv "${dir}module.modulemap" "${dir}GhosttyKit.modulemap"
        fi
    done

    log_info "Verifying build with new xcframework..."
    resolve_packages
    build_simulator

    log_info "✅ GhosttyKit sync complete"
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
    echo "  build           Build for iOS Simulator (no signing required)"
    echo "  device-build    Build for iOS device (requires signing)"
    echo "  install [ID]    Install and launch on device"
    echo "  test            Run unit tests on simulator"
    echo "  ui-test         Run UI tests on simulator"
    echo "  lint            Analyze code for warnings"
    echo "  sync-ghostty    Rebuild and sync GhosttyKit xcframework from ghostty fork"
    echo "  all             Run all CI checks"
    echo "  help            Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 build                              # Build for simulator"
    echo "  $0 install 00008103-001425D11153001E  # Install on specific device"
    echo "  $0 all                                # Full CI run"
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
    test)
        run_tests
        ;;
    ui-test)
        run_ui_tests
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
