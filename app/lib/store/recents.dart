/// The short memory the search face keeps: the last words typed, and the last records opened.
///
/// It exists because of how this face is actually used — the same question is asked again a day
/// later, from the same half-remembered word. Without it, an empty field is a blank wall every
/// time, and the way back to the thing looked up yesterday is to remember it twice.
///
/// It is the device's own writing, not the place's, so it survives the store being emptied and
/// refilled — see [MetaKey.deviceOwn].
library;

import 'dart:convert';

import 'backlog_store.dart';

/// A record the person opened, small enough to keep by number.
///
/// Only the number is kept. The row itself is read back out of the store when it is shown, so a
/// title that changed on the PC is not remembered wrong, and one that was deleted simply drops
/// off the list.
class Seen {
  const Seen(this.kind, this.id);

  static const task = 'task';
  static const decision = 'decision';

  /// [task] or [decision].
  final String kind;
  final int id;

  @override
  bool operator ==(Object other) =>
      other is Seen && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

extension Recents on BacklogStore {
  /// How many of each are kept. Enough to cover "the thing I was just looking at" and no more —
  /// a longer list stops being a shortcut and becomes something to read.
  static const kept = 5;

  List<String> recentTerms() => _list(MetaKey.recentTerms);

  /// What was opened from the search face, newest first.
  List<Seen> recentlyViewed() =>
      _list(MetaKey.recentlyViewed).map(_seen).nonNulls.toList(growable: false);

  /// Remembers a search that led somewhere.
  ///
  /// The term and the record are written together because that is the moment the term is known to
  /// have been worth typing. Recording every keystroke instead would fill the list with the
  /// prefixes of one word.
  void remember({String? term, Seen? seen}) {
    final word = term?.trim() ?? '';
    if (word.isNotEmpty) {
      _push(MetaKey.recentTerms, word, _list(MetaKey.recentTerms));
    }
    if (seen != null) {
      _push(
        MetaKey.recentlyViewed,
        '${seen.kind}/${seen.id}',
        _list(MetaKey.recentlyViewed),
      );
    }
  }

  void _push(String key, String value, List<String> held) {
    final next = [value, ...held.where((one) => one != value)];
    setMeta(key, jsonEncode(next.take(Recents.kept).toList(growable: false)));
  }

  List<String> _list(String key) {
    final held = meta(key);
    if (held == null) return const [];
    final decoded = jsonDecode(held);
    if (decoded is! List) return const [];
    return decoded.whereType<String>().toList(growable: false);
  }
}

Seen? _seen(String key) {
  final slash = key.lastIndexOf('/');
  if (slash <= 0) return null;
  final id = int.tryParse(key.substring(slash + 1));
  return id == null ? null : Seen(key.substring(0, slash), id);
}
