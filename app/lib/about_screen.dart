/// What this build is — the four answers worth having when something is not behaving.
///
/// The app's own version, where the copy came from, the contract version it reads, and the
/// licences of what it is built out of. Nothing is fetched: the origin is read off the phone and
/// the licences are the ones Flutter collected at build time, so this screen works with the phone
/// in a tunnel like every other one.
library;

import 'package:flutter/material.dart';

import 'build_origin.dart';
import 'cloudflare_intake.dart';
import 'l10n/words.dart';
import 'ui/tokens.dart';

/// This build's version, as the stores show it.
///
/// It is written here as well as in `pubspec.yaml` because reading it back at runtime would mean
/// carrying a plugin to do it, for one line of text. A test holds the two together.
const appVersion = '1.0.0';

class AboutScreen extends StatefulWidget {
  const AboutScreen({
    super.key,
    required this.appName,
    this.readOrigin = BuildOrigin.read,
  });

  final String appName;

  /// How the origin is asked for. The phone answers by default; a test hands its own answer in,
  /// the same way it would on a machine where there is no phone to ask.
  final Future<BuildOrigin> Function() readOrigin;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  /// Null until the phone has answered. The line is left out rather than filled with a guess —
  /// the answer arrives in the time it takes to look at a file name, and a screen that said
  /// "not known" first and corrected itself would be reporting the wait, not the build.
  BuildOrigin? _origin;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final origin = await widget.readOrigin();
    if (!mounted) return;
    setState(() => _origin = origin);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = Words.of(context);
    final origin = _origin;

    return Scaffold(
      appBar: AppBar(title: Text(words.aboutTitle)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.s7),
        children: [
          ListTile(
            title: Text(widget.appName),
            subtitle: Text(words.appVersion(appVersion)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.s3,
              Space.gutter,
              Space.s5,
            ),
            child: DefaultTextStyle.merge(
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: Space.s3,
                children: [
                  if (origin != null) Text(buildOriginWords(words, origin)),
                  Text(words.contractLine(contractVersion)),
                ],
              ),
            ),
          ),
          const Divider(height: Stroke.rule),
          ListTile(
            title: Text(words.licences),
            onTap: () => showLicensePage(
              context: context,
              applicationName: widget.appName,
              applicationVersion: appVersion,
            ),
          ),
        ],
      ),
    );
  }
}
