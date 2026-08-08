/// The Dart side of the iCloud Drive folder path.
///
/// iOS only. The work is in [`ios/Runner/ICloudFolderBridge.swift`]; this is the calling side,
/// which turns the channel's maps into types the rest of the app can hold.
library;

import 'package:flutter/services.dart';

/// What iOS says about a file's contents being on the device.
///
/// [notDownloaded] is the state the whole path exists for: the file is listed, has a size, and
/// its bytes are not here. [unknown] means the system does not treat the item as an iCloud item
/// at all — a file in a local folder, for instance.
enum DownloadStatus {
  notDownloaded('NSURLUbiquitousItemDownloadingStatusNotDownloaded'),
  downloaded('NSURLUbiquitousItemDownloadingStatusDownloaded'),
  current('NSURLUbiquitousItemDownloadingStatusCurrent'),
  unknown('unknown');

  const DownloadStatus(this.raw);

  final String raw;

  static DownloadStatus parse(Object? raw) => values.firstWhere(
        (status) => status.raw == raw,
        orElse: () => DownloadStatus.unknown,
      );
}

/// Whether a folder is being held, and which one.
class FolderStatus {
  const FolderStatus({
    required this.saved,
    this.path,
    this.name,
    this.wasStale = false,
    this.reachable = false,
  });

  /// A bookmark is stored. This is what survives a restart; [reachable] is whether it still
  /// resolves to something the app may read.
  final bool saved;
  final String? path;
  final String? name;

  /// iOS reported the bookmark as stale and it was rewritten. Normal after the folder moves or
  /// the app is updated — not a failure.
  final bool wasStale;
  final bool reachable;

  static const none = FolderStatus(saved: false);

  factory FolderStatus.fromMap(Map<Object?, Object?> map) => FolderStatus(
        saved: map['saved'] as bool? ?? false,
        path: map['path'] as String?,
        name: map['name'] as String?,
        wasStale: map['wasStale'] as bool? ?? false,
        reachable: map['reachable'] as bool? ?? false,
      );
}

/// One entry in the chosen folder.
class FolderEntry {
  const FolderEntry({
    required this.name,
    required this.isDirectory,
    required this.bytes,
    required this.ubiquitous,
    required this.status,
  });

  final String name;
  final bool isDirectory;
  final int bytes;

  /// The item lives in iCloud. False for anything the picker reached outside it.
  final bool ubiquitous;
  final DownloadStatus status;

  factory FolderEntry.fromMap(Map<Object?, Object?> map) => FolderEntry(
        name: map['name'] as String? ?? '',
        isDirectory: map['isDirectory'] as bool? ?? false,
        bytes: map['bytes'] as int? ?? 0,
        ubiquitous: map['ubiquitous'] as bool? ?? false,
        status: DownloadStatus.parse(map['status']),
      );
}

/// The result of reading one file, with the download status on either side of the read.
///
/// [statusBefore] is the interesting half: a read that started at [DownloadStatus.notDownloaded]
/// and came back with bytes is the third requirement met. [statusAfter] lags behind the bytes and
/// is often still [DownloadStatus.notDownloaded] right after a read that succeeded.
class FileRead {
  const FileRead({
    required this.name,
    required this.bytes,
    required this.head,
    required this.statusBefore,
    required this.statusAfter,
  });

  final String name;
  final int bytes;

  /// The first stretch of the file, decoded as UTF-8 — enough to see that the bytes are the
  /// file's own and not an empty placeholder.
  final String head;
  final DownloadStatus statusBefore;
  final DownloadStatus statusAfter;

  factory FileRead.fromMap(Map<Object?, Object?> map) => FileRead(
        name: map['name'] as String? ?? '',
        bytes: map['bytes'] as int? ?? 0,
        head: map['head'] as String? ?? '',
        statusBefore: DownloadStatus.parse(map['statusBefore']),
        statusAfter: DownloadStatus.parse(map['statusAfter']),
      );
}

/// A folder in iCloud Drive the user picked once, read as often as needed afterwards.
class ICloudFolder {
  const ICloudFolder._();

  static const _channel = MethodChannel('work.amenbo.viewer/icloud_folder');

  /// Shows the system folder picker. Returns null if the user backed out.
  ///
  /// Called once. Everything after this goes through the stored bookmark.
  static Future<FolderStatus?> pick() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('pick');
    if (result == null) return null;
    return FolderStatus.fromMap(result);
  }

  static Future<FolderStatus> status() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('status');
    return result == null ? FolderStatus.none : FolderStatus.fromMap(result);
  }

  /// Lists the folder through a coordinated read.
  static Future<List<FolderEntry>> list() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('list');
    final entries = result?['entries'] as List<Object?>? ?? const [];
    return entries
        .map((entry) => FolderEntry.fromMap(entry! as Map<Object?, Object?>))
        .toList(growable: false);
  }

  /// Reads one file out of the folder, waiting for iCloud to hand over the contents if the
  /// device is not holding them.
  static Future<FileRead> read(String name) async {
    final result =
        await _channel.invokeMethod<Map<Object?, Object?>>('read', {'name': name});
    return FileRead.fromMap(result ?? const {});
  }

  /// Drops the bookmark. The next read needs a fresh [pick].
  static Future<void> forget() => _channel.invokeMethod<void>('forget');
}
