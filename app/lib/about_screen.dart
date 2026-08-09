/// What this build is — the three answers worth having when something is not behaving.
///
/// The app's own version, the contract version it reads, and the licences of what it is built out
/// of. Nothing is fetched: the licences are the ones Flutter collected at build time, so this
/// screen works with the phone in a tunnel like every other one.
library;

import 'package:flutter/material.dart';

import 'cloudflare_intake.dart';

/// This build's version, as the stores show it.
///
/// It is written here as well as in `pubspec.yaml` because reading it back at runtime would mean
/// carrying a plugin to do it, for one line of text. A test holds the two together.
const appVersion = '1.0.0';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, required this.appName});

  final String appName;

  static const title = 'About';
  static const licences = 'Licences';

  /// Said in full rather than as a number on its own: `spec_v` is the one thing a place and a
  /// phone can disagree about while both are working correctly, and this is where the person
  /// finds out which side is behind.
  static String contractLine(int version) =>
      'Reads version $version of the amenbo snapshot contract. A place writing '
      'any other version needs a different version of this app.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ListTile(title: Text(appName), subtitle: Text('Version $appVersion')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              contractLine(contractVersion),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            title: const Text(licences),
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
