/// What this build is — the three answers worth having when something is not behaving.
///
/// The app's own version, the contract version it reads, and the licences of what it is built out
/// of. Nothing is fetched: the licences are the ones Flutter collected at build time, so this
/// screen works with the phone in a tunnel like every other one.
library;

import 'package:flutter/material.dart';

import 'cloudflare_intake.dart';
import 'l10n/words.dart';
import 'ui/tokens.dart';

/// This build's version, as the stores show it.
///
/// It is written here as well as in `pubspec.yaml` because reading it back at runtime would mean
/// carrying a plugin to do it, for one line of text. A test holds the two together.
const appVersion = '1.0.0';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, required this.appName});

  final String appName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = Words.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(words.aboutTitle)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.s7),
        children: [
          ListTile(
            title: Text(appName),
            subtitle: Text(words.appVersion(appVersion)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.s3,
              Space.gutter,
              Space.s5,
            ),
            child: Text(
              words.contractLine(contractVersion),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: Stroke.rule),
          ListTile(
            title: Text(words.licences),
            onTap: () => showLicensePage(
              context: context,
              applicationName: appName,
              applicationVersion: appVersion,
            ),
          ),
        ],
      ),
    );
  }
}
