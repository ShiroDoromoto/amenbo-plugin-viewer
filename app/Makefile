# The app's build is Flutter's; this only gives the root Makefile the three verbs it calls, so
# `make build` at the top of the repository reaches every part the same way.
#
# `build` stops at what needs no platform SDK and no device — the same place the Worker's does.
# The platform builds are named targets of their own, because each one needs a toolchain not
# every machine has (the Android SDK; Xcode and a Mac), and `make build` failing on a machine
# that simply is not set up for Android would say nothing about the code.

FLUTTER := flutter

.PHONY: build test analyze apk ipa screen-android screen-ios shots-ios shots-ipad shots-android \
	feature-graphic clean

build: analyze

analyze:
	$(FLUTTER) pub get
	$(FLUTTER) gen-l10n
	$(FLUTTER) analyze

test:
	$(FLUTTER) gen-l10n
	$(FLUTTER) test

# Android. Needs the Android SDK.
apk:
	$(FLUTTER) build apk --debug

# iOS. Needs Xcode and a Mac. Unsigned — signing is the release's business, not the build's.
ipa:
	$(FLUTTER) build ios --no-codesign

# What is on a phone's screen, read with nobody holding the phone. Needs that phone on a cable.
# Neither one is part of `build` or `test`: they talk to hardware, and a machine without it would
# fail for reasons that say nothing about the code.
screen-android:
	tool/device-screen.sh android

screen-ios:
	tool/device-screen.sh ios

# The pictures the stores put next to the app. A simulator, not a phone: the sizes the stores ask
# for are not the sizes of the phone on the cable. Out of `build` and `test` for the same reason
# the two above are.
shots-ios:
	tool/store-shots.sh ios

shots-ipad:
	tool/store-shots.sh ipad

shots-android:
	tool/store-shots.sh android

# The wide picture Play asks for on top of those. It draws rather than photographs, so it needs
# neither a device nor a simulator — but it does need an engine, which is why it runs as a test.
feature-graphic:
	$(FLUTTER) test tool/gen_feature_graphic.dart

clean:
	$(FLUTTER) clean
