/// amenbo Viewer — the backlog, on the phone, while you are away from the PC.
///
/// The app reads an encrypted snapshot out of a place its owner holds — a folder in their iCloud
/// Drive, or their own Cloudflare Worker — decrypts it here, and shows it. It never writes back.
///
/// **The app has to be complete on its own.** Store review takes as long as it takes, so there
/// will be users running this build against an amenbo and a plugin that know nothing about it.
/// Nothing here may depend on either one being present, and no state that follows from their
/// absence is an error: an app nobody has paired yet is working correctly.
///
/// Until a route exists, what it shows is [PairingGuideScreen] — the setup instructions, because
/// a fresh install has nothing else it could truthfully show.
library;

import 'package:flutter/material.dart';

import 'pairing_guide.dart';

void main() {
  runApp(const AmenboViewerApp());
}

class AmenboViewerApp extends StatelessWidget {
  const AmenboViewerApp({super.key});

  /// The name the stores show, in both languages — it reads the same in each, so it is not
  /// translated per locale.
  static const title = 'amenbo Viewer';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: title,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: const PairingGuideScreen(appName: title),
    );
  }
}
