/// The few things the person is allowed to change, and where those choices are kept.
///
/// The list is short on purpose. This is a thing to read, so every switch on it is one more place
/// to stop on the way to the backlog — and a switch that changed how a screen is built would mean
/// the app has two shapes and nobody has seen both. What is left is when to go and look, how dark
/// it is, and how far back the finished ones reach.
///
/// **There is no refresh interval.** The app is not resident and never wakes itself, so an
/// interval would be a number that does nothing. Automatic means launch and coming back to the
/// front, and the alternative is not a slower version of that but pulling the list down by hand.
///
/// The choices are this device's own, not the place's, so they are kept beside the cursor rather
/// than inside it: throwing the local copy away and taking it again leaves them standing.
library;

import 'package:flutter/material.dart';

import 'store/backlog_store.dart';

/// When the app goes and looks.
enum Refresh {
  /// On launch and on coming back to the front, and at no other moment.
  automatic('automatic', 'Automatically'),

  /// Only when the person pulls the list down.
  manualOnly('manual', 'Only when I pull to refresh');

  const Refresh(this.stored, this.words);

  /// What goes in the store. Written out rather than an index, so reordering this list cannot
  /// silently change what a phone has already chosen.
  final String stored;
  final String words;

  /// An unwritten or unrecognised choice reads as the default rather than as an error: a settings
  /// row is not worth failing a launch over.
  static Refresh read(String? stored) =>
      values.firstWhere((one) => one.stored == stored, orElse: () => automatic);
}

/// Light or dark, or whatever the phone is doing.
enum Appearance {
  system('system', 'Match the phone', ThemeMode.system),
  light('light', 'Light', ThemeMode.light),
  dark('dark', 'Dark', ThemeMode.dark);

  const Appearance(this.stored, this.words, this.themeMode);

  final String stored;
  final String words;
  final ThemeMode themeMode;

  static Appearance read(String? stored) =>
      values.firstWhere((one) => one.stored == stored, orElse: () => system);
}

/// How far back the finished ones reach on the list.
enum DoneWindow {
  sevenDays('7', 'The last 7 days', 7),
  thirtyDays('30', 'The last 30 days', 30),
  everything('all', 'Everything', null);

  const DoneWindow(this.stored, this.words, this.days);

  final String stored;
  final String words;

  /// Null for [everything] — no cut-off at all, which is not the same as a very large number of
  /// days and is worth being able to say.
  final int? days;

  static DoneWindow read(String? stored) =>
      values.firstWhere((one) => one.stored == stored, orElse: () => sevenDays);
}

/// The three choices, together.
@immutable
class ViewerSettings {
  const ViewerSettings({
    this.refresh = Refresh.automatic,
    this.appearance = Appearance.system,
    this.doneWindow = DoneWindow.sevenDays,
  });

  /// What a phone that has never been to this screen behaves like: go and look without being
  /// asked, wear what the phone wears, and keep a week of finished work.
  static const defaults = ViewerSettings();

  final Refresh refresh;
  final Appearance appearance;
  final DoneWindow doneWindow;

  ViewerSettings copyWith({
    Refresh? refresh,
    Appearance? appearance,
    DoneWindow? doneWindow,
  }) => ViewerSettings(
    refresh: refresh ?? this.refresh,
    appearance: appearance ?? this.appearance,
    doneWindow: doneWindow ?? this.doneWindow,
  );

  @override
  bool operator ==(Object other) =>
      other is ViewerSettings &&
      other.refresh == refresh &&
      other.appearance == appearance &&
      other.doneWindow == doneWindow;

  @override
  int get hashCode => Object.hash(refresh, appearance, doneWindow);
}

/// Where the choices survive a restart.
abstract interface class SettingsKeep {
  String? read(String key);

  void write(String key, String value);
}

/// The local store's `meta` table, which is where a device's own remembering already lives.
class StoredSettings implements SettingsKeep {
  const StoredSettings(this._store);

  final BacklogStore _store;

  @override
  String? read(String key) => _store.meta(key);

  @override
  void write(String key, String value) => _store.setMeta(key, value);
}

/// Choices that last as long as the process and no longer — for tests, and for anything running
/// without a store behind it.
class UnkeptSettings implements SettingsKeep {
  final _written = <String, String>{};

  @override
  String? read(String key) => _written[key];

  @override
  void write(String key, String value) => _written[key] = value;
}

/// The current settings, and the one place they are changed.
///
/// A change is written before it is announced, so a phone killed the moment after a tap comes back
/// with the choice the person made rather than the one they replaced.
class SettingsController extends ChangeNotifier {
  SettingsController(this._keep)
    : _value = ViewerSettings(
        refresh: Refresh.read(_keep.read(MetaKey.refresh)),
        appearance: Appearance.read(_keep.read(MetaKey.appearance)),
        doneWindow: DoneWindow.read(_keep.read(MetaKey.doneWindow)),
      );

  final SettingsKeep _keep;
  ViewerSettings _value;

  ViewerSettings get value => _value;

  void setRefresh(Refresh refresh) {
    _change(_value.copyWith(refresh: refresh), MetaKey.refresh, refresh.stored);
  }

  void setAppearance(Appearance appearance) {
    _change(
      _value.copyWith(appearance: appearance),
      MetaKey.appearance,
      appearance.stored,
    );
  }

  void setDoneWindow(DoneWindow doneWindow) {
    _change(
      _value.copyWith(doneWindow: doneWindow),
      MetaKey.doneWindow,
      doneWindow.stored,
    );
  }

  void _change(ViewerSettings next, String key, String stored) {
    if (next == _value) return;
    _keep.write(key, stored);
    _value = next;
    notifyListeners();
  }
}
