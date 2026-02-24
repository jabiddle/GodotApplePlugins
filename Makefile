.PHONY: run xcframework check_swiftsyntax build pre-build build-ios build-macos

# Allow overriding common build knobs.
CONFIG ?= Release
DERIVED_DATA ?= $(CURDIR)/.xcodebuild
WORKSPACE ?= .swiftpm/xcode/package.xcworkspace
SCHEME ?= GodotApplePlugins
FRAMEWORK_NAMES ?= GodotApplePlugins
XCODEBUILD ?= xcodebuild
XCODEBUILD_ARGS ?=

run:
	@echo -e "Run make xcframework to produce the binary payloads for all platforms"

# The master build target triggers the prerequisite and explicit platform targets
build: pre-build build-ios build-macos

pre-build:
	@echo "Pre-building Swift Macros natively..."
	swift build

build-ios:
	@echo "Building for iOS..."
	set -e; \
	for framework in $(FRAMEWORK_NAMES); do \
		$(XCODEBUILD) \
			-workspace '$(WORKSPACE)' \
			-scheme $$framework \
			-configuration '$(CONFIG)' \
			-destination "generic/platform=iOS" \
			-derivedDataPath "$(DERIVED_DATA)-ios" \
			$(XCODEBUILD_ARGS) \
			build; \
		\
		$(CURDIR)/relink_without_swiftsyntax.sh \
			--derived-data "$(DERIVED_DATA)-ios" \
			--config "$(CONFIG)" \
			--framework $$framework \
			--platform ios; \
	done

build-macos:
	@echo "Building for macOS Universal..."
	set -e; \
	for framework in $(FRAMEWORK_NAMES); do \
		$(XCODEBUILD) \
			-workspace '$(WORKSPACE)' \
			-scheme $$framework \
			-configuration '$(CONFIG)' \
			-destination "generic/platform=macOS" \
			-derivedDataPath "$(DERIVED_DATA)-macos" \
			ARCHS="x86_64 arm64" \
			ONLY_ACTIVE_ARCH=NO \
			$(XCODEBUILD_ARGS) \
			build; \
		\
		$(CURDIR)/relink_without_swiftsyntax.sh \
			--derived-data "$(DERIVED_DATA)-macos" \
			--config "$(CONFIG)" \
			--framework $$framework \
			--platform macos; \
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

package: build dist

dist:
	set -e; \
	for framework in $(FRAMEWORK_NAMES); do \
		config_lc=`echo $(CONFIG) | tr '[:upper:]' '[:lower:]'`; \
		out_dir="$(CURDIR)/addons/$$framework/bin/$$config_lc"; \
		mkdir -p $$out_dir; \
		rm -rf $$out_dir/$$framework.xcframework; \
		rm -rf $$out_dir/$$framework*.framework; \
		\
		if [ -d "$(DERIVED_DATA)-ios/Build/Products/$(CONFIG)-iphoneos/PackageFrameworks/$$framework.framework" ]; then \
			$(XCODEBUILD) -create-xcframework \
				-framework "$(DERIVED_DATA)-ios/Build/Products/$(CONFIG)-iphoneos/PackageFrameworks/$$framework.framework" \
				-output "$$out_dir/$${framework}.xcframework"; \
		else \
			echo "Skipping iOS xcframework creation for $$framework (directory not found)"; \
		fi; \
		\
		MAC_FW="$(DERIVED_DATA)-macos/Build/Products/$(CONFIG)/PackageFrameworks/$${framework}.framework"; \
		if [ -d "$$MAC_FW" ]; then \
			rsync -a "$$MAC_FW/" "$$out_dir/$${framework}_x64.framework"; \
			lipo -thin x86_64 "$$out_dir/$${framework}_x64.framework/Versions/Current/$${framework}" -output "$$out_dir/$${framework}_x64.framework/Versions/Current/$${framework}" 2>/dev/null || true; \
			\
			rsync -a "$$MAC_FW/" "$$out_dir/$${framework}.framework"; \
			lipo -thin arm64 "$$out_dir/$${framework}.framework/Versions/Current/$${framework}" -output "$$out_dir/$${framework}.framework/Versions/Current/$${framework}" 2>/dev/null || true; \
			\
			if [ -d "doc_classes/" ]; then \
				rsync -a "doc_classes/" "$$out_dir/$${framework}_x64.framework/Resources/doc_classes/" 2>/dev/null || true; \
				rsync -a "doc_classes/" "$$out_dir/$${framework}.framework/Resources/doc_classes/" 2>/dev/null || true; \
			fi; \
		else \
			echo "Skipping macOS framework copy for $$framework (directory not found)"; \
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
