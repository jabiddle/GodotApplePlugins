.PHONY: run xcframework check_swiftsyntax build pre-build build-ios build-macos build-windows build-linux dist dist-ios dist-macos

# Allow overriding common build knobs.
CONFIG ?= Release
DERIVED_DATA ?= $(CURDIR)/.xcodebuild
FRAMEWORK_NAMES ?= GodotApplePlugins
XCODEBUILD ?= xcodebuild
XCODEBUILD_ARGS ?=

# Zig cross-compilation for C stub
LINUX_CC ?= zig cc -target x86_64-linux-gnu
WINDOWS_CC ?= zig cc -target x86_64-windows-gnu

# Firebase plist paths
IOS_PLIST_PATH ?= $(CURDIR)/GoogleService-Info-iOS.plist
MACOS_PLIST_PATH ?= $(CURDIR)/GoogleService-Info-macOS.plist

run:
	@echo -e "Run make xcframework to produce the binary payloads for all platforms"

# The master build target triggers the prerequisite and explicit platform targets
build: pre-build build-ios build-macos build-windows build-linux

pre-build:
	@echo "Pre-building Swift Macros natively..."
	swift build

build-ios:
	@echo "Building for iOS..."
	mkdir -p "$(DERIVED_DATA)-ios"
	set -e; set -o pipefail; \
	for framework in $(FRAMEWORK_NAMES); do \
		$(XCODEBUILD) \
			-scheme $$framework \
			-configuration '$(CONFIG)' \
			-destination "generic/platform=iOS" \
			-derivedDataPath "$(DERIVED_DATA)-ios" \
			$(XCODEBUILD_ARGS) \
			build 2>&1 | tee "$(DERIVED_DATA)-ios/build.log"; \
		\
		$(CURDIR)/relink_without_swiftsyntax.sh \
			--derived-data "$(DERIVED_DATA)-ios" \
			--config "$(CONFIG)" \
			--framework $$framework \
			--platform ios \
			--build-log "$(DERIVED_DATA)-ios/build.log"; \
		\
		echo "Uploading iOS dSYMs to Crashlytics..."; \
		UPLOAD_TOOL="$(DERIVED_DATA)-ios/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols"; \
		DSYM_DIR="$(DERIVED_DATA)-ios/Build/Products/$(CONFIG)-iphoneos/"; \
		if [ "$(CONFIG)" != "Release" ]; then \
			echo "Skipping dSYM upload for non-Release build ($(CONFIG))."; \
		elif [ ! -f "$(IOS_PLIST_PATH)" ]; then \
			echo "GoogleService-Info-iOS.plist not found. Skipping dSYM upload."; \
		elif [ -x "$$UPLOAD_TOOL" ] && [ -d "$$DSYM_DIR" ]; then \
			"$$UPLOAD_TOOL" -gsp "$(IOS_PLIST_PATH)" -p ios "$$DSYM_DIR"; \
		else \
			echo "Crashlytics upload tool or dSYM dir not found. Skipping."; \
		fi; \
	done

build-macos:
	@echo "Building for macOS Universal..."
	mkdir -p "$(DERIVED_DATA)-macos"
	set -e; set -o pipefail; \
	for framework in $(FRAMEWORK_NAMES); do \
		$(XCODEBUILD) \
			-scheme $$framework \
			-configuration '$(CONFIG)' \
			-destination "generic/platform=macOS" \
			-derivedDataPath "$(DERIVED_DATA)-macos" \
			ARCHS="x86_64 arm64" \
			ONLY_ACTIVE_ARCH=NO \
			$(XCODEBUILD_ARGS) \
			build 2>&1 | tee "$(DERIVED_DATA)-macos/build.log"; \
		\
		$(CURDIR)/relink_without_swiftsyntax.sh \
			--derived-data "$(DERIVED_DATA)-macos" \
			--config "$(CONFIG)" \
			--framework $$framework \
			--platform macos \
			--build-log "$(DERIVED_DATA)-macos/build.log"; \
		\
		echo "Uploading macOS dSYMs to Crashlytics..."; \
		UPLOAD_TOOL="$(DERIVED_DATA)-macos/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols"; \
		DSYM_DIR="$(DERIVED_DATA)-macos/Build/Products/$(CONFIG)/"; \
		if [ "$(CONFIG)" != "Release" ]; then \
			echo "Skipping dSYM upload for non-Release build ($(CONFIG))."; \
		elif [ ! -f "$(MACOS_PLIST_PATH)" ]; then \
			echo "GoogleService-Info-macOS.plist not found. Skipping dSYM upload."; \
		elif [ -x "$$UPLOAD_TOOL" ] && [ -d "$$DSYM_DIR" ]; then \
			"$$UPLOAD_TOOL" -gsp "$(MACOS_PLIST_PATH)" -p mac "$$DSYM_DIR"; \
		else \
			echo "Crashlytics upload tool or dSYM dir not found. Skipping."; \
		fi; \
	done

check_swiftsyntax:
	set -e; \
	pattern='SwiftSyntax|SwiftParser|SwiftDiagnostics|SwiftParserDiagnostics|SwiftBasicFormat|_SwiftSyntaxCShims'; \
	failed=0; \
	check_one() { \
		sdk="$$1"; bin="$$2"; label="$$3"; \
		if [ ! -f "$$bin" ]; then \
			echo "SKIP: $$label (missing: $$bin)"; \
			return 0; \
		fi; \
		if xcrun --sdk "$$sdk" nm -gU "$$bin" 2>/dev/null | grep -Eq "$$pattern"; then \
			echo "FAIL: $$label still contains SwiftSyntax-related symbols"; \
			failed=1; \
		else \
			echo "OK:   $$label"; \
		fi; \
	}; \
	for framework in $(FRAMEWORK_NAMES); do \
		check_one iphoneos "$(DERIVED_DATA)-ios/Build/Products/$(CONFIG)-iphoneos/PackageFrameworks/$$framework.framework/$$framework" "iOS/$$framework"; \
		check_one macosx "$(DERIVED_DATA)-macos/Build/Products/$(CONFIG)/PackageFrameworks/$$framework.framework/$$framework" "macOS Universal/$$framework"; \
	done; \
	test "$$failed" -eq 0

build-windows:
	@echo "Building stub for Windows using Zig..."
	@config_lc=`echo $(CONFIG) | tr '[:upper:]' '[:lower:]'`; \
	out_dir="$(CURDIR)/addons/GodotApplePlugins/bin/$$config_lc"; \
	mkdir -p "$$out_dir"; \
	$(WINDOWS_CC) -shared Sources/stub.c -o "$$out_dir/godot_apple_plugins.dll"

build-linux:
	@echo "Building stub for Linux using Zig..."
	@config_lc=`echo $(CONFIG) | tr '[:upper:]' '[:lower:]'`; \
	out_dir="$(CURDIR)/addons/GodotApplePlugins/bin/$$config_lc"; \
	mkdir -p "$$out_dir"; \
	$(LINUX_CC) -shared -fPIC Sources/stub.c -o "$$out_dir/libgodot_apple_plugins.so"

package: build dist

# dist is split per platform so a job that only built one platform never reaches
# into the other platform's derived data. Stale .xcodebuild-<platform> trees
# survive between CI jobs on a self-hosted runner, and a failed build leaves the
# .framework directory in place with no binary inside it, so presence of the
# directory is not evidence that the platform was built.
dist: dist-ios dist-macos

dist-ios:
	set -e; \
	for framework in $(FRAMEWORK_NAMES); do \
		config_lc=`echo $(CONFIG) | tr '[:upper:]' '[:lower:]'`; \
		out_dir="$(CURDIR)/addons/$$framework/bin/$$config_lc"; \
		IOS_FW="$(DERIVED_DATA)-ios/Build/Products/$(CONFIG)-iphoneos/PackageFrameworks/$$framework.framework"; \
		if [ ! -f "$$IOS_FW/$$framework" ]; then \
			echo "error: iOS binary missing at $$IOS_FW/$$framework" >&2; \
			echo "       The iOS build did not produce a linked framework. Remove $(DERIVED_DATA)-ios and rebuild." >&2; \
			exit 1; \
		fi; \
		mkdir -p "$$out_dir"; \
		rm -rf "$$out_dir/$$framework.xcframework"; \
		$(XCODEBUILD) -create-xcframework \
			-framework "$$IOS_FW" \
			-output "$$out_dir/$${framework}.xcframework"; \
	done

dist-macos:
	set -e; \
	for framework in $(FRAMEWORK_NAMES); do \
		config_lc=`echo $(CONFIG) | tr '[:upper:]' '[:lower:]'`; \
		out_dir="$(CURDIR)/addons/$$framework/bin/$$config_lc"; \
		MAC_FW="$(DERIVED_DATA)-macos/Build/Products/$(CONFIG)/PackageFrameworks/$${framework}.framework"; \
		if [ ! -f "$$MAC_FW/Versions/Current/$$framework" ]; then \
			echo "error: macOS binary missing at $$MAC_FW/Versions/Current/$$framework" >&2; \
			echo "       The macOS build did not produce a linked framework. Remove $(DERIVED_DATA)-macos and rebuild." >&2; \
			exit 1; \
		fi; \
		mkdir -p "$$out_dir"; \
		rm -rf "$$out_dir/$${framework}.framework" "$$out_dir/$${framework}_x64.framework"; \
		\
		rsync -a "$$MAC_FW/" "$$out_dir/$${framework}_x64.framework"; \
		lipo -thin x86_64 "$$out_dir/$${framework}_x64.framework/Versions/Current/$${framework}" -output "$$out_dir/$${framework}_x64.framework/Versions/Current/$${framework}" 2>/dev/null || true; \
		\
		rsync -a "$$MAC_FW/" "$$out_dir/$${framework}.framework"; \
		lipo -thin arm64 "$$out_dir/$${framework}.framework/Versions/Current/$${framework}" -output "$$out_dir/$${framework}.framework/Versions/Current/$${framework}" 2>/dev/null || true; \
		\
		if [ -d "doc_classes/" ]; then \
			rsync -a "doc_classes/" "$$out_dir/$${framework}_x64.framework/Versions/Current/Resources/doc_classes/" 2>/dev/null || true; \
			rsync -a "doc_classes/" "$$out_dir/$${framework}.framework/Versions/Current/Resources/doc_classes/" 2>/dev/null || true; \
		fi; \
	done

XCFRAMEWORK_GODOTAPPLEPLUGINS ?= $(CURDIR)/addons/GodotApplePlugins/bin/GodotApplePlugins.xcframework

justgen:
	(cd test-apple-godot-api; ~/cvs/master-godot/editor/bin/godot.macos.editor.dev.arm64 --headless --path . --doctool .. --gdextension-docs)

gendocs: justgen
	./fix_doc_enums.sh
	$(MAKE) -C doctools html

#
# Quick hacks I use for rapid iteration
#
# My hack is that I build on Xcode for Mac and iPad first, then I
# iterate by just rebuilding in one platform, and then running
# "make o" here over and over, and my Godot project already has a
# symlink here, so I can test quickly on desktop against the Mac 
# API.
o:
	rm -rf '$(XCFRAMEWORK_GODOTAPPLEPLUGINS)'; \
	rm -rf addons/GodotApplePlugins/bin/GodotApplePlugins.framework; \
	$(XCODEBUILD) -create-xcframework \
		-framework ~/DerivedData/GodotApplePlugins-*/Build/Products/Debug-iphoneos/PackageFrameworks/GodotApplePlugins.framework/ \
		-output '$(XCFRAMEWORK_GODOTAPPLEPLUGINS)'
	cp -pr ~/DerivedData/GodotApplePlugins-*/Build/Products/Debug/PackageFrameworks/GodotApplePlugins.framework addons/GodotApplePlugins/bin/GodotApplePlugins.framework
	rsync -a doc_classes/ addons/GodotApplePlugins/bin/GodotApplePlugins.framework/Resources/doc_classes/
#
# This I am using to test on the "Exported" project I placed
#
XCFRAMEWORK_EXPORT_PATH=test-apple-godot-api/demo/output/dylibs/addons/GodotApplePlugins/bin/GodotApplePlugins.xcframework
make oo:
	rm -rf $(XCFRAMEWORK_EXPORT_PATH)
	$(XCODEBUILD) -create-xcframework \
		-framework ~/DerivedData/GodotApplePlugins-*/Build/Products/Debug-iphoneos/PackageFrameworks/GodotApplePlugins.framework/ \
		-framework ~/DerivedData/GodotApplePlugins-*/Build/Products/Debug/PackageFrameworks/GodotApplePlugins.framework/ \
		-output '$(XCFRAMEWORK_EXPORT_PATH)'
