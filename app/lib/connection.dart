/// What this one phone's connection is, read off the phone itself.
///
/// **It is one device's account of itself and nothing else.** The other phones the person has
/// paired are not listed and could not be acted on from here anyway: a read token is added and
/// revoked at the writing end, and this app only ever holds one. A list of devices with no way to
/// cut any of them off would be a screen of buttons that do not press.
///
/// The screen is handed a [Connection] rather than reaching for these things itself, so what it
/// draws can be walked without a keychain, a database or an iCloud account anywhere near it.
library;

import 'icloud_container.dart';
import 'l10n/words.dart';
import 'pairing_store.dart';
import 'settings.dart';
import 'store/backlog_store.dart';

/// Which of the two ways a snapshot reaches this phone.
enum ConnectionRoute {
  /// The app's own iCloud container. iPhone only, and it holds no secret this device chose — so
  /// there is nothing here to pair again and nothing to revoke.
  iCloud,

  /// The person's own Worker, reached with the token and key the QR code carried.
  cloudflare,
}

String connectionRouteWords(Words words, ConnectionRoute route) =>
    switch (route) {
      ConnectionRoute.iCloud => words.routeICloud,
      ConnectionRoute.cloudflare => words.routeCloudflare,
    };

/// The last thing the app managed to take from the place.
///
/// [at] is the one that answers "how old is what I am reading", which is the question a phone
/// with no signal is actually asking. The rest is there for the times the answer is that the two
/// ends disagree.
class LastTaken {
  const LastTaken({this.at, this.version, this.seq = 0, this.specVersion});

  /// When the last round of the intake finished, or null if none ever has.
  final DateTime? at;

  /// Amenbo's own version, as it stood in the last record written.
  final int? version;

  /// How far down the order this device has read.
  final int seq;

  /// The contract version those records were written under.
  final int? specVersion;

  /// Nothing has ever arrived. Paired is not the same as fed.
  bool get isEmpty => at == null;

  static LastTaken fromStore(BacklogStore store) => LastTaken(
    at: DateTime.tryParse(store.meta(MetaKey.fetchedAt) ?? ''),
    version: int.tryParse(store.meta(MetaKey.version) ?? ''),
    seq: store.seq,
    specVersion: int.tryParse(store.meta(MetaKey.specVersion) ?? ''),
  );
}

/// Everything the connection screen draws, as it stood when the screen opened.
class Connection {
  const Connection({
    required this.route,
    this.label,
    this.host,
    this.iCloudAvailable,
    this.taking = true,
    this.lastTaken = const LastTaken(),
  });

  final ConnectionRoute route;

  /// Whether the route named above is one this phone is still taking from. False only where the
  /// person switched the iCloud route off: what runs is the declaration and the container
  /// together, so a route the person has said no to is not where anything is coming from, and a
  /// screen that named it anyway would be answering with half the product.
  final bool taking;

  /// What the PC calls this phone. It is the name a read token is cut off by, so showing it is
  /// what lets the person match the phone in their hand against the rows on the PC. Null off the
  /// Cloudflare route, and on a pairing made before the code carried a name.
  final String? label;

  /// The Worker's host, on the Cloudflare route. The host alone: the token and the key on the same
  /// URL are the pairing itself, and a screen is a thing people photograph.
  final String? host;

  /// Whether the app's iCloud container resolves. Null off the iCloud route, where it is not a
  /// fact about this phone's connection at all.
  final bool? iCloudAvailable;

  final LastTaken lastTaken;

  /// Pairing again is the Cloudflare route's move — reading a fresh code swaps the URL, the token
  /// and the key together. The iCloud route was never given any of the three.
  bool get canPairAgain => route == ConnectionRoute.cloudflare;
}

/// The phone's own account of itself, and the one way to end it.
abstract interface class ConnectionFacts {
  /// Reads the connection as it stands. Called when the screen opens and again after pairing.
  Future<Connection> read();

  /// Drops what this device holds: the decrypted rows, the key that opens them, and — on a phone
  /// that could read the folder — the route that would put them back.
  ///
  /// Nothing is said to the place — it belongs to the person, not to this phone, and the PC goes
  /// on writing to it. What this undoes is only this phone having a copy.
  Future<void> erase();
}

/// The real phone.
class PhoneConnection implements ConnectionFacts {
  const PhoneConnection({
    required this.store,
    required this.settings,
    this.pairings = const PairingStore(),
    this.hasICloud = false,
  });

  final BacklogStore store;

  /// Read for nothing and written to once: erasing this phone's copy takes the iCloud route down
  /// with it. The Cloudflare route ends by itself when the pairing goes.
  final SettingsController settings;

  final PairingStore pairings;

  /// Whether this build is running somewhere with an iCloud container — iOS. Passed in rather
  /// than read from `dart:io`, so the Android answer is reachable from a Mac.
  final bool hasICloud;

  @override
  Future<Connection> read() async {
    final pairing = await pairings.read();
    final lastTaken = LastTaken.fromStore(store);

    // A pairing is the phone having been pointed at a Worker on purpose, so it settles the
    // question on a phone that could also read a container. The container is where the route
    // lands when nothing was ever set up here, which is the whole of what the iCloud route asks.
    if (pairing != null) {
      return Connection(
        route: ConnectionRoute.cloudflare,
        label: pairing.label,
        host: pairing.url.host,
        lastTaken: lastTaken,
      );
    }
    final taking = settings.value.iCloud.isOn;
    return Connection(
      route: ConnectionRoute.iCloud,
      // Not asked while nobody is taking from it, and not answered either: whether iCloud is
      // signed in says nothing about a route that is switched off, and "not available on this
      // phone" would be read as the reason nothing is arriving.
      iCloudAvailable: taking
          ? hasICloud && (await ICloudContainer.status()).available
          : null,
      taking: taking,
      lastTaken: lastTaken,
    );
  }

  @override
  Future<void> erase() async {
    await pairings.forget();
    store.wipe();
    // A pairing is thrown away with the rows, and that is the end of the Cloudflare route. The
    // iCloud route was never given anything to throw away — the folder is the Mac's, and the
    // phone reads it for having been opened once — so without this the rows would be back on the
    // next launch, which is the person watching what they erased come straight back.
    if (hasICloud) settings.setICloud(TakeFromICloud.off);
  }
}
