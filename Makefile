PHONY: run xcframework

# Allow overriding common build knobs.
CONFIG ?= Debug
DESTINATION ?= generic/platform=iOS
DESTINATIONS ?= generic/platform=iOS generic/platform=macOS
DERIVED_DATA ?= $(CURDIR)/build/xcodebuild
WORKSPACE ?= .swiftpm/xcode/package.xcworkspace
SCHEME ?= GodotApplePlugins
FRAMEWORK_NAMES ?= GodotApplePlugins GameCenter
XCODEBUILD ?= xcodebuild

run:
	@set -e; \
	$(XCODEBUILD) \
		-workspace '$(WORKSPACE)' \
		-scheme '$(SCHEME)' \
		-configuration '$(CONFIG)' \
		-destination '$(DESTINATION)' \
		-derivedDataPath '$(DERIVED_DATA)' \
		build

xcframework-prep:
	@set -e; \
	for dest in $(DESTINATIONS); do \
	    for framework in $(FRAMEWORK_NAMES); do \
		$(XCODEBUILD) \
			-workspace '$(WORKSPACE)' \
			-scheme $$framework \
			-configuration '$(CONFIG)' \
			-destination "$$dest" \
			-derivedDataPath '$(DERIVED_DATA)' \
			build; \
	    done;  \
	done; \

xcframework: xcframework-prep
	for framework in $(FRAMEWORK_NAMES); do \
		rm -rf $(CURDIR)/addons/$$framework/bin/$$framework.xcframework; \
		$(XCODEBUILD) -create-xcframework \
			-framework $(DERIVED_DATA)/Build/Products/$(CONFIG)-iphoneos/PackageFrameworks/$$framework.framework \
			-framework $(DERIVED_DATA)/Build/Products/$(CONFIG)/PackageFrameworks/$$framework.framework \
			-output $(CURDIR)/addons/$$framework/bin/$${framework}.xcframework; \
	done

XCFRAMEWORK_GAMECENTER ?= $(CURDIR)/addons/GameCenter/bin/GameCenter.xcframework

#
# Quick hacks I use for rapid iteration
#

# This one just gets me a GameCenter I can test on desktop quickly
q:
	make xcframework FRAMEWORK_NAMES=GameCenter DERIVED_DATA=~/DerivedData/GodotApplePlugins-*

o:
	rm -rf '$(XCFRAMEWORK_GAMECENTER)'; \
	$(XCODEBUILD) -create-xcframework \
		-framework ~/DerivedData/GodotApplePlugins-*/Build/Products/Debug-iphoneos/PackageFrameworks/GameCenter.framework/ \
		-framework ~/DerivedData/GodotApplePlugins-*/Build/Products/Debug/PackageFrameworks/GameCenter.framework/ \
		-output '$(XCFRAMEWORK_GAMECENTER)'
