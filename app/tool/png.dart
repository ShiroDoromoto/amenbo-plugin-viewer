// Writing a PNG.
//
// Neither Dart nor Flutter offers one in the shape the generators next door need: `dart:io` has
// the compressor but no format around it, and Flutter's own encoder always writes the alpha
// channel — which the stores refuse on the pictures that are meant to be opaque.
//
// There is nothing clever here. A PNG is a signature, a header, one deflated block of rows, and
// an end marker, and every row is prefixed with the filter it used — none, in these, since flat
// colour deflates on its own.

import 'dart:io';
import 'dart:typed_data';

/// [rgba] is width × height pixels, four bytes each, alpha last and not multiplied in.
///
/// With [opaque] the alpha channel is dropped rather than written as 255: an opaque picture is
/// smaller for it, and a store that refuses transparency refuses the channel, not the value.
Uint8List encodePng({
  required int width,
  required int height,
  required Uint8List rgba,
  required bool opaque,
}) {
  final channels = opaque ? 3 : 4;
  final rows = Uint8List(height * (1 + width * channels));
  var at = 0;
  for (var y = 0; y < height; y++) {
    rows[at++] = 0; // No filter on this row.
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      rows[at++] = rgba[i];
      rows[at++] = rgba[i + 1];
      rows[at++] = rgba[i + 2];
      if (!opaque) rows[at++] = rgba[i + 3];
    }
  }

  final header = BytesBuilder()
    ..add(_be32(width))
    ..add(_be32(height))
    ..add([8, opaque ? 2 : 6, 0, 0, 0]);

  return (BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(_chunk('IHDR', header.takeBytes()))
        ..add(
          _chunk('IDAT', Uint8List.fromList(ZLibCodec(level: 9).encode(rows))),
        )
        ..add(_chunk('IEND', Uint8List(0))))
      .takeBytes();
}

Uint8List _chunk(String kind, Uint8List body) {
  final tagged = Uint8List.fromList([...kind.codeUnits, ...body]);
  return Uint8List.fromList([
    ..._be32(body.length),
    ...tagged,
    ..._be32(_crc32(tagged)),
  ]);
}

List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
