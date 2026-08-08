/// The first screen anyone sees, and the one they see for as long as no backlog is reaching the
/// phone.
///
/// **Not being paired is a normal state, not a failure.** Someone who has just installed the app
/// has done nothing wrong, and neither has someone whose PC is switched off. So this is not an
/// error and not an empty list — it is the instructions, which is the only thing the app can
/// usefully offer until a route exists.
///
/// The setup happens on the PC, in amenbo itself; nothing here can start it. That is why the
/// screen carries steps rather than buttons: the one action the app will own — picking the iCloud
/// folder, reading the QR code — arrives with the route it belongs to, and a button that did
/// nothing would be worse than no button.
///
/// It knows nothing about the contract. No snapshot format, no cipher, no QR payload. That is
/// deliberate: it means this screen is finished while the other three parts are not, which is the
/// same property the release needs — the app has to stand on its own.
library;

import 'package:flutter/material.dart';

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
  });

  final String name;

  /// Who this route is for. The two are not ranked by quality — they are picked by what the
  /// person already owns.
  final String who;

  /// What it asks of the person before it works. The iCloud route asks nothing, and saying so is
  /// most of why someone would choose it.
  final String cost;
  final List<String> steps;

  /// mac and iPhone. iOS only — no other provider hands a folder to the picker, and Android has
  /// no equivalent at all.
  static const iCloud = PairingRoute(
    name: 'iCloud Drive',
    who: 'A Mac and an iPhone, both signed in to the same iCloud.',
    cost: 'Nothing to sign up for.',
    steps: [
      'In amenbo on your Mac, turn on the iCloud route and pick a folder.',
      'Come back here and pick that same folder.',
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
  );

  /// What the phone in hand can actually do.
  static List<PairingRoute> forPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.iOS ? const [iCloud, cloudflare] : const [cloudflare];
}

class PairingGuideScreen extends StatelessWidget {
  const PairingGuideScreen({super.key, required this.appName});

  /// Handed down rather than read back out of the app, so the screen stays a screen and the
  /// product name keeps one home.
  final String appName;

  static const heading = 'No backlog is reaching this phone yet.';

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
            _RouteCard(route: route),
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
  const _RouteCard({required this.route});

  final PairingRoute route;

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
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < route.steps.length; i++)
              _Step(number: i + 1, text: route.steps[i]),
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
            child: Text('$number.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline)),
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
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      ],
    );
  }
}
