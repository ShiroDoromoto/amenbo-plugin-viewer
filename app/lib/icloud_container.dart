/// The Dart side of the iCloud path.
///
/// iOS only. The work is in [`ios/Runner/ICloudContainerBridge.swift`]; this is the calling side,
/// which turns the channel's maps into types the rest of the app can hold.
library;

import 'package:flutter/services.dart';

/// What iOS says about a file's contents being on the device.
///
/// [notDownloaded] is the state the whole path exists for: the file is listed, has a size, and
/// its bytes are not here. [unknown] means the system does not treat the item as an iCloud item
/// at all.
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

/// Whether the app's iCloud container can be reached.
///
/// [available] false is a normal state, not a failure: the person is signed out of iCloud, or
/// iCloud Drive is off. There is nothing to pick and nothing to repair in the app — the answer
/// lives in the system settings.
class ContainerStatus {
  const ContainerStatus({required this.available, this.path});

  final bool available;

  /// The directory both sides agree on — the container's `Documents/`, which the Mac writes into.
  final String? path;

  static const unavailable = ContainerStatus(available: false);

  factory ContainerStatus.fromMap(Map<Object?, Object?> map) => ContainerStatus(
    available: map['available'] as bool? ?? false,
    path: map['path'] as String?,
  );
}

/// One entry in the container.
class ContainerEntry {
  const ContainerEntry({
    required this.name,
    required this.isDirectory,
    required this.bytes,
    required this.ubiquitous,
    required this.status,
  });

  final String name;
  final bool isDirectory;
  final int bytes;

  /// The item lives in iCloud. False for anything the system does not treat as an iCloud item.
  final bool ubiquitous;
  final DownloadStatus status;

  factory ContainerEntry.fromMap(Map<Object?, Object?> map) => ContainerEntry(
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
/// and came back with bytes is the requirement met. [statusAfter] lags behind the bytes and is
/// often still [DownloadStatus.notDownloaded] right after a read that succeeded.
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

/// The app's own iCloud container, read without anyone choosing anything.
class ICloudContainer {
  const ICloudContainer._();

  static const _channel = MethodChannel('work.amenbo.viewer/icloud_container');

  /// Whether the container resolves, and where it landed.
  ///
  /// Asking is also what creates the directory the Mac writes into, so this is worth calling on
  /// launch even when nothing is going to be read.
  static Future<ContainerStatus> status() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('status');
    return result == null
        ? ContainerStatus.unavailable
        : ContainerStatus.fromMap(result);
  }

  /// Lists one directory of the container through a coordinated read — `Documents/` itself, or
  /// [path] under it. A directory that is not there lists as nothing.
  static Future<List<ContainerEntry>> list({
    String path = '',
    Duration? within,
  }) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('list', {
      'path': path,
      if (within != null) 'seconds': within.inMilliseconds / 1000,
    });
    final entries = result?['entries'] as List<Object?>? ?? const [];
    return entries
        .map((entry) => ContainerEntry.fromMap(entry! as Map<Object?, Object?>))
        .toList(growable: false);
  }

  /// Reads one file whole and hands back its text, or null where there is no such file.
  ///
  /// Waits for iCloud to hand the contents over when the device is not holding them, the same as
  /// [read] does — the difference is that this one is the whole file rather than a first stretch
  /// of it, because a record has to be opened, not glanced at.
  ///
  /// [within] is how long that wait may last. With no network there is nobody to hand the
  /// contents over and the read would otherwise never come back, so it is called off on the iOS
  /// side and comes back as a channel error.
  static Future<String?> readText(String name, {Duration? within}) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'readText',
      {
        'name': name,
        if (within != null) 'seconds': within.inMilliseconds / 1000,
      },
    );
    if (result == null || result['found'] != true) return null;
    return result['text'] as String? ?? '';
  }

  /// Reads one file out of the container, waiting for iCloud to hand over the contents if the
  /// device is not holding them.
  static Future<FileRead> read(String name) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('read', {
      'name': name,
    });
    return FileRead.fromMap(result ?? const {});
  }
}
