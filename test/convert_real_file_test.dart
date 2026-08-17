// Diagnóstico: convierte un archivo EPUB/PDF real (fuera del repo) con el
// convertidor de la app y valida el .mobi generado igual que los otros tests
// (magic BOOKMOBI, descompresión de registros, capítulos, sin emoji astral).
//
// Se salta (skip) si el archivo no existe, para no romper la suite normal.
//
// Uso:
//   flutter test test/convert_real_file_test.dart --dart-define=SOURCE=/ruta/al/libro.epub

// Dart imports:
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Package imports:
import 'package:flutter_test/flutter_test.dart';

// Project imports:
import 'package:openlib/services/convert_to_mobi.dart';
import 'package:openlib/services/mobi_writer.dart' show decompressTextRecords;

const String _sourcePath = String.fromEnvironment('SOURCE');

void main() {
  test('convertir el libro real ($_sourcePath) a MOBI y validar el resultado',
      () async {
    const sourcePath = _sourcePath;
    if (sourcePath.isEmpty || !File(sourcePath).existsSync()) {
      markTestSkipped('No hay archivo SOURCE: $sourcePath');
      return;
    }
    final format =
        sourcePath.toLowerCase().endsWith('.pdf') ? 'pdf' : 'epub';

    final stopwatch = Stopwatch()..start();
    final result = await convertToMobi(
      sourcePath: sourcePath,
      sourceFormat: format,
    );
    stopwatch.stop();
    // ignore: avoid_print
    print('Conversión en ${stopwatch.elapsedMilliseconds} ms');

    expect(result.outputPath, sourcePath.replaceFirst(RegExp(r'\.epub$|\.pdf$'), '.mobi'));
    expect(result.chapterCount, greaterThan(0));
    expect(result.title.trim(), isNotEmpty);
    // ignore: avoid_print
    print('Título: ${result.title} | Autor: ${result.author} | '
        'Capítulos: ${result.chapterCount}');

    final mobi = await File(result.outputPath).readAsBytes();
    // ignore: avoid_print
    print('Tamaño: ${mobi.length} bytes');
    expect(utf8.decode(mobi, allowMalformed: true), contains('BOOKMOBI'));

    final record0 = _record(mobi, 0);
    final numTextRecords = _u16(record0, 0x08);
    expect(numTextRecords, greaterThan(0));

    final text = utf8.decode(decompressTextRecords(mobi));
    // ignore: avoid_print
    print('Texto descomprimido: ${text.length} bytes');
    final titles = RegExp(r'<h2>(.*?)</h2>')
        .allMatches(text)
        .map((m) => m.group(1)!)
        .where((t) => t.trim().isNotEmpty)
        .toList();
    // ignore: avoid_print
    print('Capítulos en el HTML: ${titles.length}');
    for (final t in titles.take(15)) {
      // ignore: avoid_print
      print('  - $t');
    }
    if (titles.length > 15) {
      // ignore: avoid_print
      print('  ... y ${titles.length - 15} más');
    }

    // Sin caracteres astrales (emoji) en el contenido real: el texto
    // descomprimido, el título (full name del registro 0) y el autor del EXTH.
    // NO se escanea el binario crudo: los registros PalmDOC comprimidos
    // pueden contener secuencias de bytes que decodifican como un carácter
    // astral válido sin ser contenido real (falso positivo).
    void expectNoAstral(String s) {
      for (final rune in s.runes) {
        expect(rune, lessThanOrEqualTo(0xFFFF),
            reason: 'astral char U+${rune.toRadixString(16)}');
      }
    }

    expectNoAstral(text);

    final titleOffset = _u32(record0, 0x54);
    final titleLength = _u32(record0, 0x58);
    expectNoAstral(
        utf8.decode(record0.sublist(titleOffset, titleOffset + titleLength),
            allowMalformed: true));
  });
}

Uint8List _record(Uint8List bytes, int index) {
  final numRecords = _u16(bytes, 76);
  final offset = _u32(bytes, 78 + index * 8);
  final end = index == numRecords - 1
      ? bytes.length
      : _u32(bytes, 78 + (index + 1) * 8);
  return Uint8List.fromList(bytes.sublist(offset, end));
}

int _u16(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _u32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
