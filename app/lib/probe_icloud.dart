/// A second entrypoint, for one question: does the iCloud path hold together?
///
/// ```
/// flutter run -t lib/probe_icloud.dart -d <iPhone>
/// ```
///
/// The parts are off the shelf; the combination is not, so it gets walked by hand on a real
/// device once before the app is built on top of it. Three things have to be true:
///
/// 1. the app's own container resolves, with nobody picking anything
/// 2. `Documents/` is there afterwards — that is the Mac's write target, and only the app can
///    create it
/// 3. a file whose contents are not on the device can still be read
///
/// The third needs a human — one to write a file on the Mac and leave the phone alone until it
/// is not downloaded — so this screen keeps the answer to each visible rather than asserting it.
/// It is not part of the shipped app and nothing imports it.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'icloud_container.dart';

void main() {
  runApp(const ProbeApp());
}

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iCloud container probe',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: const ProbeScreen(),
    );
  }
}

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  ContainerStatus _status = ContainerStatus.unavailable;
  List<ContainerEntry> _entries = const [];
  final List<String> _log = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Nothing is asked of the person first: a launch with no prior state is the whole of
    // requirements 1 and 2, so both answers are here by the time the screen is drawn, and a
    // launch alone is enough to file a run.
    () async {
      await _statusCheck('status on launch');
      await _list();
      // Requirement 3 needs a file the Mac put there, so it can only be answered on a launch
      // that finds one. Reading the first is enough — they all arrive the same way.
      final file = _entries.where((entry) => !entry.isDirectory).firstOrNull;
      if (file != null) await _read(file);
    }();
  }

  /// Runs one channel call, keeping the outcome — success or failure — in the log.
  ///
  /// Every line is also appended to a file in the app's temporary directory. The phone is where
  /// the answer is read, but a release build says nothing on the Mac's console, and the Mac can
  /// fetch that file over the cable:
  ///
  /// ```
  /// xcrun devicectl device copy from --device <udid> \
  ///   --domain-type appDataContainer --domain-identifier work.amenbo.viewer \
  ///   --source tmp/probe.log --destination .
  /// ```
  Future<void> _run(String label, Future<String> Function() body) async {
    setState(() => _busy = true);
    String line;
    try {
      line = '$label → ${await body()}';
    } catch (error) {
      line = '$label ✗ $error';
    }
    debugPrint('probe: $line');
    try {
      File(
        '${Directory.systemTemp.path}/probe.log',
      ).writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // The screen is the primary report; a log nobody can write to is not worth failing over.
    }
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      _busy = false;
    });
  }

  Future<void> _statusCheck(String label) => _run(label, () async {
    final status = await ICloudContainer.status();
    setState(() => _status = status);
    return status.available
        ? 'available: ${status.path}'
        : 'not available (signed out, or iCloud Drive is off)';
  });

  Future<void> _list() => _run('list', () async {
    final entries = await ICloudContainer.list();
    setState(() => _entries = entries);
    final absent = entries
        .where((e) => e.status == DownloadStatus.notDownloaded)
        .length;
    return '${entries.length} entries, $absent not downloaded';
  });

  Future<void> _read(ContainerEntry entry) =>
      _run('read ${entry.name}', () async {
        final read = await ICloudContainer.read(entry.name);
        return '${read.bytes} bytes, '
            '${read.statusBefore.name} → ${read.statusAfter.name}, '
            'head "${read.head.trim()}"';
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('iCloud container probe'),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(status: _status),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : () => _statusCheck('status'),
                child: const Text('Status'),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : _list,
                child: const Text('List'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_entries.isNotEmpty) ...[
            Text('Entries', style: Theme.of(context).textTheme.titleMedium),
            for (final entry in _entries)
              ListTile(
                dense: true,
                leading: Icon(
                  entry.isDirectory ? Icons.folder : Icons.description,
                ),
                title: Text(entry.name),
                subtitle: Text(
                  '${entry.bytes} B · ${entry.status.name}'
                  '${entry.ubiquitous ? '' : ' · not an iCloud item'}',
                ),
                onTap: entry.isDirectory || _busy ? null : () => _read(entry),
              ),
            const SizedBox(height: 16),
          ],
          Text('Log', style: Theme.of(context).textTheme.titleMedium),
          for (final line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SelectableText(
                line,
                style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final ContainerStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              status.available
                  ? 'The container is here'
                  : 'iCloud is not available',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(status.path ?? 'nothing to read from'),
          ],
        ),
      ),
    );
  }
}
