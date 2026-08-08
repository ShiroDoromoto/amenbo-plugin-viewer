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
/// # Skeleton
///
/// This is the shell — enough to boot, be tested and be built by CI, and no more. The first
/// screen a user actually meets is its own piece of work.
library;

import 'package:flutter/material.dart';

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
      home: const NotBuiltYetScreen(),
    );
  }
}

/// What stands in until the first real screen is written.
///
/// It says what it is rather than showing a plausible empty backlog: a screen that looked
/// finished would make "no tasks" and "nothing implemented" the same picture, and the whole
/// point of the first screen is to tell a user which of those they are looking at.
class NotBuiltYetScreen extends StatelessWidget {
  const NotBuiltYetScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(AmenboViewerApp.title)),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nothing is built here yet.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
