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
/// * **being refused is not the end.** The settings app is one way back, and a photograph of the
///   PC screen is the other; both are offered, because the second needs no permission at all.
/// * **a code that does not fit says what was different.** `pairing_code.dart` keeps those
///   sentences.
///
/// The camera and the photo library reach this screen through [Camera], so what is drawn and what
/// happens after a code is read can be walked in a test. Only [LiveCamera] talks to a device.
library;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import 'pairing_code.dart';
import 'pairing_store.dart';

/// Whether the camera may be used, once the person has been asked.
enum CameraAccess { granted, refused }

/// What this screen needs of the phone's camera and its pictures.
abstract interface class Camera {
  /// Asks the OS for the camera. Called only after the person has been told why.
  Future<CameraAccess> ask();

  /// Opens this app's page in the system settings, which is the only way back from a refusal.
  Future<void> openTheSettings();

  /// The live view, calling [onCode] with the text of each code it sees.
  Widget view(void Function(String text) onCode);

  /// Reads a code out of a picture the person picks — a photo of the PC screen taken on another
  /// phone, or a screenshot sent over.
  ///
  /// Null when they picked nothing. Throws [PairingCodeException] when the picture holds no code.
  Future<String?> readAPicture();
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

  @override
  Future<String?> readAPicture() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return null;

    final scanner = MobileScannerController(formats: _formats);
    try {
      final seen = await scanner.analyzeImage(picked.path, formats: _formats);
      final text = seen?.barcodes
          .map((barcode) => barcode.rawValue)
          .whereType<String>()
          .firstOrNull;
      if (text == null) {
        throw const PairingCodeException(
          CodeProblem.nothingInThePicture,
          'There is no code in that picture. A photo of the whole PC screen, '
          'taken straight on, is the one that reads.',
        );
      }
      return text;
    } finally {
      await scanner.dispose();
    }
  }
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

  static const title = 'Pair this phone';
  static const heading = 'Read the code on your PC';
  static const why =
      'The code is on the PC screen, so the camera is how it gets here. '
      'It is read on this phone and sent nowhere.';
  static const inFrame = 'Hold the code inside the frame.';
  static const refused = 'The camera is off for this app.';
  static const fromAPicture = 'Read it from a picture';

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

  Future<void> _fromAPicture() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _trouble = null;
    });

    final String? text;
    try {
      text = await widget.camera.readAPicture();
    } on PairingCodeException catch (problem) {
      _say(problem.message);
      return;
    }
    if (text == null) {
      // They backed out of the picker. Nothing happened, so nothing is said about it.
      if (mounted) setState(() => _busy = false);
      return;
    }
    await _pairWith(text);
  }

  Future<void> _pairWith(String text) async {
    final Pairing pairing;
    try {
      pairing = readPairingCode(text);
    } on PairingCodeException catch (problem) {
      _say(problem.message);
      return;
    }

    try {
      await widget.store.save(pairing);
    } catch (error) {
      // The code was right and the phone would not keep it. Saying so beats a screen that goes
      // on scanning a code it has already read correctly.
      _say('This phone could not keep the pairing: $error');
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
      appBar: AppBar(title: const Text(PairingScanScreen.title)),
      body: switch (_stage) {
        _Stage.explaining => _Explaining(
          onAsk: _busy ? null : _askForTheCamera,
        ),
        _Stage.scanning => _Scanning(
          view: widget.camera.view(_sawACode),
          trouble: _trouble,
          onPicture: _busy ? null : _fromAPicture,
        ),
        _Stage.refused => _Refused(
          trouble: _trouble,
          onSettings: _busy ? null : widget.camera.openTheSettings,
          onPicture: _busy ? null : _fromAPicture,
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        Text(PairingScanScreen.heading, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(PairingScanScreen.why, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 28),
        FilledButton(onPressed: onAsk, child: const Text('Turn on the camera')),
      ],
    );
  }
}

/// The camera, with a frame drawn on it and nothing else in the way.
class _Scanning extends StatelessWidget {
  const _Scanning({
    required this.view,
    required this.trouble,
    required this.onPicture,
  });

  final Widget view;
  final String? trouble;
  final VoidCallback? onPicture;

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
                padding: const EdgeInsets.all(20),
                child: _OverTheView(
                  child: Text(
                    trouble ?? PairingScanScreen.inFrame,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.all(20),
                child: _OverTheView(
                  child: TextButton(
                    onPressed: onPicture,
                    child: const Text(PairingScanScreen.fromAPicture),
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
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(16),
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
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: child,
      ),
    );
  }
}

/// The camera was refused, and there are two ways on from here.
class _Refused extends StatelessWidget {
  const _Refused({
    required this.trouble,
    required this.onSettings,
    required this.onPicture,
  });

  final String? trouble;
  final VoidCallback? onSettings;
  final VoidCallback? onPicture;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trouble = this.trouble;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        Text(PairingScanScreen.refused, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(
          'Pairing needs to read one code off your PC screen. Turn the camera '
          'on in the settings, or use a picture of that screen instead.',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: onSettings,
          child: const Text('Open the settings'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: onPicture,
          child: const Text(PairingScanScreen.fromAPicture),
        ),
        if (trouble != null) ...[
          const SizedBox(height: 20),
          Text(
            trouble,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}
