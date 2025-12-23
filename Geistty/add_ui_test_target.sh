#!/bin/bash
# add_ui_test_target.sh
# Run this to add the UI test target to the Xcode project
# Or manually: File > New > Target > iOS UI Testing Bundle

echo "📦 To add the UI test target:"
echo ""
echo "1. Open Xcode:"
echo "   open /Users/daiimus/Projects/Repositories/geistty/Geistty/Geistty.xcodeproj"
echo ""
echo "2. In Xcode:"
echo "   - File → New → Target..."
echo "   - Choose 'UI Testing Bundle' under iOS"
echo "   - Name: GeisttyUITests"
echo "   - Target to Test: Geistty"
echo "   - Click Finish"
echo ""
echo "3. When Xcode creates the default test file, replace it with our files:"
echo "   - Delete the auto-generated GeisttyUITests.swift"
echo "   - Drag in the files from: GeisttyUITests/"
echo ""
echo "4. Run tests:"
echo "   - Select an iPad simulator"
echo "   - Product → Test (Cmd+U)"
echo ""
echo "Or run specific tests from command line:"
echo "   xcodebuild test -project Geistty.xcodeproj -scheme GeisttyUITests -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'"

