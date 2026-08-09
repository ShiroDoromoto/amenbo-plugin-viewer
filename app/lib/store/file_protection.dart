/// Asking iOS to keep the store unreadable while the phone is locked.
///
/// The decrypted backlog is kept in the clear on the device — decrypting on every read would mean
/// decrypting everything anyway, for any list, sort or search, so the thing guarded is the key,
/// not each row. What is left to say is who may read the file, and on iOS that is a file
/// attribute: `NSFileProtectionComplete` makes the contents unreadable until the person unlocks
/// the phone.
///
/// It is affordable because of when the app reads: at launch and on coming to the front, both of
/// which happen with the phone unlocked. Nothing here runs in the background.
///
/// Android has no equivalent to ask for. The file sits in the app's private storage, which the
/// system encrypts with the device, so the call is skipped rather than faked.
library;

import 'dart:io';

import 'package:flutter/services.dart';

class FileProtection {
  const FileProtection._();

  static const _channel = MethodChannel('work.amenbo.viewer/file_protection');

  /// Marks [path] — and the journal files SQLite keeps beside it — as readable only while
  /// unlocked.
  ///
  /// Returns false where there is nothing to ask for. A failure to apply it is not raised: the
  /// app is still usable and still holds nothing but a copy, and refusing to open the backlog
  /// over a file attribute would trade the whole app for a hardening step.
  static Future<bool> completeFor(String path) async {
    if (!Platform.isIOS) return false;
    try {
      final applied = await _channel.invokeMethod<bool>('protect', {
        'path': path,
      });
      return applied ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
