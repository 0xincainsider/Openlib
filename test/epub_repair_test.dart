// Dart imports:
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Package imports:
import 'package:archive/archive.dart';
import 'package:epubx/epubx.dart' show EpubReader;
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

// Project imports:
import 'package:openlib/services/convert_to_mobi.dart';
import 'package:openlib/services/epub_repair.dart';
import 'package:openlib/services/mobi_writer.dart' show decompressTextRecords;

void main() {
  group('regresión: epub con cover meta apuntando al href', () {
    test('EpubReader.readBook rechaza el epub sin reparar (el bug reportado)',
        () async {
      final broken = _buildBrokenCoverEpub();
      await expectLater(
        EpubReader.readBook(broken),
        throwsA(predicate((e) =>
            e.toString().contains('images/cover.png') &&
            e.toString().contains('is missing'))),
      );
    });

    test('convertToMobi convierte el epub con cover roto a mobi', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final epubPath = '${dir.path}/book.epub';
        await File(epubPath).writeAsBytes(_buildBrokenCoverEpub());

        final result = await convertToMobi(
          sourcePath: epubPath,
          sourceFormat: 'epub',
        );

        expect(result.title, 'Test Book');
        expect(result.author, 'Jane Doe');
        final content = _decompressedText(
            await File(result.outputPath).readAsBytes());
        expect(content, contains('First chapter text.'));
        expect(content, contains('Second chapter'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('convertToMobi convierte el epub con cover roto a azw', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final epubPath = '${dir.path}/book.epub';
        await File(epubPath).writeAsBytes(_buildBrokenCoverEpub());

        final result = await convertToMobi(
          sourcePath: epubPath,
          sourceFormat: 'epub',
          outputExtension: 'azw',
        );
        expect(result.outputPath, '${dir.path}/book.azw');
        final content = _decompressedText(
            await File(result.outputPath).readAsBytes());
        expect(content, contains('First chapter text.'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('repairEpubBytes', () {
    test('reescribe el content del meta cover al id del item (href -> id)',
        () {
      final repaired = repairEpubBytes(_buildBrokenCoverEpub());

      final archive = ZipDecoder().decodeBytes(repaired);
      final opfText = utf8.decode(
          archive.findFile('OEBPS/content.opf')!.content as List<int>);
      final opfDoc = XmlDocument.parse(opfText);

      final coverMetas = opfDoc
          .findAllElements('meta', namespace: '*')
          .where((m) => m.getAttribute('name') == 'cover')
          .toList();
      expect(coverMetas, hasLength(1));
      expect(coverMetas.single.getAttribute('content'), 'cover-image');
      // El href del item de portada sigue intacto.
      final coverItem = opfDoc
          .findAllElements('item', namespace: '*')
          .firstWhere((i) => i.getAttribute('id') == 'cover-image');
      expect(coverItem.getAttribute('href'), 'images/cover.png');
    });

    test('EpubReader.readBook acepta el archivo reparado (lo que usa el '
        'lector interno)', () async {
      final repaired = repairEpubBytes(_buildBrokenCoverEpub());

      final book = await EpubReader.readBook(repaired);
      expect(book.Title, 'Test Book');
      expect(book.Author, 'Jane Doe');
      expect(book.Chapters, isNotEmpty);
    });

    test('elimina el meta cover irresoluble y readBook no lanza', () async {
      final repaired = repairEpubBytes(_buildUnresolvableCoverEpub());

      final archive = ZipDecoder().decodeBytes(repaired);
      final opfText = utf8.decode(
          archive.findFile('OEBPS/content.opf')!.content as List<int>);
      final opfDoc = XmlDocument.parse(opfText);
      expect(
        opfDoc
            .findAllElements('meta', namespace: '*')
            .where((m) => m.getAttribute('name') == 'cover'),
        isEmpty,
      );

      final book = await EpubReader.readBook(repaired);
      expect(book.Title, 'Test Book');
      expect(book.Chapters, isNotEmpty);
    });

    test('no toca un epub cuyo content del cover ya es el id del item',
        () async {
      final valid = _buildValidCoverEpub();
      final repaired = repairEpubBytes(valid);
      expect(identical(repaired, valid), isTrue);
      // Y sigue siendo legible.
      final book = await EpubReader.readBook(valid);
      expect(book.Chapters, isNotEmpty);
    });

    test('no toca un epub sin meta cover (mismos bytes)', () async {
      final valid = _buildPlainEpub();
      final repaired = repairEpubBytes(valid);
      expect(identical(repaired, valid), isTrue);
      await EpubReader.readBook(valid);
    });

    test('no toca bytes que no son un zip/epub', () {
      final garbage = Uint8List.fromList(utf8.encode('this is not an epub'));
      final repaired = repairEpubBytes(garbage);
      expect(identical(repaired, garbage), isTrue);
    });

    test('no lanza con un zip vacío o sin container.xml', () {
      final zipBytes = Uint8List.fromList(ZipEncoder().encode(Archive())!);
      final repaired = repairEpubBytes(zipBytes);
      expect(identical(repaired, zipBytes), isTrue);
    });
  });

  group('repairEpubFile', () {
    test('reescribe el archivo solo cuando hay algo que reparar', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final brokenPath = '${dir.path}/broken.epub';
        await File(brokenPath).writeAsBytes(_buildBrokenCoverEpub());
        final validPath = '${dir.path}/valid.epub';
        final validBytes = _buildPlainEpub();
        await File(validPath).writeAsBytes(validBytes);

        expect(await repairEpubFile(brokenPath), isTrue);
        expect(await repairEpubFile(validPath), isFalse);

        // El válido no fue reescrito: bytes idénticos.
        expect(await File(validPath).readAsBytes(), validBytes);
        // El roto ahora es legible.
        final book = await EpubReader.readBook(
            await File(brokenPath).readAsBytes());
        expect(book.Chapters, isNotEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('no reescribe un archivo que no es un epub', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final path = '${dir.path}/garbage.epub';
        final garbage = Uint8List.fromList(utf8.encode('not a zip'));
        await File(path).writeAsBytes(garbage);
        expect(await repairEpubFile(path), isFalse);
        expect(await File(path).readAsBytes(), garbage);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// PNG 1x1 transparente válido (para que la portada sea decodificable).
const List<int> _png1x1 = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

const String _metadata = '''
    <dc:title>Test Book</dc:title>
    <dc:creator opf:role="aut">Jane Doe</dc:creator>
    <dc:language>en</dc:language>''';

const String _manifestItems = '''
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>''';

/// EPUB cuyo `<meta name="cover" content="images/cover.png"/>` apunta al
/// *href* del item de portada (id `cover-image`) en vez de a su id: el bug
/// reportado. El PNG existe en el archivo.
Uint8List _buildBrokenCoverEpub() {
  return _buildEpub(
    metadata: '$_metadata\n'
        '    <meta name="cover" content="images/cover.png"/>',
    manifestItems: '''
    <item id="cover-image" href="images/cover.png" media-type="image/png"/>
    $_manifestItems''',
    extraFiles: {'OEBPS/images/cover.png': _png1x1},
  );
}

/// Cover meta que no resuelve a ningún item (ni id ni href).
Uint8List _buildUnresolvableCoverEpub() {
  return _buildEpub(
    metadata: '$_metadata\n'
        '    <meta name="cover" content="stale-cover.png"/>',
    manifestItems: _manifestItems,
  );
}

/// Cover meta correcto: el content ya es el id del item.
Uint8List _buildValidCoverEpub() {
  return _buildEpub(
    metadata: '$_metadata\n'
        '    <meta name="cover" content="cover-image"/>',
    manifestItems: '''
    <item id="cover-image" href="images/cover.png" media-type="image/png"/>
    $_manifestItems''',
    extraFiles: {'OEBPS/images/cover.png': _png1x1},
  );
}

/// EPUB sin portada declarada.
Uint8List _buildPlainEpub() {
  return _buildEpub(metadata: _metadata, manifestItems: _manifestItems);
}

Uint8List _buildEpub({
  required String metadata,
  required String manifestItems,
  Map<String, List<int>> extraFiles = const {},
}) {
  final archive = Archive();
  void addText(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  addText('mimetype', 'application/epub+zip');
  addText('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''');
  addText('OEBPS/content.opf', '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookId">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
$metadata
  </metadata>
  <manifest>
$manifestItems
  </manifest>
  <spine toc="ncx">
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>''');
  addText('OEBPS/toc.ncx', '''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="1234"/></head>
  <docTitle><text>Test Book</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="chapter1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>Chapter Two</text></navLabel><content src="chapter2.xhtml"/></navPoint>
  </navMap>
</ncx>''');
  addText('OEBPS/chapter1.xhtml',
      '<html><head><title>One</title></head><body><h1>Chapter One</h1>'
      '<p>First chapter text.</p></body></html>');
  addText('OEBPS/chapter2.xhtml',
      '<html><head><title>Two</title></head><body><h1>Chapter Two</h1>'
      '<p>Second chapter <b>bold</b> text.</p></body></html>');
  for (final entry in extraFiles.entries) {
    archive.addFile(
        ArchiveFile(entry.key, entry.value.length, entry.value));
  }

  final zip = ZipEncoder().encode(archive);
  return Uint8List.fromList(zip ?? const <int>[]);
}

String _decompressedText(Uint8List bytes) =>
    utf8.decode(decompressTextRecords(bytes));
