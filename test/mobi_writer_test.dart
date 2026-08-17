// Dart imports:
import 'dart:convert';
import 'dart:typed_data';

// Package imports:
import 'package:flutter_test/flutter_test.dart';

// Project imports:
import 'package:openlib/services/mobi_writer.dart';

/// Golden vectors produced by Calibre's `py_compress_doc` reference
/// implementation (src/calibre/ebooks/compression/palmdoc.py) and verified to
/// round-trip with the KindleUnpack `PalmdocReader` decompressor.
const Map<String, List<int>> _calibreVectors = {
  'abc\\x03\\x04\\x05\\x06ms': [97, 98, 99, 4, 3, 4, 5, 6, 109, 115],
  'a b c \\xfed ': [97, 226, 227, 32, 1, 254, 100, 32],
  '0123456789axyz2bxyz2cdfgfo9iuyerh': [
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 97, 120, 121, 122, 50, 98, 128, 41,
    99, 100, 102, 103, 102, 111, 57, 105, 117, 121, 101, 114, 104
  ],
  '0123456789asd0123456789asd|yyzzxxffhhjjkk': [
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 97, 115, 100, 128, 111, 128, 104,
    124, 121, 121, 122, 122, 120, 120, 102, 102, 104, 104, 106, 106, 107, 107
  ],
};

void main() {
  group('compressPalmDoc', () {
    test('byte-for-byte matches Calibre py_compress_doc vectors', () {
      _calibreVectors.forEach((rawInput, expected) {
        final input = _bytesFromEscaped(rawInput);
        expect(
          compressPalmDoc(input),
          expected,
          reason: 'vector: $rawInput',
        );
      });
    });

    test('round-trips every Calibre test corpus input', () {
      final inputs = <Uint8List>[
        _bytesFromEscaped('abc\\x03\\x04\\x05\\x06ms'),
        _bytesFromEscaped('a b c \\xfed '),
        _bytesFromEscaped('0123456789axyz2bxyz2cdfgfo9iuyerh'),
        _bytesFromEscaped('0123456789asd0123456789asd|yyzzxxffhhjjkk'),
        _bytesFromEscaped(
            'ciewacnaq eiu743 r787q 0w%  ; sa fd\\xef\\xffdxosac wocjp '
            'acoiecowei owaic jociowapjcivcjpoivjporeivjpoavca; '
            'p9aw8743y6r74%\\x24^\\x24^%8 '),
        utf8.encode('The quick brown fox jumps over the lazy dog. ' * 200),
        utf8.encode('El veloz murci\\u00e9lago hind\\u00fa com\\u00eda '
            'feliz cardillo y kiwi. ' * 50),
        Uint8List(0),
        Uint8List.fromList([0, 0, 0]),
        Uint8List.fromList(List<int>.generate(256, (i) => i)),
      ];
      for (final input in inputs) {
        final compressed = compressPalmDoc(input);
        final roundTrip = decompressPalmDoc(compressed);
        expect(roundTrip, input, reason: 'input length: ${input.length}');
      }
    });

    test('decompressPalmDoc expands a hand-crafted stream correctly', () {
      // literals 'A','B','C','D' + 0xC0 (space + '@') then a 2-byte backref
      // code 0x8021: distance m = (0x8021 >> 3) & 0x7ff = 4, length n = 4.
      final stream = Uint8List.fromList([0x41, 0x42, 0x43, 0x44, 0xC0, 0x80, 0x21]);
      // out after literals + space: A B C D ' ' @ ; backref copies the 4 bytes
      // ending 4 positions back (C D ' ' @) with byte-by-byte semantics.
      expect(
        decompressPalmDoc(stream),
        [0x41, 0x42, 0x43, 0x44, 0x20, 0x40, 0x43, 0x44, 0x20, 0x40],
      );
    });

    test('decompressPalmDoc handles overlapping (RLE) backreferences', () {
      // 0x01 run of 2: 'AA' then backref m=1, n=5: code = 0x8000 | (1<<3) | 2
      // -> repeats 'A' 5 times.
      final stream = Uint8List.fromList([0x01, 0x41, 0x41, 0x80, 0x0A]);
      expect(
        decompressPalmDoc(stream),
        [0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41],
      );
    });
  });

  group('buildMobi', () {
    test('palm database header: BOOKMOBI magic and record list', () {
      final bytes = buildMobi(const MobiBook(
        title: 'A Test Book',
        author: 'Jane Doe',
        contentHtml: '<html><body><p>Hello world</p></body></html>',
      ));
      expect(_ascii(bytes, 60, 68), 'BOOKMOBI');
      final numRecords = _u16(bytes, 76);
      expect(numRecords, greaterThanOrEqualTo(2));
      // First record must start right after the 78-byte header + record list.
      expect(_u32(bytes, 78), 78 + numRecords * 8);
      // Record offsets must be in order, contiguous and inside the file.
      var expectedOffset = 78 + numRecords * 8;
      for (var i = 0; i < numRecords; i++) {
        final offset = _u32(bytes, 78 + i * 8);
        expect(offset, expectedOffset, reason: 'record $i offset');
        final end = i == numRecords - 1
            ? bytes.length
            : _u32(bytes, 78 + (i + 1) * 8);
        expect(end, greaterThanOrEqualTo(offset));
        expect(end, lessThanOrEqualTo(bytes.length));
        expectedOffset = end;
      }
    });

    test('palm name is the truncated, null-padded, ascii title', () {
      final bytes = buildMobi(const MobiBook(
        title: 'My Book',
        contentHtml: '<html><body><p>x</p></body></html>',
      ));
      // Como Calibre/kindlegen: nombre PalmDB en ASCII, espacios -> '_'.
      expect(_ascii(bytes, 0, 7), 'My_Book');
      expect(bytes[7], 0);
      expect(bytes.sublist(7, 32).every((b) => b == 0), isTrue);
    });

    test('palm name nunca contiene bytes no ASCII (el Kindle rechaza nombres '
        'UTF-8 crudos)', () {
      final bytes = buildMobi(const MobiBook(
        title: 'El secreto del universo y otros ensayos científicos',
        contentHtml: '<html><body><p>x</p></body></html>',
      ));
      // Los 32 bytes del nombre son ASCII puro (espacios y acentos -> '_').
      expect(_ascii(bytes, 0, 32).codeUnits.every((c) => c < 0x80), isTrue);
      expect(_ascii(bytes, 0, 32), startsWith('El_secreto_del_universo'));
      // El título completo con acentos se conserva en el campo "full name".
      final record0 = _record(bytes, 0);
      final titleOffset = _u32(record0, 0x54);
      final titleLength = _u32(record0, 0x58);
      expect(
          utf8.decode(record0.sublist(titleOffset, titleOffset + titleLength)),
          'El secreto del universo y otros ensayos científicos');
    });

    test('MOBI header fields are correct', () {
      final bytes = buildMobi(const MobiBook(
        title: 'T',
        author: 'A',
        contentHtml: '<html><body><p>x</p></body></html>',
      ));
      final record0 = _record(bytes, 0);
      expect(_ascii(record0, 0x10, 0x14), 'MOBI');
      expect(_u32(record0, 0x14), 0xE8); // header length
      expect(_u32(record0, 0x18), 2); // type: book
      expect(_u32(record0, 0x1c), 65001); // utf-8
      expect(_u32(record0, 0x24), 6); // version
      expect(_u32(record0, 0x68), 6); // min version
      expect(_u32(record0, 0x80), 0x50); // EXTH flags: kindlegen/Calibre
      expect(_u32(record0, 0xa8), 0xFFFFFFFF); // no DRM
      // Bit 0 of extra_data_flags: every text record carries the multibyte
      // overlap count byte (as Calibre always writes).
      expect(_u16(record0, 0xf2) & 0x1, 0x1);
      // Without TOC entries there is no NCX index.
      expect(_u32(record0, 0xf4), 0xFFFFFFFF);
      // compression type: 2 = PalmDOC
      expect(_u16(record0, 0x00), 2);
      // text record size
      expect(_u16(record0, 0x0a), 4096);
    });

    test('EXTH contains the author and the full name is the title', () {
      final bytes = buildMobi(const MobiBook(
        title: 'The Title',
        author: 'The Author',
        contentHtml: '<html><body><p>x</p></body></html>',
      ));
      final record0 = _record(bytes, 0);
      final titleOffset = _u32(record0, 0x54);
      final titleLength = _u32(record0, 0x58);
      expect(_ascii(record0, titleOffset, titleOffset + titleLength), 'The Title');
      // EXTH starts right after the 16-byte palm header + 0xE8 MOBI header.
      const exthOffset = 16 + 0xE8;
      expect(_ascii(record0, exthOffset, exthOffset + 4), 'EXTH');
      final count = _u32(record0, exthOffset + 8);
      var pos = exthOffset + 12;
      var foundAuthor = false;
      for (var i = 0; i < count; i++) {
        final type = _u32(record0, pos);
        final size = _u32(record0, pos + 4);
        if (type == 100) {
          foundAuthor = true;
          expect(
            _ascii(record0, pos + 8, pos + size),
            'The Author',
          );
        }
        pos += size;
      }
      expect(foundAuthor, isTrue);
    });

    test('EXTH: bloque alineado a 4 bytes, cdeType "EBOK", título tras el '
        'bloque padded', () {
      final bytes = buildMobi(const MobiBook(
        title: 'The Title',
        author: 'Jane Doe',
        contentHtml: '<html><body><p>x</p></body></html>',
      ));
      final record0 = _record(bytes, 0);
      const exthOffset = 16 + 0xE8;
      expect(_ascii(record0, exthOffset, exthOffset + 4), 'EXTH');
      final exthLength = _u32(record0, exthOffset + 4); // sin padding
      final count = _u32(record0, exthOffset + 8);

      // Recorre las entradas por su longitud explícita.
      var pos = exthOffset + 12;
      var foundAuthor = false;
      var foundCdeType = false;
      var foundCreator = false;
      var foundTitle = false;
      var recordsBytes = 12;
      for (var i = 0; i < count; i++) {
        final type = _u32(record0, pos);
        final size = _u32(record0, pos + 4);
        recordsBytes += size;
        if (type == 100) {
          foundAuthor = true;
          expect(_ascii(record0, pos + 8, pos + size), 'Jane Doe');
        }
        if (type == 501) {
          foundCdeType = true;
          expect(size, 12); // 8 + 4 bytes de datos
          // cdeType es la cadena "EBOK" (ebook), NO el encoding.
          expect(_ascii(record0, pos + 8, pos + size), 'EBOK');
        }
        if (type == 503) {
          foundTitle = true;
          expect(_ascii(record0, pos + 8, pos + size), 'The Title');
        }
        if (type == 204) {
          foundCreator = true;
          expect(_u32(record0, pos + 8), 201); // kindlegen Linux
        }
        pos += size;
      }
      expect(foundAuthor, isTrue);
      expect(foundCdeType, isTrue);
      expect(foundCreator, isTrue);
      expect(foundTitle, isTrue);
      // El campo de longitud excluye el padding final.
      expect(exthLength, recordsBytes);

      // El bloque EXTH (con padding) queda alineado a 4 bytes y el título
      // se coloca justo después: el offset debe ser múltiplo de 4.
      final titleOffset = _u32(record0, 0x54);
      final titleLength = _u32(record0, 0x58);
      expect(titleOffset % 4, 0);
      expect(titleOffset - (exthOffset + exthLength), inInclusiveRange(0, 3));
      expect(_ascii(record0, titleOffset, titleOffset + titleLength),
          'The Title');
    });

    test('primera sección no-libro apunta a FLIS y el rango de imágenes '
        'queda vacío', () {
      final bytes = buildMobi(const MobiBook(
        title: 'T',
        contentHtml: '<html><body><p>x</p></body></html>',
      ));
      final record0 = _record(bytes, 0);
      final numRecords = _u16(bytes, 76);
      // 0x50 first non-book index: el primer registro que no es texto (FLIS;
      // puede haber un registro de padding de 1-3 bytes justo antes).
      expect(_ascii(_record(bytes, _u32(record0, 0x50)), 0, 4), 'FLIS');
      // 0x6c first image index: con libro sin imágenes apunta más allá del
      // último registro (número total de registros).
      expect(_u32(record0, 0x6c), numRecords);
    });

    test('el texto largo se parte en registros de 4096 bytes (menos el '
        'último) y se reensambla byte a byte', () {
      final html = '<html><body><mbp:pagebreak/><h2>C1</h2>'
          '${'<p>abcdefghij</p>' * 600}</body></html>';
      final textBytes = utf8.encode(html);
      final bytes = buildMobi(MobiBook(
        title: 'T',
        contentHtml: html,
      ));
      final record0 = _record(bytes, 0);
      final numTextRecords = _u16(record0, 0x08);
      expect(numTextRecords, greaterThan(1));
      final pieces = <int>[];
      for (var i = 1; i <= numTextRecords; i++) {
        final uncompressed = _textRecord(bytes, i);
        expect(uncompressed.length, lessThanOrEqualTo(4096));
        pieces.addAll(uncompressed);
      }
      // El reader reensambla los registros antes de parsear: el HTML (con
      // etiquetas partidas por el límite de 4096) se recupera íntegro.
      expect(Uint8List.fromList(pieces), textBytes);
    });

    test('caracteres UTF-8 partidos por el límite de 4096 se completan con '
        'overlap bytes y el texto se recupera íntegro (como Calibre)', () {
      // Texto español con acentos: suficientes caracteres multibyte como
      // para que un corte a byte ciego caiga dentro de uno de ellos.
      final accented =
          'El veloz murci\\u00e9lago hind\\u00fa com\\u00eda feliz cardillo y kiwi. ' * 400;
      final html = '<html><body><p>$accented</p></body></html>';
      final textBytes = utf8.encode(html);
      final bytes = buildMobi(MobiBook(
        title: 'T',
        contentHtml: html,
      ));
      final record0 = _record(bytes, 0);
      final numTextRecords = _u16(record0, 0x08);

      final pieces = <int>[];
      for (var i = 1; i <= numTextRecords; i++) {
        final uncompressed = _textRecord(bytes, i);
        // Todos los registros menos el último tienen exactamente 4096 bytes
        // de texto: la posición <-> registro del índice NCX se mantiene en
        // la cuadrícula de 4096.
        expect(uncompressed.length, lessThanOrEqualTo(4096));
        pieces.addAll(uncompressed);
      }
      // El texto reensamblado es UTF-8 válido y coincide con el original.
      expect(Uint8List.fromList(pieces), textBytes);
      expect(() => utf8.decode(Uint8List.fromList(pieces),
          allowMalformed: false), returnsNormally);
    });

    test('text records decompress exactly to the content html', () {
      const html = '<html><body>'
          '<mbp:pagebreak/><h2>One</h2><p>Alpha</p>'
          '<mbp:pagebreak/><h2>Two</h2><p>Beta \\u00e9\\u00f1\\u00fc</p>'
          '</body></html>';
      final textBytes = utf8.encode(html);
      final bytes = buildMobi(const MobiBook(
        title: 'T',
        contentHtml: html,
      ));
      final record0 = _record(bytes, 0);
      // text length in the palm doc header == utf-8 byte length
      expect(_u32(record0, 0x04), textBytes.length);
      // Record 0 carries no text: it ends right after the title, only
      // padded to a 4-byte boundary.
      final titleOffset = _u32(record0, 0x54);
      final titleLength = _u32(record0, 0x58);
      expect(record0.length - (titleOffset + titleLength), lessThan(4));

      // Calibre/KindleUnpack assemble the document from sections 1..N.
      final numTextRecords = _u16(record0, 0x08);
      expect(numTextRecords, greaterThanOrEqualTo(1));
      final pieces = <int>[];
      for (var i = 1; i <= numTextRecords; i++) {
        pieces.addAll(_textRecord(bytes, i));
      }
      expect(Uint8List.fromList(pieces), textBytes);
    });

    test('calibre-style layout: text in records 1..N plus FLIS/FCIS/EOF', () {
      const html = '<html><body><p>Hello Kindle world!</p></body></html>';
      final textBytes = utf8.encode(html);
      final bytes = buildMobi(const MobiBook(
        title: 'T',
        author: 'A',
        contentHtml: html,
      ));
      final record0 = _record(bytes, 0);
      final numTextRecords = _u16(record0, 0x08);
      final numRecords = _u16(bytes, 76);
      // record 0 + N text records + (padding?) + FLIS + FCIS + EOF
      var recordsSize = 0;
      for (var i = 1; i <= numTextRecords; i++) {
        recordsSize += _record(bytes, i).length;
      }
      final padding = recordsSize % 4 != 0 ? 1 : 0;
      expect(numRecords, numTextRecords + 4 + padding);

      // The whole document is reconstructed from sections 1..N.
      final pieces = <int>[];
      for (var i = 1; i <= numTextRecords; i++) {
        pieces.addAll(_textRecord(bytes, i));
      }
      expect(Uint8List.fromList(pieces), textBytes);

      // Trailing records are FLIS, FCIS and the EOF marker.
      expect(_ascii(_record(bytes, numRecords - 3), 0, 4), 'FLIS');
      expect(_ascii(_record(bytes, numRecords - 2), 0, 4), 'FCIS');
      expect(_record(bytes, numRecords - 1),
          [0xE9, 0x8E, 0x0D, 0x0A]);
      // FCIS embeds the uncompressed text length at offset 20.
      expect(_u32(_record(bytes, numRecords - 2), 20), textBytes.length);

      // Content record range in the MOBI header.
      expect(_u16(record0, 0xc0), 1); // first content record
      expect(_u16(record0, 0xc2), numTextRecords); // last content record
      // FCIS/FLIS record numbers.
      expect(_u32(record0, 0xc8), numRecords - 2); // fcis
      expect(_u32(record0, 0xd0), numRecords - 3); // flis
    });

    test('no images: first_image_record points past the last record so no '
        'metadata record is decoded as an image', () {
      final bytes = buildMobi(const MobiBook(
        title: 'T',
        contentHtml: '<html><body><p>x</p></body></html>',
      ));
      final record0 = _record(bytes, 0);
      final numRecords = _u16(bytes, 76);
      final firstImage = _u32(record0, 0x6c);
      final firstNonText = _u32(record0, 0x50);
      // Calibre writes `first_image_record or len(records)`: with no images
      // the field is the total record count (one past the last record), so
      // the image range [first_image, first_nontext) is empty and no reader
      // tries to render FLIS/FCIS/EOF as an image (the Kindle shows a
      // magnifying glass for such broken images).
      expect(firstImage, numRecords);
      expect(firstImage, greaterThanOrEqualTo(firstNonText));
      // FLIS is still the first non-text record (right after the text).
      expect(firstNonText, greaterThan(_u16(record0, 0x08)));
    });

    test('empty content still produces a valid multi-record mobi', () {
      final bytes = buildMobi(const MobiBook(
        title: 'Empty',
        contentHtml: '',
      ));
      final numRecords = _u16(bytes, 76);
      expect(numRecords, greaterThanOrEqualTo(4));
      final record0 = _record(bytes, 0);
      expect(_u32(record0, 0x04), 0); // text length 0
      expect(_u16(record0, 0x08), greaterThanOrEqualTo(1));
    });
  });

  group('NCX index', () {
    // The TOC offsets below are the UTF-8 byte positions of each `<h2>`.
    const html = '<html><body>'
        '<h1>Title</h1>'
        '<mbp:pagebreak/><h2>Chapter One</h2><p>Alpha</p>'
        '<mbp:pagebreak/><h2>Chapter Two</h2><p>Beta \\u00e9\\u00f1\\u00fc</p>'
        '</body></html>';
    late Uint8List textBytes;

    setUp(() {
      textBytes = utf8.encode(html);
    });

    Uint8List buildWithToc() => buildMobi(MobiBook(
          title: 'T',
          author: 'A',
          contentHtml: html,
          tocEntries: [
            MobiTocEntry(
                title: 'Chapter One', offset: byteIndexOf(html, '<h2>Chapter One')),
            MobiTocEntry(
                title: 'Chapter Two', offset: byteIndexOf(html, '<h2>Chapter Two')),
          ],
        ));

    test('writes the NCX index: extra_data_flags, ncx field and INDX records',
        () {
      final bytes = buildWithToc();
      final record0 = _record(bytes, 0);
      // Bit 0 (multibyte overlap) + bit 1 (TBS) as Calibre writes.
      expect(_u16(record0, 0xf2), 0x3);
      final ncx = _u32(record0, 0xf4);
      expect(ncx, isNot(0xFFFFFFFF));
      expect(_u32(record0, 0x50), ncx); // first non-text == NCX header
      expect(_ascii(_record(bytes, ncx), 0, 4), 'INDX');
      // Entries record right after, then the CNCX string record.
      expect(_ascii(_record(bytes, ncx + 1), 0, 4), 'INDX');
      expect(_ascii(_record(bytes, ncx + 2), 0, 4), isNot('INDX'));
      // Last content record covers the last index record.
      expect(_u16(record0, 0xc2), greaterThanOrEqualTo(ncx));
    });

    test('index entries point at the chapter headings and lengths span to '
        'the next entry', () {
      final bytes = buildWithToc();
      final record0 = _record(bytes, 0);
      final ncx = _u32(record0, 0xf4);
      final entries = _parseIndexEntries(bytes, ncx);
      expect(entries.length, 2);

      final expected0 = byteIndexOf(html, '<h2>Chapter One');
      final expected1 = byteIndexOf(html, '<h2>Chapter Two');
      expect(entries[0].offset, expected0);
      expect(entries[1].offset, expected1);
      expect(entries[0].size, expected1 - expected0);
      expect(entries[1].size, textBytes.length - expected1);

      // Every entry's offset points at a real `<h2>` in the reconstructed
      // text.
      final pieces = <int>[];
      for (var i = 1; i <= _u16(record0, 0x08); i++) {
        pieces.addAll(_textRecord(bytes, i));
      }
      final text = Uint8List.fromList(pieces);
      expect(_ascii(text, expected0, expected0 + 3), '<h2');
      expect(_ascii(text, expected1, expected1 + 3), '<h2');
    });

    test('CNCX record holds the chapter titles with vwi lengths', () {
      final bytes = buildWithToc();
      final record0 = _record(bytes, 0);
      final ncx = _u32(record0, 0xf4);
      final cncx = _record(bytes, ncx + 2);
      final strings = <String>[];
      var pos = 0;
      while (pos < cncx.length) {
        final (len, consumed) = _decint(cncx, pos);
        if (len == 0) {
          break; // padding
        }
        pos += consumed;
        strings.add(utf8.decode(cncx.sublist(pos, pos + len)));
        pos += len;
      }
      expect(strings, contains('Chapter One'));
      expect(strings, contains('Chapter Two'));
    });

    test('every text record carries a trailing byte sequence (TBS) when the '
        'index exists', () {
      final bytes = buildWithToc();
      final record0 = _record(bytes, 0);
      final numTextRecords = _u16(record0, 0x08);
      // extra_data_flags bit 1 set -> each record ends with <tbs><size>.
      for (var i = 1; i <= numTextRecords; i++) {
        final record = _record(bytes, i);
        final size = _trailingSize(record);
        // The size vwi covers the TBS data + the vwi itself.
        expect(size, greaterThanOrEqualTo(1));
        expect(size, lessThan(record.length));
        // The remaining record decompresses cleanly (no trailing bytes leak
        // into the PalmDOC stream).
        final stripped =
            Uint8List.fromList(record.sublist(0, record.length - size));
        final mb = (stripped[stripped.length - 1] & 0x3) + 1;
        final compressed =
            Uint8List.fromList(stripped.sublist(0, stripped.length - mb));
        expect(() => decompressPalmDoc(compressed), returnsNormally);
      }
    });

    test('EXTH 116 (start reading) is written with the body start offset', () {
      final bytes = buildMobi(const MobiBook(
        title: 'T',
        contentHtml: html,
        tocEntries: [
          MobiTocEntry(title: 'Chapter One', offset: 30),
        ],
        bodyStartOffset: 109,
      ));
      final record0 = _record(bytes, 0);
      const exthOffset = 16 + 0xE8;
      final count = _u32(record0, exthOffset + 8);
      var pos = exthOffset + 12;
      var found116 = false;
      for (var i = 0; i < count; i++) {
        final type = _u32(record0, pos);
        final size = _u32(record0, pos + 4);
        if (type == 116) {
          found116 = true;
          expect(_u32(record0, pos + 8), 109);
        }
        pos += size;
      }
      expect(found116, isTrue);
    });

    test('a single TOC entry still produces an index', () {
      final bytes = buildMobi(const MobiBook(
        title: 'T',
        contentHtml: '<html><body><h2>Solo</h2><p>x</p></body></html>',
        tocEntries: [MobiTocEntry(title: 'Solo', offset: 16)],
      ));
      final record0 = _record(bytes, 0);
      expect(_u32(record0, 0xf4), isNot(0xFFFFFFFF));
      expect(_u16(record0, 0xf2), 0x3);
    });

    test('invalid toc entries (empty title or out of range) produce no index',
        () {
      final bytes = buildMobi(const MobiBook(
        title: 'T',
        contentHtml: '<html><body><p>x</p></body></html>',
        tocEntries: [
          MobiTocEntry(title: '   ', offset: 10),
          MobiTocEntry(title: 'Bad', offset: 9999),
        ],
      ));
      final record0 = _record(bytes, 0);
      expect(_u32(record0, 0xf4), 0xFFFFFFFF);
      expect(_u16(record0, 0xf2) & 0x2, 0x0); // no TBS bit
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List _bytesFromEscaped(String raw) {
  final out = <int>[];
  for (var i = 0; i < raw.length; i++) {
    final c = raw.codeUnitAt(i);
    if (c == 0x5C /* \ */ && i + 3 < raw.length && raw[i + 1] == 'x') {
      out.add(int.parse(raw.substring(i + 2, i + 4), radix: 16));
      i += 3;
    } else {
      out.add(c);
    }
  }
  return Uint8List.fromList(out);
}

Uint8List _record(Uint8List bytes, int index) {
  final numRecords = _u16(bytes, 76);
  final offset = _u32(bytes, 78 + index * 8);
  final end = index == numRecords - 1
      ? bytes.length
      : _u32(bytes, 78 + (index + 1) * 8);
  return Uint8List.fromList(bytes.sublist(offset, end));
}

/// Decompresses text record [index] the way a MOBI reader does: strips the
/// trailing byte sequences (TBS) and the multibyte overlap + count byte per
/// the `extra_data_flags` in the header, then decompresses what remains.
Uint8List _textRecord(Uint8List bytes, int index) {
  final record0 = _record(bytes, 0);
  final extraFlags = _u16(record0, 0xf2);
  var data = _record(bytes, index);

  // Strip TBS entries first (one per set bit of extra_data_flags >> 1).
  var flags = extraFlags >> 1;
  while (flags > 0) {
    if (flags & 0x1 == 0x1) {
      final num = _trailingSize(data);
      data = Uint8List.fromList(data.sublist(0, data.length - num));
    }
    flags >>= 1;
  }
  // Then the multibyte overlap + count byte.
  if (extraFlags & 0x1 == 0x1) {
    final num = (data[data.length - 1] & 0x3) + 1;
    data = Uint8List.fromList(data.sublist(0, data.length - num));
  }
  return decompressPalmDoc(data);
}

/// Replicates the reader's `getSizeOfTrailingDataEntry`: reads the backward
/// vwi at the end of [data] (scanning the last 4 bytes, resetting at every
/// byte with bit 8 set), returning the total size of the trailing entry.
int _trailingSize(Uint8List data) {
  var num = 0;
  final start = data.length > 4 ? data.length - 4 : 0;
  for (var i = start; i < data.length; i++) {
    final v = data[i];
    if (v & 0x80 != 0) {
      num = 0;
    }
    num = (num << 7) | (v & 0x7f);
  }
  return num;
}

/// Decodes a forward variable-width integer at [pos] in [data].
(int, int) _decint(Uint8List data, int pos) {
  var value = 0;
  var i = pos;
  while (true) {
    final b = data[i];
    i += 1;
    value = (value << 7) | (b & 0x7f);
    if (b & 0x80 != 0) {
      break;
    }
  }
  return (value, i - pos);
}

/// Parses the index entries from the NCX index at [ncx], replicating
/// KindleUnpack's `MobiIndex.getIndexData` for a flat book. Returns
/// (offset, size, labelOffset) per entry.
List<({int offset, int size, int labelOffset})> _parseIndexEntries(
    Uint8List bytes, int ncx) {
  final headerRecord = _record(bytes, ncx);
  final numIndexRecords = _u32(headerRecord, 4 + 20); // 'count' at byte 24
  expect(numIndexRecords, greaterThanOrEqualTo(1));
  // control byte count from the TAGX block (offset 192 in the header).
  final controlByteCount = _u32(headerRecord, 192 + 8);

  final entriesRecord = _record(bytes, ncx + 1);
  final idxtPos = _u32(entriesRecord, 20);
  final entryCount = _u32(entriesRecord, 24);
  final positions = <int>[];
  for (var j = 0; j < entryCount; j++) {
    positions.add(_u16(entriesRecord, idxtPos + 4 + 2 * j));
  }
  positions.add(idxtPos);

  final out = <({int offset, int size, int labelOffset})>[];
  for (var j = 0; j < entryCount; j++) {
    final startPos = positions[j];
    final endPos = positions[j + 1];
    final textLen = entriesRecord[startPos];
    final p = startPos + 1 + textLen; // entry type (control) byte
    final et = entriesRecord[p];
    expect(et & 0x0F, 0x0F); // flat book: tags 1..4 present
    final values = <int>[];
    var q = p + controlByteCount;
    while (q < endPos && values.length < 4) {
      final (value, consumed) = _decint(entriesRecord, q);
      values.add(value);
      q += consumed;
    }
    expect(values.length, 4);
    out.add(
        (offset: values[0], size: values[1], labelOffset: values[2]));
  }
  return out;
}

/// Byte offset of [needle] inside the UTF-8 encoding of [haystack].
int byteIndexOf(String haystack, String needle) {
  final hayBytes = utf8.encode(haystack);
  final needleBytes = utf8.encode(needle);
  if (needleBytes.isEmpty || needleBytes.length > hayBytes.length) {
    return -1;
  }
  outer:
  for (var i = 0; i <= hayBytes.length - needleBytes.length; i++) {
    for (var j = 0; j < needleBytes.length; j++) {
      if (hayBytes[i + j] != needleBytes[j]) {
        continue outer;
      }
    }
    return i;
  }
  return -1;
}

int _u16(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _u32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

String _ascii(Uint8List bytes, int start, int end) =>
    ascii.decode(bytes.sublist(start, end), allowInvalid: true);
