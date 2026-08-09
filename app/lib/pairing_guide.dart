/// The first screen anyone sees, and the one they see for as long as no backlog is reaching the
/// phone.
///
/// **Not being paired is a normal state, not a failure.** Someone who has just installed the app
/// has done nothing wrong, and neither has someone whose PC is switched off. So this is not an
/// error and not an empty list — it is the instructions, which is the only thing the app can
/// usefully offer until a route exists.
///
/// The setup happens on the PC, in amenbo itself; almost nothing here can start it. That is why
/// the screen is mostly steps: **one button, on one card.** Reading the QR code is the whole of
/// this phone's half of the Cloudflare route, and the iCloud route has no half at all — the phone
/// held up its end by having been opened once. A second button would have to do nothing.
///
/// What follows a pairing is not decided here. This screen has said everything it has to say the
/// moment the phone has one, and which screen replaces it is the root's judgement.
///
/// It knows nothing about the contract. No snapshot format, no cipher, no QR payload — the code
/// is read by the screen it pushes and comes back as a pairing. That is deliberate: it means this
/// screen is finished while the other three parts are not, which is the same property the release
/// needs — the app has to stand on its own.
library;

import 'package:flutter/material.dart';

import 'pairing_scan.dart';
import 'pairing_store.dart';

/// One of the two ways a snapshot reaches the phone.
///
/// They differ only in where the file sits. What is carried, how it is encrypted, that it goes
/// one way and that each snapshot replaces the last are the same either way.
class PairingRoute {
  const PairingRoute({
    required this.name,
    required this.who,
    required this.cost,
    required this.steps,
    this.action,
  });

  final String name;

  /// Who this route is for. The two are not ranked by quality — they are picked by what the
  /// person already owns.
  final String who;

  /// What it asks of the person before it works. The iCloud route asks nothing, and saying so is
  /// most of why someone would choose it.
  final String cost;
  final List<String> steps;

  /// The one thing this phone can do about the route, or null where there is nothing to do. A
  /// route whose whole setup is on the PC gets no button: one that did nothing would read as the
  /// app being broken rather than as the person's next step being elsewhere.
  final String? action;

  /// mac and iPhone. iOS only — the place both ends meet is this app's own iCloud container, and
  /// Android has no equivalent at all.
  static const iCloud = PairingRoute(
    name: 'iCloud Drive',
    who: 'A Mac and an iPhone, both signed in to the same iCloud.',
    cost: 'Nothing to sign up for.',
    steps: [
      'In amenbo on your Mac, turn on the iCloud route.',
      'Nothing to do on this phone. Opening the app is what made the place to write to.',
    ],
  );

  /// Everything else. It costs an account, which is the price of not being on Apple's two
  /// machines.
  static const cloudflare = PairingRoute(
    name: 'Your own Cloudflare',
    who: 'Any other combination of PC and phone.',
    cost: 'A Cloudflare account, free of charge.',
    steps: [
      'In amenbo on your PC, set up the Worker. It does the work; you press and paste.',
      'Scan the QR code it shows you with this app.',
    ],
    action: 'Scan the QR code',
  );

  /// What the phone in hand can actually do.
  static List<PairingRoute> forPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.iOS
      ? const [iCloud, cloudflare]
      : const [cloudflare];
}

class PairingGuideScreen extends StatelessWidget {
  const PairingGuideScreen({
    super.key,
    required this.appName,
    required this.onPaired,
    this.readACode = scanForACode,
  });

  /// Handed down rather than read back out of the app, so the screen stays a screen and the
  /// product name keeps one home.
  final String appName;

  /// Called the moment this phone has a pairing. The screen does not decide what follows — it has
  /// nothing left to say once a route exists, and choosing the screen that replaces it is the
  /// root's judgement, not this one's.
  final ValueChanged<Pairing> onPaired;

  /// How a code gets read. The default opens the camera; a test hands back an answer.
  final Future<Pairing?> Function(BuildContext context) readACode;

  static const heading = 'No backlog is reaching this phone yet.';

  /// The scanning screen, which saves the pairing itself and hands it back on the way out.
  static Future<Pairing?> scanForACode(BuildContext context) => Navigator.of(
    context,
  ).push<Pairing>(MaterialPageRoute(builder: (_) => const PairingScanScreen()));

  Future<void> _pair(BuildContext context) async {
    final pairing = await readACode(context);
    if (pairing != null) onPaired(pairing);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Read off the theme rather than dart:io, so the Android screen can be looked at on a Mac and
    // both are reachable from a test.
    final routes = PairingRoute.forPlatform(theme.platform);

    return Scaffold(
      appBar: AppBar(title: Text(appName)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(heading, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(
            routes.length > 1
                ? 'Set up either route on the PC that runs amenbo, and your tasks turn up here.'
                : 'Set this up on the PC that runs amenbo, and your tasks turn up here.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          for (final route in routes) ...[
            _RouteCard(route: route, onAction: () => _pair(context)),
            const SizedBox(height: 16),
          ],
          const SizedBox(height: 8),
          const _Assurance(),
        ],
      ),
    );
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.route, required this.onAction});

  final PairingRoute route;

  /// What the card's button does, where the route has one.
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(route.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(route.who, style: theme.textTheme.bodyMedium),
            Text(
              route.cost,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < route.steps.length; i++)
              _Step(number: i + 1, text: route.steps[i]),
            if (route.action case final action?) ...[
              const SizedBox(height: 8),
              // Left where the steps are, not stretched across the card: it is the last step's
              // other half, not a decision about the whole screen.
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(onPressed: onAction, child: Text(action)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '$number.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// The one thing worth saying on a screen that is asking someone to connect their task list to
/// their phone.
class _Assurance extends StatelessWidget {
  const _Assurance();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline, size: 18, color: theme.colorScheme.outline),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Either way, the snapshot goes to a place you own and nowhere else. '
            'This app only reads it, and never writes anything back.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      ],
    );
  }
}
