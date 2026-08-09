/// The connection, as this one phone can describe it and act on it.
///
/// Three things are worth saying here and the rest is noise: where the snapshot is coming from,
/// how old what you are reading is, and how to stop this phone holding a copy. Everything on the
/// screen is one of the three.
///
/// **What is not here is other devices.** Adding and revoking read tokens happens at the writing
/// end, and this app holds one token — its own. A list of the person's phones would be a list
/// nothing on this screen could change.
library;

import 'package:flutter/material.dart';

import 'connection.dart';
import 'pairing_scan.dart';
import 'pairing_store.dart';
import 'ui/time.dart';

/// The connection screen. Pops `true` when the person erased this phone's copy, so whoever pushed
/// it can go back to the guide — there is nothing left to show a backlog from.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key, required this.facts});

  final ConnectionFacts facts;

  static const title = 'Connection';
  static const nothingYet = 'Nothing has arrived yet.';
  static const pairAgain = 'Pair this phone again';
  static const erase = 'Erase this phone\'s copy';
  static const eraseQuestion = 'Erase this phone\'s copy?';
  static const eraseDetail =
      'The backlog kept on this phone and the key that opens it are removed. '
      'Nothing on your PC changes, and you can pair again whenever you like.';

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  Connection? _connection;

  /// Read once when the screen opens and again after pairing, rather than watched. Nothing here
  /// changes while the person is looking at it except by their own hand.
  late Future<void> _reading = _read();

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

  Future<void> _pairAgain() async {
    final paired = await Navigator.of(context).push<Pairing>(
      MaterialPageRoute(builder: (_) => const PairingScanScreen()),
    );
    if (paired == null || !mounted) return;
    setState(() => _reading = _read());
  }

  Future<void> _erase() async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(ConnectionScreen.eraseQuestion),
        content: const Text(ConnectionScreen.eraseDetail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Erase'),
          ),
        ],
      ),
    );
    if (agreed != true) return;

    await widget.facts.erase();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(ConnectionScreen.title)),
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
    final taken = connection.lastTaken;

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        _Fact(
          label: 'Route',
          value: connection.route.words,
          detail: connection.host,
        ),
        if (connection.iCloudAvailable case final available?)
          _Fact(
            label: 'iCloud',
            value: available ? 'Signed in' : 'Not available on this phone',
            detail: available
                ? null
                : 'Sign in to iCloud, and turn on iCloud Drive, in the phone\'s '
                      'settings. There is nothing to choose in this app.',
          ),
        if (taken.isEmpty)
          const _Fact(
            label: 'Last taken',
            value: ConnectionScreen.nothingYet,
            detail: 'The PC writes when there is something to write.',
          )
        else
          TimeOnHold(
            when: taken.at!,
            child: _Fact(
              label: 'Last taken',
              value: relativeTime(taken.at!, now: now),
              detail: [
                if (taken.version case final version?) 'version $version',
                'record ${taken.seq}',
                if (taken.specVersion case final specVersion?)
                  'contract $specVersion',
              ].join(' · '),
            ),
          ),
        const Divider(height: 32),
        if (connection.canPairAgain)
          ListTile(
            title: const Text(ConnectionScreen.pairAgain),
            subtitle: const Text(
              'Reads a fresh code from the PC. The address, the token and the '
              'key are all replaced.',
            ),
            onTap: onPairAgain,
          ),
        ListTile(
          title: Text(
            ConnectionScreen.erase,
            style: TextStyle(color: scheme.error),
          ),
          subtitle: const Text(
            'Removes the backlog kept here and the key that opens it. Nothing '
            'on the PC changes.',
          ),
          onTap: onErase,
        ),
      ],
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: theme.textTheme.bodyLarge),
          if (detail case final detail?) ...[
            const SizedBox(height: 2),
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
