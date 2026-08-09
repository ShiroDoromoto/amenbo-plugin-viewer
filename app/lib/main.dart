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
import 'settings.dart';
import 'store/backlog_store.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AmenboViewerApp(settings: await openSettings()));
}

/// The settings as this phone last left them.
///
/// Opening the local store is the only thing done before the first frame, and it is a file on the
/// device — nothing is fetched here. Drawing the app in the wrong brightness and correcting it a
/// moment later is a flash the person did not ask for, and the read costs less than the flash.
Future<SettingsController> openSettings() async =>
    SettingsController(StoredSettings(await BacklogStore.open()));

class AmenboViewerApp extends StatelessWidget {
  const AmenboViewerApp({super.key, required this.settings});

  /// Held here rather than looked up, because the one setting the app itself obeys — how dark it
  /// is — is decided at this level and nowhere else.
  final SettingsController settings;

  /// The name the stores show, in both languages — it reads the same in each, so it is not
  /// translated per locale.
  static const title = 'amenbo Viewer';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: title,
        theme: viewerTheme(Brightness.light),
        darkTheme: viewerTheme(Brightness.dark),
        themeMode: settings.value.appearance.themeMode,
        home: const PairingGuideScreen(appName: title),
      ),
    );
  }
}
