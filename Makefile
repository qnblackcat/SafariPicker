TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = MobileSafari

DIAGNOSTICS ?= 0

# make package SCHEME=roothide|rootless (default roothide)
export THEOS_PACKAGE_SCHEME := $(or $(SCHEME),roothide)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafariPicker

SafariPicker_FILES = LinkMenu.x FileUpload.x SAPFilePickerViewController.m SAPDiagnostics.m SAPSandbox.m SAPPrefs.m
SafariPicker_CFLAGS = -fobjc-arc -Ivendor/libsandy -DSAP_DIAGNOSTICS=$(DIAGNOSTICS)
SafariPicker_LDFLAGS = -Lvendor/libsandy/$(THEOS_PACKAGE_SCHEME) -lsandy
SafariPicker_FRAMEWORKS = UIKit UniformTypeIdentifiers

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk

# The libSandy profiles in layout/ are written for roothide, whose sandyd passes every path
# through jbroot() ("/" = jailbreak root, "/rootfs/..." = real file system). Rootless sandyd
# uses paths as written, so the staged copies get rootless paths. Stops the build if any
# profile is missing or keeps a roothide path, since "/" would mean the whole file system.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
after-stage::
	$(ECHO_NOTHING)set -e; \
	dir=$$(dirname "$$(find "$(THEOS_STAGING_DIR)" -path '*/Library/libSandy/SafariPicker_FileAccess.plist')"); \
	set_path() { plutil -replace "Extensions.$$2.path" -string "$$3" "$$dir/$$1.plist"; \
		[ "$$(plutil -extract "Extensions.$$2.path" raw "$$dir/$$1.plist")" = "$$3" ] || { echo "SafariPicker: could not set $$1 path $$2" >&2; exit 1; }; }; \
	set_path SafariPicker_FileAccess 0 /var/jb/; \
	set_path SafariPicker_FileAccess 1 /var/mobile/; \
	set_path SafariPicker_SystemAccess 0 /; \
	set_path SafariPicker_Preferences 0 /var/jb/var/mobile/Library/Preferences/$(ECHO_END)
endif
