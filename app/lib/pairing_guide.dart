/// The first screen anyone sees, and the one they see for as long as no backlog is reaching the
/// phone.
///
/// **Not being paired is a normal state, not a failure.** Someone who has just installed the app
/// has done nothing wrong, and neither has someone whose PC is switched off. So this is not an
/// error and not an empty list — it is the instructions, which is the only thing the app can
/// usefully offer until a route exists.
///
/// The setup happens on the PC, in Amenbo itself; almost nothing here can start it. That is why
/// the screen is mostly steps: **one button, on one card.** Reading the QR code is the whole of
/// this phone's half, and a second button would have to do nothing.
///
/// The one thing the bar carries is the way to what this build is, and it is here because it is
/// nowhere else: the settings are opened from the front screen, and the front screen is what a
/// pairing brings. **Anyone who cannot pair would otherwise never reach the privacy policy** —
/// and that is every reviewer either store sends, since none of them has a PC running Amenbo.
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

import 'about_screen.dart';
import 'l10n/words.dart';
import 'pairing_scan.dart';
import 'pairing_store.dart';
import 'ui/measure.dart';
import 'ui/theme.dart';
import 'ui/tokens.dart';

/// What the card says about the one way a snapshot reaches the phone.
///
/// [who] is who it is for, [cost] is what it asks before it works, and [action] is this phone's
/// whole half of it.
({String name, String who, String cost, List<String> steps, String action})
pairingRouteWords(Words words) => (
  name: words.routeCloudflare,
  who: words.guideCloudflareWho,
  cost: words.guideCloudflareCost,
  steps: [
    words.guideCloudflareStepOne,
    words.guideCloudflareStepTwo,
    words.guideCloudflareStepThree,
  ],
  action: words.guideCloudflareAction,
);

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

    return Scaffold(
      appBar: AppBar(
        title: Text(appName),
        // Not a second way to pair — the way to the one screen that names the privacy policy,
        // for the person who has no way through this one.
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: words.aboutTitle,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AboutScreen(appName: appName)),
            ),
          ),
        ],
      ),
      // The first thing anybody sees is a page of prose, so it stops where every other page of
      // prose in this app stops rather than running the width of a tablet.
      body: Measured.prose(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Space.pageGutter,
            Space.s4,
            Space.pageGutter,
            Space.s7,
          ),
          children: [
            Text(words.guideHeading, style: theme.textTheme.headlineSmall),
            const SizedBox(height: Space.s4),
            Text(words.guideOneRoute, style: theme.textTheme.bodyLarge),
            const SizedBox(height: Space.s6),
            _RouteCard(
              canDo: (
                label: pairingRouteWords(words).action,
                pressed: () => _pair(context),
              ),
            ),
            const SizedBox(height: Space.s6),
            const _Assurance(),
          ],
        ),
      ),
    );
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.canDo});

  /// The card's button — what it says, and what it does.
  final ({String label, VoidCallback pressed}) canDo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final said = pairingRouteWords(Words.of(context));

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
            const SizedBox(height: Space.s3),
            // Left where the steps are, not stretched across the card: it is the last step's
            // other half, not a decision about the whole screen.
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: canDo.pressed,
                child: Text(canDo.label),
              ),
            ),
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
