#!/bin/bash
#
# add_unit_test_target.sh
# Adds GeisttyTests unit test target to the Xcode project
#
# This script creates the necessary test target configuration in project.pbxproj
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_FILE="$SCRIPT_DIR/Geistty.xcodeproj/project.pbxproj"

# Check if target already exists
if grep -q "GeisttyTests.xctest" "$PROJECT_FILE"; then
    echo "✅ GeisttyTests target already exists"
    exit 0
fi

echo "Adding GeisttyTests target to project..."

# Generate unique IDs for the test target
# Format: D[1-9]XXXXXX for test target items
TEST_PRODUCT_ID="D1000001"
TEST_TARGET_ID="D6000001"
TEST_SOURCES_ID="D7000001"
TEST_FRAMEWORKS_ID="D4000001"
TEST_RESOURCES_ID="D5000001"
TEST_CONFIG_LIST_ID="DA000001"
TEST_DEBUG_CONFIG_ID="DB000001"
TEST_RELEASE_CONFIG_ID="DC000001"
TEST_GROUP_ID="D5000002"
TEST_PROXY_ID="D3000001"
TEST_DEPENDENCY_ID="D3000002"

# File references for test files
TEST_FILE_1_REF="D2000001"
TEST_FILE_1_BUILD="D1000002"

# Create backup
cp "$PROJECT_FILE" "$PROJECT_FILE.backup"

# Use Python for complex pbxproj manipulation
python3 << 'PYTHON_SCRIPT'
import re
import sys

project_file = sys.argv[1] if len(sys.argv) > 1 else "Geistty.xcodeproj/project.pbxproj"

with open(project_file, 'r') as f:
    content = f.read()

# Add file reference for FileProviderTests.swift
file_ref_section = """		D2000001 /* FileProviderTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FileProviderTests.swift; sourceTree = "<group>"; };
"""

# Add build file
build_file_section = """		D1000002 /* FileProviderTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = D2000001 /* FileProviderTests.swift */; };
"""

# Add test target product reference
product_ref = """		D1000001 /* GeisttyTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = GeisttyTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
"""

# Add container item proxy for dependency
proxy_section = """		D3000001 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = AA000001 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = A6000001;
			remoteInfo = Geistty;
		};
"""

# Add target dependency
dependency_section = """		D3000002 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = A6000001 /* Geistty */;
			targetProxy = D3000001 /* PBXContainerItemProxy */;
		};
"""

# Add test group
group_section = """		D5000002 /* GeisttyTests */ = {
			isa = PBXGroup;
			children = (
				D2000001 /* FileProviderTests.swift */,
			);
			path = GeisttyTests;
			sourceTree = "<group>";
		};
"""

# Add sources build phase
sources_phase = """		D7000001 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				D1000002 /* FileProviderTests.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
"""

# Add frameworks build phase  
frameworks_phase = """		D4000001 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
"""

# Add resources build phase
resources_phase = """		D5000001 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
"""

# Add native target
target_section = """		D6000001 /* GeisttyTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = DA000001 /* Build configuration list for PBXNativeTarget "GeisttyTests" */;
			buildPhases = (
				D7000001 /* Sources */,
				D4000001 /* Frameworks */,
				D5000001 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				D3000002 /* PBXTargetDependency */,
			);
			name = GeisttyTests;
			productName = GeisttyTests;
			productReference = D1000001 /* GeisttyTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		};
"""

# Build configuration list for test target
config_list = """		DA000001 /* Build configuration list for PBXNativeTarget "GeisttyTests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				DB000001 /* Debug */,
				DC000001 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
"""

# Debug build settings
debug_config = """		DB000001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = GeisttyTests;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.geistty.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Geistty.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Geistty";
			};
			name = Debug;
		};
"""

# Release build settings
release_config = """		DC000001 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = GeisttyTests;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.geistty.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Geistty.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Geistty";
			};
			name = Release;
		};
"""

# Insert sections into the appropriate places

# 1. Add build file in PBXBuildFile section
build_file_marker = "/* End PBXBuildFile section */"
content = content.replace(build_file_marker, build_file_section + build_file_marker)

# 2. Add container item proxy
proxy_marker = "/* End PBXContainerItemProxy section */"
content = content.replace(proxy_marker, proxy_section + proxy_marker)

# 3. Add file reference in PBXFileReference section
file_ref_marker = "/* End PBXFileReference section */"
content = content.replace(file_ref_marker, file_ref_section + product_ref + file_ref_marker)

# 4. Add test group and update main group
group_marker = "/* End PBXGroup section */"
content = content.replace(group_marker, group_section + group_marker)

# 5. Add build phases
frameworks_marker = "/* End PBXFrameworksBuildPhase section */"
content = content.replace(frameworks_marker, frameworks_phase + frameworks_marker)

# Check if PBXResourcesBuildPhase section exists, if not add it
if "/* End PBXResourcesBuildPhase section */" not in content:
    # Add after PBXFrameworksBuildPhase
    content = content.replace(
        "/* End PBXFrameworksBuildPhase section */",
        "/* End PBXFrameworksBuildPhase section */\n\n/* Begin PBXResourcesBuildPhase section */\n" + resources_phase + "/* End PBXResourcesBuildPhase section */\n"
    )
else:
    resources_marker = "/* End PBXResourcesBuildPhase section */"
    content = content.replace(resources_marker, resources_phase + resources_marker)

# 6. Add sources build phase
sources_marker = "/* End PBXSourcesBuildPhase section */"
content = content.replace(sources_marker, sources_phase + sources_marker)

# 7. Add target dependency section if not exists
if "/* Begin PBXTargetDependency section */" not in content:
    # Add after PBXSourcesBuildPhase
    content = content.replace(
        "/* End PBXSourcesBuildPhase section */",
        "/* End PBXSourcesBuildPhase section */\n\n/* Begin PBXTargetDependency section */\n" + dependency_section + "/* End PBXTargetDependency section */\n"
    )
else:
    dep_marker = "/* End PBXTargetDependency section */"
    content = content.replace(dep_marker, dependency_section + dep_marker)

# 8. Add native target
target_marker = "/* End PBXNativeTarget section */"
content = content.replace(target_marker, target_section + target_marker)

# 9. Add to project targets list
# Find the targets line and add the test target
targets_pattern = r'(targets = \(\s*\n\s*A6000001 /\* Geistty \*/,)'
targets_replacement = r'\1\n\t\t\t\tD6000001 /* GeisttyTests */,'
content = re.sub(targets_pattern, targets_replacement, content)

# 10. Add build configurations
config_marker = "/* End XCConfigurationList section */"
content = content.replace(config_marker, config_list + config_marker)

# Find XCBuildConfiguration section and add configs
build_config_pattern = r'(/\* End XCBuildConfiguration section \*/)'
build_config_insert = debug_config + release_config
content = re.sub(build_config_pattern, build_config_insert + r'\1', content)

# 11. Add GeisttyTests group to main group children
# Find the main group (A5000001) and add GeisttyTests
main_group_pattern = r'(A5000001 = \{\s*isa = PBXGroup;\s*children = \()'
main_group_replacement = r'\1\n\t\t\t\tD5000002 /* GeisttyTests */,'
content = re.sub(main_group_pattern, main_group_replacement, content)

# 12. Add to Products group
products_pattern = r'(A5000010 /\* Products \*/ = \{\s*isa = PBXGroup;\s*children = \()'
products_replacement = r'\1\n\t\t\t\tD1000001 /* GeisttyTests.xctest */,'
content = re.sub(products_pattern, products_replacement, content)

with open(project_file, 'w') as f:
    f.write(content)

print("✅ GeisttyTests target added to project")
PYTHON_SCRIPT

echo "Done! Test target added."
echo ""
echo "To run tests:"
echo "  xcodebuild test -project Geistty.xcodeproj -scheme GeisttyTests -destination 'platform=iOS Simulator,name=iPhone 15'"
