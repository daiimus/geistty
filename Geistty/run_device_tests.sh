#!/bin/bash
# Run File Provider integration tests on a real device
#
# These tests require the app to be installed with the File Provider extension.
# They test actual extension behavior, not just the components.
#
# Usage:
#   ./run_device_tests.sh [device-id]
#
# If no device-id is provided, uses the first connected device.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}[INFO]${NC} Running File Provider integration tests on device..."

# Find device
if [ -n "$1" ]; then
    DEVICE_ID="$1"
else
    # Get first connected device
    DEVICE_ID=$(xcrun devicectl list devices 2>&1 | grep "connected" | head -1 | awk '{print $3}')
fi

if [ -z "$DEVICE_ID" ]; then
    echo -e "${RED}[ERROR]${NC} No connected device found. Connect an iOS device and try again."
    exit 1
fi

echo -e "${GREEN}[INFO]${NC} Using device: $DEVICE_ID"

# Build and test on device
xcodebuild test \
    -project Geistty.xcodeproj \
    -scheme Geistty \
    -destination "id=$DEVICE_ID" \
    -only-testing:GeisttyTests/FileProviderExtensionTests \
    -allowProvisioningUpdates \
    -resultBundlePath test_results/device_tests.xcresult \
    2>&1 | tee /tmp/device_tests.log

# Check result
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo -e "${GREEN}[INFO]${NC} ✅ Device tests passed"
else
    echo -e "${RED}[ERROR]${NC} ❌ Device tests failed"
    echo -e "${YELLOW}[INFO]${NC} Check /tmp/device_tests.log for details"
    exit 1
fi
