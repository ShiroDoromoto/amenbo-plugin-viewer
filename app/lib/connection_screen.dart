/// The connection, as this one phone can describe it and act on it.
///
/// Four things are worth saying here and the rest is noise: what this phone is called, where the
/// snapshot is coming from, how old what you are reading is, and how to stop this phone holding a
/// copy. Everything on the screen is one of the four.
///
/// **What is not here is other devices.** Adding and revoking read tokens happens at the writing
/// end, and this app holds one token — its own. A list of the person's phones would be a list
/// nothing on this screen could change. The name is the one part of that list this phone can
/// answer for, and it is here because cutting a phone off is done by name: without it the person
/// is at the PC choosing between rows with no way to tell which is the phone in their hand.
library;

import 'package:flutter/material.dart';

import 'connection.dart';
import 'l10n/words.dart';
import 'pairing_scan.dart';
import 'pairing_store.dart';
import 'ui/measure.dart';
import 'ui/time.dart';
import 'ui/tokens.dart';

/// The connection screen. Pops a [ConnectionOutcome] when the person did one of the two things
/// on it that the root has to act on, and nothing at all when they only looked.
/// What was done on the connection screen, for whoever pushed it.
///
/// Both close the screen, and what has to happen next is opposite. An erased phone has nothing
/// left to read from, so the root goes back to the guide. A phone that has just read a fresh code
/// has a whole backlog waiting at the other end, and fetching it is the root's round to run.
/// Saying which of the two happened is what keeps the root from guessing.
sealed class ConnectionOutcome {
  const ConnectionOutcome();
}

/// The copy on this phone is gone, and the way in with it.
final class CopyErased extends ConnectionOutcome {
  const CopyErased();
}

/// A fresh code was read and kept. **Nothing has been fetched with it yet** — the token in hand
/// answers nobody until somebody asks, which is the round the root runs on the way back.
final class PairedAgain extends ConnectionOutcome {
  const PairedAgain(this.pairing);

  final Pairing pairing;
}

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({
    super.key,
    required this.facts,
    this.camera = const LiveCamera(),
  });

  final ConnectionFacts facts;

  /// Handed on to the scanning screen, and here for the reason it is there: nothing can point a
  /// real camera at a code, so what happens after one is read is only reachable with a stand-in.
  final Camera camera;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  Connection? _connection;

  /// Read once, when the screen opens, rather than watched. Nothing here changes while the
  /// person is looking at it: the two things they can do from here both close the screen.
  late final Future<void> _reading = _read();

  /// When the screen was drawn. Held still so the times on it agree with each other.
  DateTime _now = DateTime.now();

  Future<void> _read() async {
    final connection = await widget.facts.read();
    if (!mounted) return;
    setState(() {
      _connection = connection;
      _now = DateTime.now();
    });
  }

  /// A fresh code, from the screen this phone's name is on.
  ///
  /// Reading it is half of re-pairing: the new token fetches nothing until a round asks with it.
  /// So the screen closes on what it read and the root runs that round, the same way the band's
  /// own button ends. Staying open would leave the person looking at a "last taken" from before
  /// the code they just read — the screen saying the re-pairing had not worked.
  Future<void> _pairAgain() async {
    final paired = await Navigator.of(context).push<Pairing>(
      MaterialPageRoute(
        builder: (_) => PairingScanScreen(camera: widget.camera),
      ),
    );
    if (paired == null || !mounted) return;
    Navigator.of(context).pop(PairedAgain(paired));
  }

  Future<void> _erase() async {
    final words = Words.of(context);
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(words.eraseQuestion),
        content: Text(words.eraseDialogDetail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(words.keepIt),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(words.eraseConfirm),
          ),
        ],
      ),
    );
    if (agreed != true) return;

    await widget.facts.erase();
    if (!mounted) return;
    Navigator.of(context).pop(const CopyErased());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(Words.of(context).connectionTitle)),
      body: FutureBuilder<void>(
        future: _reading,
        builder: (context, _) {
          final connection = _connection;
          // Reading the keychain and the store takes no perceptible time, so an empty frame is
          // shown rather than a spinner that would flash and go.
          if (connection == null) return const SizedBox.shrink();
          return _Details(
            connection: connection,
            now: _now,
            onPairAgain: _pairAgain,
            onErase: _erase,
          );
        },
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({
    required this.connection,
    required this.now,
    required this.onPairAgain,
    required this.onErase,
  });

  final Connection connection;
  final DateTime now;
  final VoidCallback onPairAgain;
  final VoidCallback onErase;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final words = Words.of(context);
    final taken = connection.lastTaken;

    return Measured.prose(
      child: ListView(
        padding: const EdgeInsets.only(bottom: Space.s7),
        children: [
          if (connection.label case final named?)
            _Fact(
              label: words.thisPhone,
              value: named,
              detail: words.thisPhoneDetail,
            ),
          _Fact(
            label: words.factRoute,
            // A phone with no pairing has rows and no place they came from that this build can
            // still reach, and naming one anyway would be the screen answering for a route that
            // is not there.
            value: connection.paired ? words.routeCloudflare : words.routeNone,
            detail: connection.host,
          ),
          if (taken.isEmpty)
            _Fact(
              label: words.factLastTaken,
              value: words.nothingArrivedYet,
              detail: words.nothingArrivedYetDetail,
            )
          else
            TimeOnHold(
              when: taken.at!,
              child: _Fact(
                label: words.factLastTaken,
                value: relativeTime(TimeFace.of(context), taken.at!, now: now),
                detail: [
                  if (taken.version case final version?)
                    words.lastTakenVersion(version),
                  words.lastTakenRecord(taken.seq),
                  if (taken.specVersion case final specVersion?)
                    words.lastTakenContract(specVersion),
                ].join(' · '),
              ),
            ),
          const Divider(),
          ListTile(
            title: Text(words.pairAgainTitle),
            subtitle: Text(words.pairAgainDetail),
            onTap: onPairAgain,
          ),
          ListTile(
            title: Text(words.erase, style: TextStyle(color: scheme.error)),
            subtitle: Text(words.eraseDetail),
            onTap: onErase,
          ),
        ],
      ),
    );
  }
}

/// One line of the account: what it is, what it says, and — where the plain answer is not enough
/// on its own — the sentence that makes it actionable.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.gutter,
        vertical: Space.s4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Space.hair),
          Text(value, style: theme.textTheme.bodyLarge),
          if (detail case final detail?) ...[
            const SizedBox(height: Space.hair),
            Text(
              detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
