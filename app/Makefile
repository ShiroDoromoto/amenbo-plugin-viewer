# The app's build is Flutter's; this only gives the root Makefile the three verbs it calls, so
# `make build` at the top of the repository reaches every part the same way.
#
# `build` stops at what needs no platform SDK and no device — the same place the Worker's does.
# The platform builds are named targets of their own, because each one needs a toolchain not
# every machine has (the Android SDK; Xcode and a Mac), and `make build` failing on a machine
# that simply is not set up for Android would say nothing about the code.

FLUTTER := flutter

.PHONY: build test analyze apk ipa clean

build: analyze

analyze:
	$(FLUTTER) pub get
	$(FLUTTER) analyze

test:
	$(FLUTTER) test

# Android. Needs the Android SDK.
apk:
	$(FLUTTER) build apk --debug

# iOS. Needs Xcode and a Mac. Unsigned — signing is the release's business, not the build's.
ipa:
	$(FLUTTER) build ios --no-codesign

clean:
	$(FLUTTER) clean
