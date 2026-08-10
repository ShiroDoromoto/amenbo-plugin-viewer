/// Everything the person may change, on one screen that does not scroll far.
///
/// The whole of it is three choices and two ways out — to the connection, and to what this build
/// is. There is nothing here about how the screens are laid out, what a list shows or what order
/// it is in: those are decided once, from what the app is for, and handing them over would leave
/// the person tuning a reader instead of reading.
///
/// Erasing the phone happens two screens in and undoes everything behind this one, so whoever put
/// this screen there has to hear about it: [onErased] where it is a tab that cannot be popped, and
/// otherwise by this screen popping `true`.
library;

import 'package:flutter/material.dart';

import 'about_screen.dart';
import 'connection.dart';
import 'connection_screen.dart';
import 'settings.dart';
import 'ui/tokens.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.connection,
    required this.appName,
    this.onErased,
  });

  final SettingsController settings;

  /// Handed on to the connection screen, which is the only thing here that reads the phone.
  final ConnectionFacts connection;

  final String appName;

  /// Called instead of popping, for the root that shows this as one of three tabs — a tab is not
  /// a route, and popping one would take the whole app off the screen.
  final VoidCallback? onErased;

  static const title = 'Settings';
  static const refreshHeading = 'Go and look';
  static const appearanceHeading = 'Appearance';
  static const doneHeading = 'Finished work stays on the list for';
  static const refreshNote =
      'Automatically means when the app opens and when you come back to it. '
      'It never runs in the background.';

  Future<void> _openConnection(BuildContext context) async {
    final erased = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ConnectionScreen(facts: connection)),
    );
    if (erased != true || !context.mounted) return;
    final erasedHere = onErased;
    if (erasedHere != null) {
      erasedHere();
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final chosen = settings.value;
          return ListView(
            padding: const EdgeInsets.only(bottom: Space.s7),
            children: [
              const _Heading(refreshHeading),
              RadioGroup<Refresh>(
                groupValue: chosen.refresh,
                onChanged: (picked) {
                  if (picked != null) settings.setRefresh(picked);
                },
                child: Column(
                  children: [
                    for (final one in Refresh.values)
                      RadioListTile<Refresh>(
                        value: one,
                        title: Text(one.words),
                      ),
                  ],
                ),
              ),
              const _Note(refreshNote),
              const _Heading(appearanceHeading),
              RadioGroup<Appearance>(
                groupValue: chosen.appearance,
                onChanged: (picked) {
                  if (picked != null) settings.setAppearance(picked);
                },
                child: Column(
                  children: [
                    for (final one in Appearance.values)
                      RadioListTile<Appearance>(
                        value: one,
                        title: Text(one.words),
                      ),
                  ],
                ),
              ),
              const _Heading(doneHeading),
              RadioGroup<DoneWindow>(
                groupValue: chosen.doneWindow,
                onChanged: (picked) {
                  if (picked != null) settings.setDoneWindow(picked);
                },
                child: Column(
                  children: [
                    for (final one in DoneWindow.values)
                      RadioListTile<DoneWindow>(
                        value: one,
                        title: Text(one.words),
                      ),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                title: const Text(ConnectionScreen.title),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openConnection(context),
              ),
              ListTile(
                title: const Text(AboutScreen.title),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AboutScreen(appName: appName),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          Space.s6,
          Space.gutter,
          Space.s1,
        ),
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// The sentence a choice needs to be made once and never revisited.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.s1,
        Space.gutter,
        0,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
