/// Reading the code off the PC screen — the one thing this phone is ever set up with.
///
/// Everything else the app does needs no configuring at all, so this screen is the whole of
/// setup, and someone stuck here is stuck at everything. That is what the shape below is for:
///
/// * **the reason comes before the request.** An OS permission sheet that arrives unannounced is
///   answered on instinct, and "no" to the camera on a phone whose only job is to read one code
///   is a dead end reached in a single tap. So the screen says why first, and the sheet appears
///   when the person asks for it.
/// * **a code that reads is acted on.** No confirm button: scanning is reversible — a wrong code
///   is scanned again — so a button between reading and pairing only asks people to approve a
///   string of base64 they cannot check.
/// * **being refused is not the end.** The settings app is the way back, and it is the only one:
///   a code read out of a photograph would put the token and the key in the photo library, and
///   from there in iCloud and every backup, which is the one place the key is never meant to go.
/// * **a code that does not fit says what was different.** `pairing_code.dart` says which refusal
///   it is; [troubleWith] turns that into the sentence this screen shows.
///
/// The camera reaches this screen through [Camera], so what is drawn and what happens after a
/// code is read can be walked in a test. Only [LiveCamera] talks to a device.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import 'cloudflare_intake.dart' show contractVersion;
import 'l10n/words.dart';
import 'pairing_code.dart';
import 'pairing_store.dart';
import 'ui/tokens.dart';

/// What was wrong with a code, in words.
///
/// `pairing_code.dart` says which refusal it is and carries the numbers; the sentence is chosen
/// here, where the language the phone is set to is known. The last arm takes the two that lost
/// the value their sentence needed along with the plain incomplete code — all three are answered
/// by showing a fresh code, so none of them leaves the person without a next step.
String troubleWith(Words words, PairingCodeException code) {
  final said = code.saidVersion;
  final url = code.url;
  return switch (code.problem) {
    CodeProblem.notAPairingCode => words.codeNotOurs,
    CodeProblem.tooNew when said != null => words.codeTooNew(
      said,
      contractVersion,
    ),
    CodeProblem.tooOld when said != null => words.codeTooOld(
      said,
      contractVersion,
    ),
    CodeProblem.notHttps when url != null => words.codeNotHttps('$url'),
    CodeProblem.keyWillNotOpen => words.codeKeyWillNotOpen,
    _ => words.codeIncomplete,
  };
}

/// Whether the camera may be used, once the person has been asked.
enum CameraAccess { granted, refused }

/// What this screen needs of the phone's camera.
abstract interface class Camera {
  /// Asks the OS for the camera. Called only after the person has been told why.
  Future<CameraAccess> ask();

  /// Opens this app's page in the system settings, which is the only way back from a refusal.
  Future<void> openTheSettings();

  /// The live view, calling [onCode] with the text of each code it sees.
  Widget view(void Function(String text) onCode);
}

/// The camera of the phone this is running on.
class LiveCamera implements Camera {
  const LiveCamera();

  /// Only QR codes are looked for. Narrowing it keeps the scanner from catching a barcode that
  /// happens to be in frame and reporting it as something that failed to pair.
  static const _formats = [BarcodeFormat.qrCode];

  @override
  Future<CameraAccess> ask() async {
    final status = await Permission.camera.request();
    return status.isGranted || status.isLimited
        ? CameraAccess.granted
        : CameraAccess.refused;
  }

  @override
  Future<void> openTheSettings() => openAppSettings();

  @override
  Widget view(void Function(String text) onCode) => _LiveView(onCode: onCode);
}

class _LiveView extends StatefulWidget {
  const _LiveView({required this.onCode});

  final void Function(String text) onCode;

  @override
  State<_LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<_LiveView> {
  /// `noDuplicates` so a code held in frame is reported once. The screen guards against a second
  /// code arriving mid-pairing anyway, but a stream repeating the same failure several times a
  /// second would rewrite the message under the reader.
  final _scanner = MobileScannerController(
    formats: LiveCamera._formats,
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MobileScanner(
      controller: _scanner,
      onDetect: (capture) {
        final text = capture.barcodes
            .map((barcode) => barcode.rawValue)
            .whereType<String>()
            .firstOrNull;
        if (text != null) widget.onCode(text);
      },
    );
  }
}

/// Pairs this phone, and hands the [Pairing] back to whoever pushed it.
///
/// It saves the pairing itself before popping, so the phone is paired the moment the screen
/// closes — nothing downstream has to remember to write it down.
class PairingScanScreen extends StatefulWidget {
  const PairingScanScreen({
    super.key,
    this.camera = const LiveCamera(),
    this.store = const PairingStore(),
  });

  final Camera camera;
  final PairingStore store;

  @override
  State<PairingScanScreen> createState() => _PairingScanScreenState();
}

enum _Stage { explaining, scanning, refused }

class _PairingScanScreenState extends State<PairingScanScreen> {
  _Stage _stage = _Stage.explaining;

  /// What was wrong with the last code read, in the words `pairing_code.dart` chose.
  String? _trouble;

  /// A code is being acted on. It keeps a second one out while the first is being saved, and it
  /// is what the buttons go quiet on.
  bool _busy = false;

  Future<void> _askForTheCamera() async {
    setState(() => _busy = true);
    final access = await widget.camera.ask();
    if (!mounted) return;
    setState(() {
      _stage = access == CameraAccess.granted
          ? _Stage.scanning
          : _Stage.refused;
      _busy = false;
    });
  }

  void _sawACode(String text) {
    if (_busy) return;
    setState(() {
      _busy = true;
      _trouble = null;
    });
    _pairWith(text);
  }

  Future<void> _pairWith(String text) async {
    final Pairing pairing;
    try {
      pairing = readPairingCode(text);
    } on PairingCodeException catch (problem) {
      if (!mounted) return;
      _say(troubleWith(Words.of(context), problem));
      return;
    }

    try {
      await widget.store.save(pairing);
    } catch (error) {
      // The code was right and the phone would not keep it. Saying so beats a screen that goes
      // on scanning a code it has already read correctly.
      if (!mounted) return;
      _say(Words.of(context).pairCouldNotKeep('$error'));
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(pairing);
  }

  void _say(String trouble) {
    if (!mounted) return;
    setState(() {
      _trouble = trouble;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(Words.of(context).pairTitle)),
      body: switch (_stage) {
        _Stage.explaining => _Explaining(
          onAsk: _busy ? null : _askForTheCamera,
        ),
        _Stage.scanning => _Scanning(
          view: widget.camera.view(_sawACode),
          trouble: _trouble,
        ),
        _Stage.refused => _Refused(
          onSettings: _busy ? null : widget.camera.openTheSettings,
        ),
      },
    );
  }
}

/// Why the camera is needed, before it is asked for.
class _Explaining extends StatelessWidget {
  const _Explaining({required this.onAsk});

  final VoidCallback? onAsk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = Words.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Space.pageGutter,
        Space.pageGutter,
        Space.pageGutter,
        Space.s7,
      ),
      children: [
        Text(words.pairHeading, style: theme.textTheme.headlineSmall),
        const SizedBox(height: Space.s4),
        Text(words.pairWhy, style: theme.textTheme.bodyLarge),
        const SizedBox(height: Space.s7),
        FilledButton(onPressed: onAsk, child: Text(words.pairTurnOnCamera)),
      ],
    );
  }
}

/// The camera, with a frame drawn on it and nothing else in the way.
class _Scanning extends StatelessWidget {
  const _Scanning({required this.view, required this.trouble});

  final Widget view;
  final String? trouble;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trouble = this.trouble;

    return Stack(
      fit: StackFit.expand,
      children: [
        view,
        const _Frame(),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(Space.pageGutter),
                child: _OverTheView(
                  child: Text(
                    trouble ?? Words.of(context).pairInFrame,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: OverCamera.frame,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The square the code goes in. It draws an edge and nothing more — what is inside it is the
/// camera, because a code is found by aiming at it and a decorated screen only gets in the way.
class _Frame extends StatelessWidget {
  const _Frame();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.7,
        child: AspectRatio(
          aspectRatio: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: OverCamera.frame, width: Stroke.thick),
              borderRadius: Corner.wide,
            ),
          ),
        ),
      ),
    );
  }
}

/// Text over a camera picture, which is any colour at all. The plate is what keeps it readable
/// against a bright PC screen.
class _OverTheView extends StatelessWidget {
  const _OverTheView({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OverCamera.scrim,
        borderRadius: Corner.wide,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.gutter,
          vertical: Space.s4,
        ),
        child: child,
      ),
    );
  }
}

/// The camera was refused, and the settings are the way on from here.
class _Refused extends StatelessWidget {
  const _Refused({required this.onSettings});

  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = Words.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Space.pageGutter,
        Space.pageGutter,
        Space.pageGutter,
        Space.s7,
      ),
      children: [
        Text(words.pairCameraRefused, style: theme.textTheme.headlineSmall),
        const SizedBox(height: Space.s4),
        Text(words.pairRefusedDetail, style: theme.textTheme.bodyLarge),
        const SizedBox(height: Space.s7),
        FilledButton(
          onPressed: onSettings,
          child: Text(words.pairOpenSettings),
        ),
      ],
    );
  }
}
