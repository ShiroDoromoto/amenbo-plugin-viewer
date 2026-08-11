/// Where the copy on this phone came from.
///
/// A build handed out for testing and the one on the store carry the same identifier, the same
/// icon and the same version — so nothing about them on the screen tells them apart, and on iOS
/// nothing can: the two are the same app, differing only in how they were delivered. The delivery
/// is what each platform still remembers, and asking it is the only way the app can say which of
/// them is in the person's hand.
///
/// * **iOS** keeps a receipt, and its name is the answer: `sandboxReceipt` for TestFlight,
///   `receipt` for the store. A build installed from Xcode has no receipt file at all.
/// * **Android** remembers which package installed this one. Play says Play — and says no more
///   than that, because the listing and a testing track are both Play. That limit is reported as
///   it is rather than guessed past.
///
/// Where the platform will not say, the answer is [BuildOrigin.unknown]. The one thing this must
/// not do is name an origin it does not have.
library;

import 'package:flutter/services.dart';

import 'l10n/words.dart';

/// The ways a build reaches a phone, as far as the phone can tell.
enum BuildOrigin {
  /// The receipt is the store's own.
  appStore('store'),

  /// A sandbox receipt — the build was handed out for testing.
  testFlight('testflight'),

  /// Play installed it. Whether that was the listing or a testing track is not in the answer.
  play('play'),

  /// No receipt, and no store that installed it: built and put on the phone by hand.
  handInstalled('none'),

  /// The platform did not say, or said something this app does not know.
  unknown('unknown');

  const BuildOrigin(this.raw);

  /// What the platform side sends back for this one.
  final String raw;

  static const _channel = MethodChannel('work.amenbo.viewer/build_origin');

  /// Asks the phone. Anything that goes wrong is [unknown] — the screen saying it cannot tell is
  /// a worse answer than the truth only in the sense that there is less of it.
  static Future<BuildOrigin> read() async {
    try {
      return parse(await _channel.invokeMethod<String>('read'));
    } on PlatformException {
      return BuildOrigin.unknown;
    } on MissingPluginException {
      return BuildOrigin.unknown;
    }
  }

  static BuildOrigin parse(Object? raw) => values.firstWhere(
    (origin) => origin.raw == raw,
    orElse: () => BuildOrigin.unknown,
  );
}

String buildOriginWords(Words words, BuildOrigin origin) => switch (origin) {
  BuildOrigin.appStore => words.originAppStore,
  BuildOrigin.testFlight => words.originTestFlight,
  BuildOrigin.play => words.originPlay,
  BuildOrigin.handInstalled => words.originHandInstalled,
  BuildOrigin.unknown => words.originUnknown,
};
