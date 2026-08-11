/// The iCloud route: the app's own container, read as if it were the place.
///
/// **On this route the folder is the store.** There is no server keeping a ledger and no cursor to
/// ask from, so a round is a pass over what is there: `meta.json` says which contract the files are
/// written to and which version of the backlog they are a picture of, and `records/<dataset>/<id>`
/// holds one record each, with the row written as it is.
///
/// Three things follow from the folder being the truth rather than a log.
///
/// * **A deletion is a file that is gone.** Nobody could collect tombstones here, so what the
///   device holds and the folder does not is a row the PC has removed, and the pass takes it away.
/// * **Nothing here is sealed.** The folder is this device's own iCloud container, in the reader's
///   own account, guarded the way the local store is — so the rows are written as they are and no
///   key has to reach the phone before a mac and an iPhone can talk. The other route ends up
///   somewhere its owner merely rents, which is why that one is the one with an envelope on it.
/// * **The version is written last, by both sides.** The PC places the records and then names the
///   version; this pass writes the records and then keeps the version. A round cut short leaves the
///   device without the version, so the next one reads the folder again rather than believing it
///   is level on a half a pass.
/// * **Nothing here is a failure worth a red screen.** Not being signed in to iCloud is a state the
///   person can be in without doing anything wrong, and it is reported as the same
///   [IntakeFailure.unreachable] every route reports, with the band above the list saying which of
///   the two it is.
///
/// What it leaves behind is rows in the local store, exactly as the other route does.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'cloudflare_intake.dart';
import 'icloud_container.dart';
import 'store/backlog_store.dart';

/// One entry of the drop, as much of it as the pass cares about.
class DropEntry {
  const DropEntry(this.name, {this.isDirectory = false});

  final String name;
  final bool isDirectory;
}

/// The folder as the intake reads it.
///
/// Named as its own thing so the pass can be walked over a folder written by hand — the iOS side
/// of it is a platform channel, and none of the reasoning below is about iOS.
abstract interface class BacklogDrop {
  /// Whether the folder can be reached at all. False is signed out of iCloud, or iCloud Drive
  /// turned off — a state, not a fault.
  Future<bool> available();

  /// One directory's entries, relative to the drop's root. A directory that is not there is empty.
  ///
  /// [within] is how long the answer may take. Whoever is reading is the one who knows how long a
  /// wait is worth it, so the limit is carried in rather than kept here.
  Future<List<DropEntry>> entriesIn(String path, {Duration? within});

  /// One file's text, or null where there is no such file.
  Future<String?> readText(String path, {Duration? within});
}

/// The drop as it really is: this app's own iCloud container.
class ICloudDrop implements BacklogDrop {
  const ICloudDrop();

  @override
  Future<bool> available() async => (await ICloudContainer.status()).available;

  @override
  Future<List<DropEntry>> entriesIn(String path, {Duration? within}) async =>
      (await ICloudContainer.list(path: path, within: within))
          .map((entry) => DropEntry(entry.name, isDirectory: entry.isDirectory))
          .toList(growable: false);

  @override
  Future<String?> readText(String path, {Duration? within}) =>
      ICloudContainer.readText(path, within: within);
}

/// What the drop's `meta.json` says.
class DropStanding {
  const DropStanding({required this.specVersion, this.version});

  final int specVersion;

  /// Amenbo's own version, as it stood when the files beside it were placed.
  final int? version;
}

/// Reads the iCloud drop and writes what it holds into the local store.
class ICloudIntake {
  ICloudIntake({
    required this.store,
    this.drop = const ICloudDrop(),
    this.timeout = const Duration(seconds: 30),
  });

  final BacklogStore store;
  final BacklogDrop drop;

  /// How long one answer out of the folder may take.
  ///
  /// A file whose contents are not on the device is fetched by the file provider, and with nothing
  /// on the other end of the network there is nobody to fetch it from — the read simply does not
  /// come back. The other route gives up after this long and says the place was not reached; a
  /// reader that waits forever instead is the quietest way this app could break.
  final Duration timeout;

  /// The file naming what the drop as a whole holds. Written last by the PC, so it never claims a
  /// version the files beside it do not carry.
  static const metaName = 'meta.json';

  /// Where the records live, one file each.
  static const recordsDir = 'records';

  /// What a round names when what it could not read was the folder itself rather than anything
  /// inside it.
  static const _container = 'iCloud';

  /// How many records are written at once.
  ///
  /// The version is kept only after the last one, so a batch is not a commit point for the round —
  /// it is how much of a long pass has to be redone when the phone is put away mid-sync.
  static const batch = 100;

  /// Takes everything the folder holds that the device does not, and forgets what it no longer
  /// holds.
  ///
  /// Throws [IntakeException] if the pass could not be finished. Whatever landed before that stays
  /// landed, without the version: the next round reads the folder again from the top.
  ///
  /// [watching] is called once the folder has been counted, and again after each batch is written.
  /// On this route the order it reports is the pass itself — records read out of records found —
  /// because the folder has no order of its own to stand in.
  Future<IntakeReport> run({
    void Function(IntakeProgress reached)? watching,
  }) async {
    if (!await _within(drop.available(), _container)) {
      throw const IntakeException(IntakeFailure.unreachable, at: _container);
    }

    final standing = await readStanding();
    // No meta at all is a folder the PC has not placed anything in yet. The app is paired and
    // working; there is simply nothing there, which the screen says in its own words.
    if (standing == null) {
      return const IntakeReport(
        records: 0,
        pages: 0,
        seq: 0,
        startedOver: false,
      );
    }

    final held = store.heldKeys();
    final local = int.tryParse(store.meta(MetaKey.version) ?? '');
    // Level only when the device already holds the picture that version names. A device that was
    // emptied still carries the number, and reading nothing because of it would leave it blank.
    if (standing.version != null &&
        standing.version == local &&
        held.isNotEmpty) {
      return IntakeReport(
        records: 0,
        pages: 0,
        seq: standing.version!,
        startedOver: false,
      );
    }

    final files = await _walk();
    var records = 0;
    var batches = 0;
    void reached() => watching?.call(
      IntakeProgress(records: records, seq: records, target: files.length),
    );
    reached();

    final waiting = <BacklogChange>[];
    for (final file in files) {
      final change = await _open(file);
      if (change != null) waiting.add(change);
      if (waiting.length < batch) continue;
      store.applyPage(waiting);
      records += waiting.length;
      batches += 1;
      waiting.clear();
      reached();
    }

    // The last write carries three things at once: whatever is left of the records, the rows the
    // folder no longer holds, and the version that says the pass ran to the end.
    final gone = held.difference(files.map((file) => file.key).toSet());
    final closing = <BacklogChange>[
      ...waiting,
      for (final key in gone) ?BacklogChange.fromKey(key),
    ];
    store.applyPage(closing, version: standing.version);
    records += closing.length;
    batches += 1;
    reached();

    store.setMeta(MetaKey.specVersion, '$contractVersion');
    store.setMeta(MetaKey.fetchedAt, DateTime.now().toUtc().toIso8601String());
    return IntakeReport(
      records: records,
      pages: batches,
      seq: standing.version ?? 0,
      startedOver: false,
    );
  }

  /// Waits on one answer out of the folder, and gives up on it the way the other route gives up
  /// on a request.
  ///
  /// Giving up is this side letting go, not the read being called off: iOS is still waiting for a
  /// file provider that may yet answer, and there is no way to say otherwise. What it buys is the
  /// pass ending — with a line the person can act on — rather than a screen that sits there.
  Future<T> _within<T>(Future<T> asked, String what) async {
    try {
      return await asked.timeout(timeout);
    } on TimeoutException {
      throw IntakeException(IntakeFailure.unreachable, at: what);
    } on PlatformException {
      // The iOS side called its own read off, which is the same event seen a moment earlier.
      throw IntakeException(IntakeFailure.unreachable, at: what);
    }
  }

  /// Reads `meta.json`, or null where the drop has never been written into.
  Future<DropStanding?> readStanding() async {
    final said = await _within(
      drop.readText(metaName, within: timeout),
      metaName,
    );
    if (said == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(said);
    } on FormatException {
      throw const IntakeException(IntakeFailure.unreadable, at: metaName);
    }
    if (decoded is! Map<String, Object?>) {
      throw const IntakeException(IntakeFailure.unreadable, at: metaName);
    }
    final specVersion = decoded['spec_v'];
    if (specVersion != contractVersion) {
      throw IntakeException(
        IntakeFailure.tooNew,
        at: metaName,
        placeVersion: specVersion is int ? specVersion : null,
      );
    }
    final version = decoded['version'];
    return DropStanding(
      specVersion: contractVersion,
      version: version is int ? version : null,
    );
  }

  /// Every record file in the drop, with the key its place gives it.
  Future<List<({String key, String path})>> _walk() async {
    final files = <({String key, String path})>[];
    for (final dataset in await _within(
      drop.entriesIn(recordsDir, within: timeout),
      recordsDir,
    )) {
      if (!dataset.isDirectory) continue;
      final within = '$recordsDir/${dataset.name}';
      for (final file in await _within(
        drop.entriesIn(within, within: timeout),
        within,
      )) {
        if (file.isDirectory || !file.name.endsWith('.json')) continue;
        final id = file.name.substring(0, file.name.length - '.json'.length);
        files.add((key: '${dataset.name}/$id', path: '$within/${file.name}'));
      }
    }
    return files;
  }

  /// Opens one record file into the change it asks for, or null where the file has gone away
  /// between being listed and being read — the PC removing a row mid-pass is an ordinary race, and
  /// the next round is what settles it.
  Future<BacklogChange?> _open(({String key, String path}) file) async {
    final said = await _within(
      drop.readText(file.path, within: timeout),
      file.key,
    );
    if (said == null) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(said);
    } on FormatException {
      throw IntakeException(IntakeFailure.unreadable, at: file.key);
    }
    if (decoded is! Map<String, Object?>) {
      throw IntakeException(IntakeFailure.unreadable, at: file.key);
    }

    // The key is written twice — once as the file's place, once in the record — and they have to
    // agree. Nothing here is sealed, so there is no tag refusing a record that was moved: this
    // check is the whole of what says a row is where it says it is.
    final key = decoded['k'];
    if (key != file.key) {
      throw IntakeException(IntakeFailure.unreadable, at: file.key);
    }

    // A deletion is not written here — the file simply goes away — but a route that says it in
    // words is not wrong, and forgetting the row is what it asks for either way.
    if (decoded['op'] == 'del') return BacklogChange.fromKey(file.key);

    final row = decoded['r'];
    if (row is! Map<String, Object?>) {
      throw IntakeException(IntakeFailure.unreadable, at: file.key);
    }
    return BacklogChange.fromKey(file.key, row: row);
  }
}
