// The choices themselves: what a phone that has never been to the screen does, that a change
// survives being killed, and that the one thing which throws the local copy away leaves them
// standing.

import 'dart:io';

import 'package:amenbo_viewer/about_screen.dart';
import 'package:amenbo_viewer/settings.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('what an untouched phone does', () {
    test('it goes and looks, and wears what the phone wears', () {
      final settings = SettingsController(UnkeptSettings()).value;

      expect(settings, ViewerSettings.defaults);
      expect(settings.refresh, Refresh.automatic);
      expect(settings.appearance.themeMode, ThemeMode.system);
    });

    test('a value written by another build reads as the default', () {
      final keep = UnkeptSettings()..write(MetaKey.appearance, 'sepia');

      final settings = SettingsController(keep).value;

      // Not an exception and not a blank screen: a settings row nobody recognises is worth less
      // than the launch it would otherwise take down.
      expect(settings.appearance, Appearance.system);
    });

    test('a choice this build no longer has is left where it lies', () {
      // A phone that once chose a week of finished work. Nothing reads the row any more, and a
      // launch is not the place to find out that it is there.
      final keep = UnkeptSettings()..write('done_window', '7');

      expect(SettingsController(keep).value, ViewerSettings.defaults);
    });
  });

  test('a choice is written before it is announced', () {
    final keep = UnkeptSettings();
    final settings = SettingsController(keep);
    var announced = 0;
    settings.addListener(() {
      announced += 1;
      // The listener is what redraws the app, so what it reads has to be on the device already.
      expect(keep.read(MetaKey.appearance), Appearance.dark.stored);
    });

    settings.setAppearance(Appearance.dark);

    expect(announced, 1);
    expect(settings.value.appearance, Appearance.dark);
  });

  test('choosing what is already chosen announces nothing', () {
    final settings = SettingsController(UnkeptSettings());
    var announced = 0;
    settings.addListener(() => announced += 1);

    settings.setRefresh(Refresh.automatic);

    expect(announced, 0);
  });

  test('the choices outlive the process', () {
    final keep = UnkeptSettings();
    SettingsController(keep)
      ..setRefresh(Refresh.manualOnly)
      ..setAppearance(Appearance.dark);

    // A second controller over the same keep is what the next launch is.
    expect(
      SettingsController(keep).value,
      const ViewerSettings(
        refresh: Refresh.manualOnly,
        appearance: Appearance.dark,
      ),
    );
  });

  test('throwing the local copy away leaves the choices standing', () {
    final store = BacklogStore.openInMemory();
    addTearDown(store.close);
    final settings = SettingsController(StoredSettings(store))
      ..setRefresh(Refresh.manualOnly)
      ..setAppearance(Appearance.dark);
    store.seq = 42;

    // What the intake does when the place turns out to have been built again from nothing. The
    // person has not changed their mind about how the app should look.
    store.wipe();

    expect(store.seq, 0);
    expect(SettingsController(StoredSettings(store)).value, settings.value);
  });

  test('the version on the About screen is the version being built', () {
    final declared = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((line) => line.startsWith('version:'))
        .split(':')
        .last
        .trim();

    // Both halves are on the screen, so both halves are held here. A build handed out for testing
    // carries the same version as the last one, and the number is the only thing telling a tester
    // which of them they have.
    expect(declared.split('+').first, appVersion);
    expect(declared.split('+').last, appBuild);
    expect(appVersionShown, "${declared.replaceFirst('+', ' (')})");
  });
}
