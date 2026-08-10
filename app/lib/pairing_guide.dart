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

import 'l10n/words.dart';
import 'pairing_scan.dart';
import 'pairing_store.dart';
import 'ui/theme.dart';
import 'ui/tokens.dart';

/// One of the two ways a snapshot reaches the phone.
///
/// They differ only in where the file sits. What is carried, how it is encrypted, that it goes
/// one way and that each snapshot replaces the last are the same either way.
enum PairingRoute {
  /// mac and iPhone. iOS only — the place both ends meet is this app's own iCloud container, and
  /// Android has no equivalent at all.
  iCloud,

  /// Everything else. It costs an account, which is the price of not being on Apple's two
  /// machines.
  cloudflare;

  /// What the phone in hand can actually do.
  static List<PairingRoute> forPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.iOS
      ? const [iCloud, cloudflare]
      : const [cloudflare];
}

/// What a card says about a route.
///
/// [who] is who it is for — the two are not ranked by quality, they are picked by what the person
/// already owns. [cost] is what it asks before it works, and the iCloud route asking nothing is
/// most of why somebody would choose it. [action] is the one thing this phone can do about the
/// route, and it is null where there is nothing to do: a button that did nothing would read as
/// the app being broken rather than as the person's next step being elsewhere.
({String name, String who, String cost, List<String> steps, String? action})
pairingRouteWords(Words words, PairingRoute route) => switch (route) {
  PairingRoute.iCloud => (
    name: words.routeICloud,
    who: words.guideICloudWho,
    cost: words.guideICloudCost,
    steps: [words.guideICloudStepOne, words.guideICloudStepTwo],
    action: null,
  ),
  PairingRoute.cloudflare => (
    name: words.routeCloudflare,
    who: words.guideCloudflareWho,
    cost: words.guideCloudflareCost,
    steps: [words.guideCloudflareStepOne, words.guideCloudflareStepTwo],
    action: words.guideCloudflareAction,
  ),
};

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
    final words = Words.of(context);
    // Read off the theme rather than dart:io, so the Android screen can be looked at on a Mac and
    // both are reachable from a test.
    final routes = PairingRoute.forPlatform(theme.platform);

    return Scaffold(
      appBar: AppBar(title: Text(appName)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Space.pageGutter,
          Space.s4,
          Space.pageGutter,
          Space.s7,
        ),
        children: [
          Text(words.guideHeading, style: theme.textTheme.headlineSmall),
          const SizedBox(height: Space.s4),
          Text(
            routes.length > 1 ? words.guideBothRoutes : words.guideOneRoute,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: Space.s6),
          for (final route in routes) ...[
            _RouteCard(route: route, onAction: () => _pair(context)),
            const SizedBox(height: Space.s5),
          ],
          const SizedBox(height: Space.s3),
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
    final said = pairingRouteWords(Words.of(context), route);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.pageGutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(said.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: Space.s3),
            Text(said.who, style: theme.textTheme.bodyMedium),
            Text(
              said.cost,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: Space.s5),
            for (var i = 0; i < said.steps.length; i++)
              _Step(number: i + 1, text: said.steps[i]),
            if (said.action case final action?) ...[
              const SizedBox(height: Space.s3),
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
      padding: const EdgeInsets.only(bottom: Space.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: Layout.stepNumber,
            child: Text(
              '$number.',
              // Quieter than the step it numbers: the number is a place-keeper, and the sentence
              // beside it is the thing to read.
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette(context).textFaint,
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
        Icon(
          Icons.lock_outline,
          size: (theme.textTheme.bodyMedium?.fontSize ?? Lettering.md) * 1.2,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: Space.s4),
        Expanded(
          child: Text(
            Words.of(context).guideAssurance,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
