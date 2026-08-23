// Three identities, held in four places that cannot see each other: Gradle names one, the Xcode
// project names another, the schemes name a third, and the scripts that put the app on a device
// name a fourth. Nothing compiles any of them together, so a suffix changed on one side is found
// on the day someone's store app is overwritten by a build meant for trying out.
//
// The store's identity is the one that must never move: it is what the two stores hold the app
// under, and no later build can be uploaded under a different one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What each identity is called, what it installs as, and what the home screen says.
const _identities = <String, (String, String)>{
  'local': ('work.amenbo.viewer.local', 'Amenbo Local'),
  'dev': ('work.amenbo.viewer.dev', 'Amenbo Dev'),
  'store': ('work.amenbo.viewer', 'Amenbo Viewer'),
};

/// Xcode wants one build configuration per identity per mode, named this way; Flutter looks the
/// name up from `--flavor` and stops if it is not there.
const _modes = <String>['Debug', 'Release', 'Profile'];

void main() {
  final gradle = File('android/app/build.gradle.kts').readAsStringSync();
  final pbxproj = File(
    'ios/Runner.xcodeproj/project.pbxproj',
  ).readAsStringSync();

  test('Android installs each identity under its own name', () {
    // The suffix hangs off one applicationId, so that is checked once rather than three times.
    expect(gradle, contains('applicationId = "work.amenbo.viewer"'));

    for (final MapEntry(key: flavor, value: (id, name))
        in _identities.entries) {
      final flavorBlock = RegExp(
        'create\\("$flavor"\\) \\{(.*?)\\n        \\}',
        dotAll: true,
      ).firstMatch(gradle);
      expect(flavorBlock, isNotNull, reason: 'no $flavor flavor in Gradle');

      final body = flavorBlock!.group(1)!;
      final suffix = id.substring('work.amenbo.viewer'.length);
      if (suffix.isEmpty) {
        // The store's identity takes no suffix at all — a suffix here renames the shipped app.
        expect(body, isNot(contains('applicationIdSuffix')));
      } else {
        expect(body, contains('applicationIdSuffix = "$suffix"'));
      }
      expect(body, contains('manifestPlaceholders["appName"] = "$name"'));
    }

    // The name on the home screen comes from the flavor, so the manifest must not state one.
    expect(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
      contains(r'android:label="${appName}"'),
    );
  });

  test('iOS builds each identity under its own name', () {
    for (final MapEntry(key: flavor, value: (id, name))
        in _identities.entries) {
      for (final mode in _modes) {
        final configuration = RegExp(
          '/\\* $mode-$flavor \\*/ = \\{(.*?)\\n\t\t\\};',
          dotAll: true,
        ).allMatches(pbxproj).map((m) => m.group(1)!).toList();

        // One for the project, one for Runner, one for RunnerTests. Xcode refuses to build a
        // configuration a target does not carry, so all three have to be there.
        expect(
          configuration.length,
          3,
          reason: 'wrong number of $mode-$flavor configurations',
        );

        final runner = configuration.where(
          (c) => c.contains('INFOPLIST_FILE = Runner/Info.plist'),
        );
        expect(
          runner.length,
          1,
          reason: 'no Runner $mode-$flavor configuration',
        );
        expect(runner.single, contains('PRODUCT_BUNDLE_IDENTIFIER = $id;'));
        expect(runner.single, contains('APP_DISPLAY_NAME = "$name";'));
      }

      // Flutter finds the configurations through a scheme of the flavor's name, and only a
      // scheme kept in xcshareddata is there for a checkout that is not this machine's.
      final scheme = File(
        'ios/Runner.xcodeproj/xcshareddata/xcschemes/$flavor.xcscheme',
      );
      expect(scheme.existsSync(), isTrue, reason: 'no $flavor scheme');
      expect(
        scheme.readAsStringSync(),
        contains('buildConfiguration = "Release-$flavor"'),
      );
    }

    // The name is a build setting rather than a constant, which is the whole of how one Info.plist
    // serves three apps.
    expect(
      File('ios/Runner/Info.plist').readAsStringSync(),
      contains('<string>\$(APP_DISPLAY_NAME)</string>'),
    );
  });

  test('what goes to the stores is still the store identity', () {
    final (storeId, storeName) = _identities['store']!;

    // These two are the release's own view of the app. They cannot be handed a flavor, so they
    // are read here against the same table the builds are.
    expect(
      File('tool/release/appstore.py').readAsStringSync(),
      contains('BUNDLE = "$storeId"'),
    );
    expect(
      File('tool/release/play.py').readAsStringSync(),
      contains('PACKAGE = "$storeId"'),
    );
    expect(storeName, 'Amenbo Viewer');
  });

  test('what goes on the phone on the desk is the local identity', () {
    final (localId, _) = _identities['local']!;

    // Both scripts install onto a device that may already carry the store's app; naming the
    // store's identity here would replace it.
    for (final script in ['tool/device-screen.sh', 'tool/store-shots.sh']) {
      expect(
        File(script).readAsStringSync(),
        contains('BUNDLE=$localId'),
        reason: '$script does not use the local identity',
      );
    }
  });
}
