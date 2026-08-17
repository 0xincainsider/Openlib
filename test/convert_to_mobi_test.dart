// Dart imports:
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Package imports:
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

// Project imports:
import 'package:openlib/services/convert_to_mobi.dart';
import 'package:openlib/services/local_file_server.dart';
import 'package:openlib/services/mobi_writer.dart' show decompressTextRecords;

void main() {
  group('buildMobiHtml', () {
    test('escapes html in titles and text', () {
      final html = buildMobiHtml(
        title: 'Book <&"Title">',
        chapters: const [
          MobiChapter(
            title: 'Ch <1>',
            htmlContent: '<p>text with <b>bold</b> & <i>italic</i></p>',
          ),
        ],
      ).html;
      expect(html, contains('Book &lt;&amp;&quot;Title&quot;&gt;'));
      expect(html, contains('<h2>Ch &lt;1&gt;</h2>'));
      expect(html, contains('text with <b>bold</b> &amp; <i>italic</i>'));
    });

    test('emits one h2 per chapter with pagebreak, in order', () {
      final html = buildMobiHtml(
        title: 'T',
        chapters: const [
          MobiChapter(title: 'First', htmlContent: '<p>one</p>'),
          MobiChapter(title: 'Second', htmlContent: '<p>two</p>'),
        ],
      ).html;
      expect(html.indexOf('<h2>First</h2>'), lessThan(html.indexOf('<h2>Second</h2>')));
      expect(html.indexOf('<mbp:pagebreak/>'), lessThan(html.indexOf('<h2>First</h2>')));
      expect(html, contains('<h1>T</h1>'));
    });

    test('converts xhtml blocks into mobi paragraphs', () {
      final html = buildMobiHtml(
        title: '',
        chapters: const [
          MobiChapter(
            title: '',
            htmlContent:
                '<div class="chapter"><h1>Heading</h1><p>Para one.</p>'
                '<p>Para <b>two</b>.</p><ul><li>item</li></ul></div>',
          ),
        ],
      ).html;
      expect(html, contains('<p>Para one.</p>'));
      expect(html, contains('<p>Para <b>two</b>.</p>'));
      expect(html, contains('<p>item</p>'));
      expect(html, isNot(contains('<div')));
    });

    test('drops script/style/img content', () {
      final html = buildMobiHtml(
        title: '',
        chapters: const [
          MobiChapter(
            title: '',
            htmlContent:
                '<p>visible</p><script>alert(1)</script><style>p{color:red}</style>'
                '<img src="x.jpg"/>',
          ),
        ],
      ).html;
      expect(html, contains('visible'));
      expect(html, isNot(contains('alert')));
      expect(html, isNot(contains('color:red')));
      expect(html, isNot(contains('<img')));
    });

    test('strips emoji (astral chars) but keeps accents and smart '
        'punctuation', () {
      final html = buildMobiHtml(
        title: 'Libro \u{1F50D} con emoji \u{1F389}',
        chapters: const [
          MobiChapter(
            title: 'Cap\u00edtulo 1 \u{1F50D}',
            htmlContent: '<p>Texto con \u201ccomillas\u201d y acentos '
                '\u00e9\u00f1 \u2014 y emoji \u{1F50D}\u{1F389}\u{1F680}.</p>',
          ),
        ],
      ).html;
      expect(html, isNot(contains('\u{1F50D}')));
      expect(html, isNot(contains('\u{1F389}')));
      expect(html, isNot(contains('\u{1F680}')));
      // The emoji are gone; the surrounding words survive (HTML collapses
      // the leftover whitespace when rendering).
      expect(html, contains('Libro'));
      expect(html, contains('con emoji'));
      expect(html, contains('Cap\u00edtulo 1'));
      expect(html, contains('\u201ccomillas\u201d'));
      expect(html, contains('\u00e9\u00f1'));
      expect(html, contains('\u2014'));
    });

    test('converted mobi contains no astral-plane (emoji) characters '
        'anywhere (title, header and text)', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final epubPath = '${dir.path}/Libro.epub';
        await File(epubPath).writeAsBytes(_buildTestEpub(
          title: 'Test Book \u{1F50D}',
          extraParagraph: '<p>Con emoji \u{1F389} aqu\u00ed.</p>',
        ));

        final result = await convertToMobi(
          sourcePath: epubPath,
          sourceFormat: 'epub',
        );
        final mobi = await File(result.outputPath).readAsBytes();

        // The whole file must not contain any astral-plane character (emoji):
        // Kindle fonts cannot render them and they show as broken glyphs.
        final decoded = utf8.decode(mobi, allowMalformed: true);
        for (final rune in decoded.runes) {
          expect(rune, lessThanOrEqualTo(0xFFFF),
              reason: 'astral char U+${rune.toRadixString(16)} in mobi');
        }
        // And the decompressed text keeps the accents.
        final content = _decompressedText(mobi);
        expect(content, contains('aqu\u00ed'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('convertToMobi (epub)', () {
    test('extracts chapters in spine order and writes a readable mobi', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final epubBytes = _buildTestEpub();
        final epubPath = '${dir.path}/book.epub';
        await File(epubPath).writeAsBytes(epubBytes);

        final result = await convertToMobi(
          sourcePath: epubPath,
          sourceFormat: 'epub',
        );

        expect(result.outputPath, '${dir.path}/book.mobi');
        expect(result.title, 'Test Book');
        expect(result.author, 'Jane Doe');
        expect(await File(result.outputPath).exists(), isTrue);

        final mobi = await File(result.outputPath).readAsBytes();
        // parsed title/author live in the full name + EXTH
        final text = utf8.decode(mobi, allowMalformed: true);
        // full name
        final record0 = _record(mobi, 0);
        expect(_ascii(record0, _u32(record0, 0x54),
            _u32(record0, 0x54) + _u32(record0, 0x58)), 'Test Book');
        // decompressed content contains both chapters in order
        final content = _decompressedText(mobi);
        expect(content, contains('<h2>Chapter One</h2>'));
        expect(content, contains('<h2>Chapter Two</h2>'));
        expect(content.indexOf('First chapter text.'),
            lessThan(content.indexOf('Second chapter')));
        expect(content, contains('Second chapter <b>bold</b> text.'));
        expect(text, contains('BOOKMOBI'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('uses caller-provided title/author when given', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final epubPath = '${dir.path}/book.epub';
        await File(epubPath).writeAsBytes(_buildTestEpub());

        final result = await convertToMobi(
          sourcePath: epubPath,
          sourceFormat: 'epub',
          title: 'Overridden Title',
          author: 'Override Author',
        );
        expect(result.title, 'Overridden Title');
        expect(result.author, 'Override Author');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('the mobi inherits the source base name (library-style name)',
        () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final epubPath = '${dir.path}/HarryPotter.epub';
        await File(epubPath).writeAsBytes(_buildTestEpub());

        final result = await convertToMobi(
          sourcePath: epubPath,
          sourceFormat: 'epub',
        );
        expect(result.outputPath, '${dir.path}/HarryPotter.mobi');
        expect(await File(result.outputPath).exists(), isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejects a file that is not an epub', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final badPath = '${dir.path}/notabook.epub';
        await File(badPath).writeAsBytes(utf8.encode('this is not an epub'));
        await expectLater(
          convertToMobi(sourcePath: badPath, sourceFormat: 'epub'),
          throwsA(isA<StateError>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('convertToMobi (pdf)', () {
    test('extracts text from a born-digital pdf', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final pdfPath = '${dir.path}/book.pdf';
        await File(pdfPath).writeAsBytes(_buildMinimalPdf('Hello Kindle World'));

        final result = await convertToMobi(
          sourcePath: pdfPath,
          sourceFormat: 'pdf',
        );
        expect(result.outputPath, '${dir.path}/book.mobi');
        final content = _decompressedText(await File(result.outputPath).readAsBytes());
        expect(content, contains('Hello Kindle World'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('fails clearly when the pdf has no extractable text', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final pdfPath = '${dir.path}/scanned.pdf';
        await File(pdfPath).writeAsBytes(utf8.encode('not a pdf at all'));
        await expectLater(
          convertToMobi(sourcePath: pdfPath, sourceFormat: 'pdf'),
          throwsA(isA<StateError>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('convertToMobi + local file server', () {
    test('el .mobi queda junto a los libros descargados y se sirve por el '
        'servidor local', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final epubPath = '${dir.path}/book.epub';
        await File(epubPath).writeAsBytes(_buildTestEpub());

        final result = await convertToMobi(
          sourcePath: epubPath,
          sourceFormat: 'epub',
        );
        // Mismo directorio que el archivo descargado (bookStorageDirectory).
        expect(result.outputPath, '${dir.path}/book.mobi');
        expect(File(result.outputPath).parent.path, File(epubPath).parent.path);

        // El servidor local sirve la carpeta de libros descargados: el .mobi
        // debe aparecer en el listing y descargarse por HTTP.
        final server = LocalFileServer();
        final port = await server.start(rootPath: dir.path);
        try {
          final listing = await http.get(Uri.parse('http://127.0.0.1:$port/'));
          expect(listing.statusCode, 200);
          expect(listing.body, contains('book.mobi'));

          final res =
              await http.get(Uri.parse('http://127.0.0.1:$port/book.mobi'));
          expect(res.statusCode, 200);
          expect(res.headers['content-type'],
              'application/x-mobipocket-ebook');
          expect(res.bodyBytes, await File(result.outputPath).readAsBytes());
        } finally {
          await server.stop();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('convertToMobi (azw output)', () {
    test('escribe el mismo contenido Mobipocket con extensión .azw',
        () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final epubPath = '${dir.path}/book.epub';
        await File(epubPath).writeAsBytes(_buildTestEpub());

        final result = await convertToMobi(
          sourcePath: epubPath,
          sourceFormat: 'epub',
          outputExtension: 'azw',
        );

        expect(result.outputPath, '${dir.path}/book.azw');
        expect(await File(result.outputPath).exists(), isTrue);

        final azw = await File(result.outputPath).readAsBytes();
        // Mismo contenedor que el .mobi (AZW = Mobipocket).
        expect(utf8.decode(azw, allowMalformed: true), contains('BOOKMOBI'));
        final content = _decompressedText(azw);
        expect(content, contains('First chapter text.'));
        expect(content, contains('<h2>Chapter One</h2>'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('el .azw se sirve por el servidor local con su content-type',
        () async {
      final dir = await Directory.systemTemp.createTemp('openlib_test');
      try {
        final epubPath = '${dir.path}/book.epub';
        await File(epubPath).writeAsBytes(_buildTestEpub());

        await convertToMobi(
          sourcePath: epubPath,
          sourceFormat: 'epub',
          outputExtension: 'azw',
        );

        final server = LocalFileServer();
        final port = await server.start(rootPath: dir.path);
        try {
          final listing = await http.get(Uri.parse('http://127.0.0.1:$port/'));
          expect(listing.statusCode, 200);
          expect(listing.body, contains('book.azw'));

          final res =
              await http.get(Uri.parse('http://127.0.0.1:$port/book.azw'));
          expect(res.statusCode, 200);
          expect(res.headers['content-type'], 'application/vnd.amazon.ebook');
          expect(res.bodyBytes, await File('${dir.path}/book.azw').readAsBytes());
        } finally {
          await server.stop();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('convertToMobi (errors)', () {
    test('rejects unsupported formats', () async {
      await expectLater(
        convertToMobi(
            sourcePath: '/tmp/x.cbz', sourceFormat: 'cbz'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('fails when the file does not exist', () async {
      await expectLater(
        convertToMobi(sourcePath: '/nonexistent/x.epub', sourceFormat: 'epub'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a minimal but valid EPUB 2 with two chapters.
Uint8List _buildTestEpub({
  String title = 'Test Book',
  String extraParagraph = '',
}) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''');
  add('OEBPS/content.opf', '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookId">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>$title</dc:title>
    <dc:creator opf:role="aut">Jane Doe</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>''');
  add('OEBPS/toc.ncx', '''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="1234"/></head>
  <docTitle><text>Test Book</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="chapter1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>Chapter Two</text></navLabel><content src="chapter2.xhtml"/></navPoint>
  </navMap>
</ncx>''');
  add('OEBPS/chapter1.xhtml',
      '<html><head><title>One</title></head><body><h1>Chapter One</h1>'
      '<p>First chapter text.</p></body></html>');
  add('OEBPS/chapter2.xhtml',
      '<html><head><title>Two</title></head><body><h1>Chapter Two</h1>'
      '<p>Second chapter <b>bold</b> text.</p>'
      '$extraParagraph</body></html>');

  final zip = ZipEncoder().encode(archive);
  return Uint8List.fromList(zip ?? const <int>[]);
}

/// Minimal single-page PDF with one text line (Helvetica, WinAnsi).
Uint8List _buildMinimalPdf(String text) {
  final objs = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
        '/Resources << /Font << /F1 5 0 R >> >> >>',
    '',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final stream = 'BT /F1 24 Tf 72 720 Td ($text) Tj ET';
  objs[3] = '<< /Length ${stream.length} >>\nstream\n$stream\nendstream';

  final sb = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(sb.length);
    sb.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xrefPos = sb.length;
  sb.write('xref\n0 ${objs.length + 1}\n');
  sb.write('0000000000 65535 f \n');
  for (final off in offsets) {
    sb.write('${off.toString().padLeft(10, '0')} 00000 n \n');
  }
  sb.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\n');
  sb.write('startxref\n$xrefPos\n%%EOF');
  return Uint8List.fromList(utf8.encode(sb.toString()));
}

Uint8List _record(Uint8List bytes, int index) {
  final numRecords = _u16(bytes, 76);
  final offset = _u32(bytes, 78 + index * 8);
  final end = index == numRecords - 1
      ? bytes.length
      : _u32(bytes, 78 + (index + 1) * 8);
  return Uint8List.fromList(bytes.sublist(offset, end));
}

String _decompressedText(Uint8List bytes) =>
    utf8.decode(decompressTextRecords(bytes));

int _u16(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _u32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

String _ascii(Uint8List bytes, int start, int end) =>
    ascii.decode(bytes.sublist(start, end), allowInvalid: true);
