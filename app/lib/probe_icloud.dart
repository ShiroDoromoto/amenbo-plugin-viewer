/// A second entrypoint, for one question: does the iCloud Drive folder path hold together?
///
/// ```
/// flutter run -t lib/probe_icloud.dart -d <iPhone>
/// ```
///
/// The parts are off the shelf; the combination is not, so it gets walked by hand on a real
/// device once before the app is built on top of it. Three things have to be true:
///
/// 1. an iCloud Drive folder can be picked
/// 2. it stays readable across an app restart and a device restart, with no second pick
/// 3. a file whose contents are not on the device can still be read
///
/// The first two need a human — one to work the picker, one to kill the app and reboot the
/// phone — so this screen keeps the answer to each visible rather than asserting it. It is not
/// part of the shipped app and nothing imports it.
library;

import 'package:flutter/material.dart';

import 'icloud_folder.dart';

void main() {
  runApp(const ProbeApp());
}

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iCloud folder probe',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
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
  FolderStatus _status = FolderStatus.none;
  List<FolderEntry> _entries = const [];
  final List<String> _log = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Read the status before anything is touched: on a launch after a restart, what it says is
    // the answer to requirement 2.
    _run('status on launch', () async {
      final status = await ICloudFolder.status();
      setState(() => _status = status);
      return status.saved
          ? 'held: ${status.path} (reachable ${status.reachable}, stale ${status.wasStale})'
          : 'no folder held';
    });
  }

  /// Runs one channel call, keeping the outcome — success or failure — in the log.
  Future<void> _run(String label, Future<String> Function() body) async {
    setState(() => _busy = true);
    String line;
    try {
      line = '$label → ${await body()}';
    } catch (error) {
      line = '$label ✗ $error';
    }
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      _busy = false;
    });
  }

  Future<void> _pick() => _run('pick', () async {
        final picked = await ICloudFolder.pick();
        if (picked == null) return 'cancelled';
        setState(() => _status = picked);
        return picked.path ?? '(no path)';
      });

  Future<void> _list() => _run('list', () async {
        final entries = await ICloudFolder.list();
        setState(() => _entries = entries);
        final absent =
            entries.where((e) => e.status == DownloadStatus.notDownloaded).length;
        return '${entries.length} entries, $absent not downloaded';
      });

  Future<void> _read(FolderEntry entry) => _run('read ${entry.name}', () async {
        final read = await ICloudFolder.read(entry.name);
        return '${read.bytes} bytes, '
            '${read.statusBefore.name} → ${read.statusAfter.name}, '
            'head "${read.head.trim()}"';
      });

  Future<void> _forget() => _run('forget', () async {
        await ICloudFolder.forget();
        setState(() {
          _status = FolderStatus.none;
          _entries = const [];
        });
        return 'bookmark dropped';
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('iCloud folder probe'),
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
              FilledButton(onPressed: _busy ? null : _pick, child: const Text('Pick folder')),
              FilledButton.tonal(
                  onPressed: _busy ? null : _list, child: const Text('List')),
              TextButton(onPressed: _busy ? null : _forget, child: const Text('Forget')),
            ],
          ),
          const SizedBox(height: 16),
          if (_entries.isNotEmpty) ...[
            Text('Entries', style: Theme.of(context).textTheme.titleMedium),
            for (final entry in _entries)
              ListTile(
                dense: true,
                leading: Icon(entry.isDirectory ? Icons.folder : Icons.description),
                title: Text(entry.name),
                subtitle: Text('${entry.bytes} B · ${entry.status.name}'
                    '${entry.ubiquitous ? '' : ' · not an iCloud item'}'),
                onTap: entry.isDirectory || _busy ? null : () => _read(entry),
              ),
            const SizedBox(height: 16),
          ],
          Text('Log', style: Theme.of(context).textTheme.titleMedium),
          for (final line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SelectableText(line,
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final FolderStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              status.saved ? 'A folder is held' : 'No folder held',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (status.saved) ...[
              const SizedBox(height: 8),
              SelectableText(status.path ?? '(no path)'),
              Text('reachable ${status.reachable} · rewritten stale ${status.wasStale}'),
            ],
          ],
        ),
      ),
    );
  }
}
