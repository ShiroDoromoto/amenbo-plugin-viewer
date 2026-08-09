/// The two moments the app is allowed to be felt, and the one it may never be heard.
///
/// A reader that buzzes at every arriving row is a reader nobody opens in a meeting. Feedback is
/// spent on the two moments the person is actually waiting on an answer, and on nothing else.
///
/// **Sound is never played.** The app is opened in bed and on trains; there is nothing it could
/// say out loud that is worth the one time it says it in the wrong room.
library;

import 'package:flutter/services.dart';

class Touch {
  const Touch._();

  /// The person pulled to refresh and the new rows went in under their thumb. Confirms the
  /// gesture they made — the only kind of change that is not a surprise.
  static Future<void> refreshApplied() => HapticFeedback.selectionClick();

  /// The first sync after pairing finished. The one moment the app was empty and now is not, and
  /// the person has been waiting on it with nothing to read.
  static Future<void> firstSyncFinished() => HapticFeedback.mediumImpact();
}
