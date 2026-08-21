/// The few things the person is allowed to change, and where those choices are kept.
///
/// The list is short on purpose. This is a thing to read, so every switch on it is one more place
/// to stop on the way to the backlog — and a switch that changed how a screen is built would mean
/// the app has two shapes and nobody has seen both. What is left is when to go and look, and how
/// dark it is.
///
/// **Narrowing is not kept here.** What a list holds is changed where the list is being read, and
/// the one narrowing that had been left in this drawer — how far back the finished ones reached —
/// was cutting off rows the device already held.
///
/// **There is no refresh interval.** The app is not resident and never wakes itself, so an
/// interval would be a number that does nothing. Automatic means launch and coming back to the
/// front, and the alternative is not a slower version of that but asking for it by hand.
///
/// **There is no row for the route.** There is one, it is the person's own Worker, and it ends by
/// erasing this phone's copy — which is on the connection screen, where the rest of what this
/// phone can say about itself is.
///
/// The choices are this device's own, not the place's, so they are kept beside the cursor rather
/// than inside it: throwing the local copy away and taking it again leaves them standing.
library;

import 'package:flutter/material.dart';

import 'l10n/words.dart';
import 'store/backlog_store.dart';

/// When the app goes and looks.
enum Refresh {
  /// On launch and on coming back to the front, and at no other moment.
  automatic('automatic'),

  /// Only when the person asks — the way out at the top of the front screen, or a pull. Both
  /// stay whichever choice is made; this settles the app going on its own, and nothing else.
  manualOnly('manual');

  const Refresh(this.stored);

  /// What goes in the store. Written out rather than an index, so reordering this list cannot
  /// silently change what a phone has already chosen.
  final String stored;

  /// An unwritten or unrecognised choice reads as the default rather than as an error: a settings
  /// row is not worth failing a launch over.
  static Refresh read(String? stored) =>
      values.firstWhere((one) => one.stored == stored, orElse: () => automatic);
}

String refreshWords(Words words, Refresh refresh) => switch (refresh) {
  Refresh.automatic => words.refreshAutomatic,
  Refresh.manualOnly => words.refreshManualOnly,
};

/// Light or dark, or whatever the phone is doing.
enum Appearance {
  system('system', ThemeMode.system),
  light('light', ThemeMode.light),
  dark('dark', ThemeMode.dark);

  const Appearance(this.stored, this.themeMode);

  final String stored;
  final ThemeMode themeMode;

  static Appearance read(String? stored) =>
      values.firstWhere((one) => one.stored == stored, orElse: () => system);
}

String appearanceWords(Words words, Appearance appearance) =>
    switch (appearance) {
      Appearance.system => words.appearanceSystem,
      Appearance.light => words.appearanceLight,
      Appearance.dark => words.appearanceDark,
    };

/// The two choices, together.
@immutable
class ViewerSettings {
  const ViewerSettings({
    this.refresh = Refresh.automatic,
    this.appearance = Appearance.system,
  });

  /// What a phone that has never been to this screen behaves like: go and look without being
  /// asked, and wear what the phone wears.
  static const defaults = ViewerSettings();

  final Refresh refresh;
  final Appearance appearance;

  ViewerSettings copyWith({Refresh? refresh, Appearance? appearance}) =>
      ViewerSettings(
        refresh: refresh ?? this.refresh,
        appearance: appearance ?? this.appearance,
      );

  @override
  bool operator ==(Object other) =>
      other is ViewerSettings &&
      other.refresh == refresh &&
      other.appearance == appearance;

  @override
  int get hashCode => Object.hash(refresh, appearance);
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

  void _change(ViewerSettings next, String key, String stored) {
    if (next == _value) return;
    _keep.write(key, stored);
    _value = next;
    notifyListeners();
  }
}
