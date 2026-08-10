// What every test file gets before it runs: the date data for the languages the app writes dates
// in.
//
// On a phone this arrives with the words. `GlobalMaterialLocalizations` loads intl's symbols for
// whichever language the app resolved to, so by the time a screen is drawn, a date can be written
// in it. A test that calls one of the time helpers directly never went through that, and would be
// told the data was never initialised — or, worse, find it there because some widget test earlier
// in the same file happened to load it.

import 'dart:async';

import 'package:intl/date_symbol_data_local.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await initializeDateFormatting();
  return testMain();
}
