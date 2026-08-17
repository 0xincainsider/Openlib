// Dart imports:
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Pure-Dart writer for MOBI 6 (Mobipocket) ebook files.
///
/// The binary layout follows the format as written by Calibre
/// (`ebooks/mobi/writer2/`) and read by KindleUnpack (`lib/mobi_header.py`):
///
///   * a Palm database ("PalmDOC") wrapper with type `BOOK` / creator `MOBI`,
///   * PalmDOC compression (type 2) with literal, space+letter and 2-byte
///     back-reference codes (byte-compatible with Calibre `py_compress_doc`),
///   * a 0xE8-byte MOBI header, an EXTH metadata block and the full title,
///   * text records of exactly 4096 bytes (uncompressed) that may end in the
///     middle of a UTF-8 character: the truncated tail is appended raw after
///     the compressed data together with a 1-byte overlap count
///     (`extra_data_flags` bit 0), exactly like Calibre's `create_text_record`,
///   * a trailing byte sequence (TBS) at the end of every text record
///     (`extra_data_flags` bit 1) that indexes which TOC entries start, end,
///     complete or span each record,
///   * an NCX index (INDX header record + INDX entries record + CNCX string
///     records) wired into the MOBI header's `ncx_index` (0xf4) and
///     `first_non_text_record` (0x50) fields when the book has a TOC.
///
/// The NCX index is what modern Kindle firmwares use to paginate a book: a
/// MOBI6 file without it (as the previous writer emitted) opens on the Kindle
/// but renders blank pages. The layout replicates Calibre's `indexer.py`
/// (`create_header`, `create_index_record`, `CNCX`, `TBS.book_tbs`) and
/// `writer2/main.py` (`generate_text`, `generate_index`, `generate_record0`).
///
/// [MobiBook.contentHtml] must be a complete HTML document wrapped in
/// `<html>...<body>...</body></html>` (see [buildMobiHtml] in
/// `convert_to_mobi.dart`); the records may split HTML tags and UTF-8
/// characters at the 4096-byte boundaries because readers reassemble the
/// full text before parsing it (the overlap bytes complete split characters).

const int _mobiHeaderLength = 0xE8;
const int _palmDocRecordSize = 4096;
/// Seconds between the Palm epoch (1904-01-01) and the Unix epoch.
const int _palmTimeEpochOffset = 2082844800;

/// One entry of the table of contents, used to build the NCX index.
///
/// [offset] is the byte offset (in the UTF-8 encoded [MobiBook.contentHtml])
/// where the chapter's content starts, and [title] is the label shown in the
/// TOC. Offsets must be strictly increasing for the length computation to
/// make sense; `buildMobi` sorts them like Calibre does.
class MobiTocEntry {
  final String title;
  final int offset;

  const MobiTocEntry({required this.title, required this.offset});
}

/// The content of a book to write as a MOBI file.
class MobiBook {
  final String title;
  final String? author;
  /// The rawml HTML stored in the text records (see [buildMobiHtml]).
  final String contentHtml;
  final DateTime? createdAt;

  /// TOC entries (chapter titles + byte offsets in [contentHtml]) used to
  /// build the NCX index. Empty means "no index": the book is written as a
  /// single text flow without a table of contents.
  final List<MobiTocEntry> tocEntries;

  /// Byte offset in [contentHtml] of the first content after `<body>`. When
  /// set, it is written as EXTH record 116 (start reading), so the Kindle
  /// opens the book at the beginning of the content instead of at the first
  /// TOC entry.
  final int? bodyStartOffset;

  const MobiBook({
    required this.title,
    this.author,
    required this.contentHtml,
    this.createdAt,
    this.tocEntries = const [],
    this.bodyStartOffset,
  });
}

/// Builds a complete MOBI 6 file from [book].
///
/// Layout (matching what Calibre writes and both Calibre's and KindleUnpack's
/// readers expect): record 0 holds only the headers (PalmDOC + MOBI + EXTH +
/// title), the uncompressed text is split into 4096-byte chunks that become
/// records 1..N (each compressed independently, with overlap bytes + TBS
/// appended), the NCX index records come next when the book has a TOC, and
/// the file ends with the FLIS, FCIS and EOF records.
Uint8List buildMobi(MobiBook book) {
  final contentBytes = utf8.encode(book.contentHtml);
  final titleBytes = utf8.encode(book.title);
  final palmTime =
      (book.createdAt ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 +
          _palmTimeEpochOffset;

  // ---- text records -----------------------------------------------------
  //
  // Each record holds exactly 4096 bytes of uncompressed text (less for the
  // last one), exactly like Calibre's `create_text_record`. A 4096-byte
  // chunk may end in the middle of a UTF-8 character; the bytes needed to
  // complete it are taken from the NEXT chunk and appended raw after the
  // compressed data, together with a 1-byte count (0-3). The next chunk
  // starts at the exact 4096 boundary, so it begins with those same bytes.
  // This keeps the record <-> text-position mapping on the 4096 grid, which
  // the NCX index and the Kindle's position-based navigation rely on.
  final textRecords = <Uint8List>[];
  var recordsSize = 0;
  var start = 0;
  while (start < contentBytes.length) {
    final end = min(start + _palmDocRecordSize, contentBytes.length);
    final data = Uint8List.fromList(contentBytes.sublist(start, end));
    final overlapLength = end < contentBytes.length
        ? _overlapLength(contentBytes, end)
        : 0;
    final record = BytesBuilder()
      ..add(compressPalmDoc(data))
      ..add(contentBytes.sublist(end, end + overlapLength))
      ..addByte(overlapLength);
    textRecords.add(record.toBytes());
    recordsSize += textRecords.last.length;
    start = end;
  }
  if (textRecords.isEmpty) {
    // Empty content: one empty text record (its single count byte is
    // stripped by readers before decompression).
    textRecords.add(Uint8List.fromList(const [0]));
    recordsSize += 1;
  }
  final numTextRecords = textRecords.length;

  // ---- NCX index --------------------------------------------------------
  //
  // Only built when the book has valid TOC entries. Replicates Calibre's
  // `Indexer`: CNCX string records, a main INDX header record, one INDX
  // entries record, and a trailing byte sequence appended to every text
  // record (so the firmware can map TOC positions to records).
  final indexRecords = <Uint8List>[];
  Uint8List? paddingRecord;
  var ncxIndex = 0xFFFFFFFF;
  var extraDataFlags = 0x1; // bit 0: multibyte overlap bytes present

  // Calibre pads so the first non-text record starts on a 4-byte boundary
  // (the pad record is added in `generate_text`, index or not).
  if (recordsSize % 4 != 0) {
    paddingRecord = Uint8List.fromList(List.filled(recordsSize % 4, 0));
  }

  final toc = _normalizeToc(book.tocEntries, contentBytes.length);
  if (toc.length > 1 || (toc.length == 1 && toc.first.offset < contentBytes.length)) {
    final cncx = _buildCncx(toc.map((e) => e.title).toList());
    final entries = <_IndexEntry>[];
    for (var i = 0; i < toc.length; i++) {
      final size = i + 1 < toc.length
          ? toc[i + 1].offset - toc[i].offset
          : contentBytes.length - toc[i].offset;
      if (size <= 0) {
        continue; // skip empty entries, like Calibre's create_book_index
      }
      entries.add(_IndexEntry(
        offset: toc[i].offset,
        size: size,
        labelOffset: cncx.labels[toc[i].title] ?? 0,
      ));
    }
    if (entries.isNotEmpty) {
      // Reset lengths in case any entry was removed above.
      for (var i = 0; i < entries.length; i++) {
        final size = i + 1 < entries.length
            ? entries[i + 1].offset - entries[i].offset
            : contentBytes.length - entries[i].offset;
        entries[i].size = size;
      }
      for (var i = 0; i < entries.length; i++) {
        entries[i].index = i;
      }

      // TBS for every text record (indexed by record number 1..N).
      final tbsList = _calculateTrailingByteSequences(entries, numTextRecords);
      for (var i = 0; i < numTextRecords; i++) {
        textRecords[i] = Uint8List.fromList(
            [...textRecords[i], ...encodeTrailingData(tbsList[i])]);
      }

      final lastEntry = entries.last;
      indexRecords.add(_buildIndexHeader(
        numEntries: entries.length,
        lastIndex: lastEntry.index,
        cncxRecordCount: cncx.records.length,
      ));
      indexRecords.add(_buildIndexRecord(entries));
      indexRecords.addAll(cncx.records);

      ncxIndex = 1 + numTextRecords + (paddingRecord != null ? 1 : 0);
      extraDataFlags |= 0x2; // bit 1: TBS present
    }
  }

  final exth = _buildExth(book.author, book.title, book.bodyStartOffset);
  final titleOffset = 16 + _mobiHeaderLength + exth.length;

  // Trailing records, byte-identical to Calibre's writer (FLIS, FCIS, EOF).
  final flisRecord = _buildFlis();
  final fcisRecord = _buildFcis(contentBytes.length);
  final eofRecord = Uint8List.fromList(const [0xE9, 0x8E, 0x0D, 0x0A]);

  // ---- record 0: PalmDOC header + MOBI header + EXTH + title (no text) ----
  final record0 = BytesBuilder();
  // PalmDOC header (16 bytes).
  _putUint16(record0, 2); // compression type: PalmDOC
  _putUint16(record0, 0); // unused
  _putUint32(record0, contentBytes.length); // uncompressed text length
  _putUint16(record0, numTextRecords); // text record count
  _putUint16(record0, _palmDocRecordSize); // max record size
  _putUint16(record0, 0); // encryption: none
  _putUint16(record0, 0); // unused

  // MOBI header (0xE8 bytes, offsets relative to the start of record 0).
  record0.add(utf8.encode('MOBI'));
  _putUint32(record0, _mobiHeaderLength); // 0x14
  _putUint32(record0, 2); // 0x18 type: MOBI book
  _putUint32(record0, 65001); // 0x1c text encoding: utf-8
  _putUint32(record0, Random().nextInt(0x7FFFFFFF) | 1); // 0x20 unique id
  _putUint32(record0, 6); // 0x24 version
  for (var i = 0; i < 10; i++) {
    _putUint32(record0, 0xFFFFFFFF); // 0x28-0x4f index record numbers
  }
  _putUint32(record0, indexRecords.isEmpty ? 0xFFFFFFFF : ncxIndex); // 0x50
  _putUint32(record0, titleOffset); // 0x54 full name offset
  _putUint32(record0, titleBytes.length); // 0x58 full name length
  _putUint32(record0, 0x0409); // 0x5c language: en-US
  _putUint32(record0, 0); // 0x60 input language
  _putUint32(record0, 0); // 0x64 output language
  _putUint32(record0, 6); // 0x68 minimum version
  // 0x6c first image record: this book has no images, so write the total
  // record count (one past the last record) exactly like Calibre
  // (`first_image_record or len(records)`), patched below once the record
  // list is complete. Pointing it at a metadata record (FLIS/FCIS) makes
  // strict readers (the Kindle) try to decode it as an image and render its
  // broken-image magnifying glass, which can block reading entirely.
  _putUint32(record0, 0); // 0x6c first image record (patched below)
  _putUint32(record0, 0); // 0x70 huff record offset
  _putUint32(record0, 0); // 0x74 huff record count
  _putUint32(record0, 0); // 0x78 huff table offset
  _putUint32(record0, 0); // 0x7c huff table length
  // 0x80 EXTH flags: bit 6 (EXTH present) + bit 4, exactly what kindlegen
  // and Calibre write (0x50); the Kindle firmware expects both bits.
  _putUint32(record0, 0x50);
  for (var i = 0; i < 8; i++) {
    _putUint32(record0, 0); // 0x84-0xa3 unknown
  }
  _putUint32(record0, 0xFFFFFFFF); // 0xa4 DRM offset
  _putUint32(record0, 0xFFFFFFFF); // 0xa8 DRM count
  _putUint32(record0, 0); // 0xac DRM size
  _putUint32(record0, 0); // 0xb0 DRM flags
  for (var i = 0; i < 3; i++) {
    _putUint32(record0, 0); // 0xb4-0xbf unknown
  }
  _putUint16(record0, 1); // 0xc0 first content record
  _putUint16(record0, indexRecords.isEmpty
      ? numTextRecords
      : ncxIndex + indexRecords.length - 1); // 0xc2 last content record
  _putUint32(record0, 1); // 0xc4 unknown (Calibre writes 0x00000001)
  _putUint32(record0, 0); // 0xc8 FCIS record (patched below)
  _putUint32(record0, 1); // 0xcc FCIS count
  _putUint32(record0, 0); // 0xd0 FLIS record (patched below)
  _putUint32(record0, 1); // 0xd4 FLIS count
  _putUint32(record0, 0); // 0xd8 unknown
  _putUint32(record0, 0); // 0xdc unknown
  _putUint32(record0, 0xFFFFFFFF); // 0xe0 SRCS offset
  _putUint32(record0, 0); // 0xe4 SRCS count
  _putUint32(record0, 0xFFFFFFFF); // 0xe8 unknown
  _putUint32(record0, 0xFFFFFFFF); // 0xec unknown
  _putUint32(record0, extraDataFlags); // 0xf0 extra record data flags
  _putUint32(record0, ncxIndex); // 0xf4 primary index / NCX record

  record0.add(exth);
  record0.add(titleBytes);

  // Pad record 0 to a 4-byte boundary (as Calibre's `align_block` does).
  var record0Bytes = record0.toBytes();
  final pad = record0Bytes.length % 4;
  if (pad != 0) {
    record0Bytes =
        Uint8List.fromList([...record0Bytes, ...List.filled(4 - pad, 0)]);
  }

  final records = <Uint8List>[
    record0Bytes,
    ...textRecords,
    if (paddingRecord != null) paddingRecord,
    ...indexRecords,
    flisRecord,
    fcisRecord,
    eofRecord,
  ];

  // Patch FCIS/FLIS record numbers (their positions are only known now).
  final flisIndex = records.length - 3;
  final fcisIndex = records.length - 2;
  _patchUint32(record0Bytes, 0xc8, fcisIndex);
  _patchUint32(record0Bytes, 0xd0, flisIndex);
  _patchUint32(record0Bytes, 0x6c, records.length); // first image: none
  _patchUint32(record0Bytes, 0x50, indexRecords.isEmpty
      ? flisIndex
      : ncxIndex); // first non-text record

  // ---- Palm database header (78 bytes) + record info list ----
  final out = BytesBuilder();
  out.add(_palmNameBytes(book.title)); // 32-byte name, null padded
  _putUint16(out, 0); // attributes
  _putUint16(out, 0); // version
  _putUint32(out, palmTime); // creation date
  _putUint32(out, palmTime); // modification date
  _putUint32(out, palmTime); // last backup date
  _putUint32(out, 0); // modification number
  _putUint32(out, 0); // appInfoID
  _putUint32(out, 0); // sortInfoID
  out.add(utf8.encode('BOOK')); // type
  out.add(utf8.encode('MOBI')); // creator
  _putUint32(out, 0); // uniqueIDseed
  _putUint32(out, 0); // nextRecordListID
  _putUint16(out, records.length); // number of records

  var offset = 78 + records.length * 8;
  for (var i = 0; i < records.length; i++) {
    _putUint32(out, offset);
    out.addByte(0); // record attributes
    out.addByte((i >> 16) & 0xFF);
    out.addByte((i >> 8) & 0xFF);
    out.addByte(i & 0xFF); // 3-byte unique id
    offset += records[i].length;
  }
  for (final record in records) {
    out.add(record);
  }
  return out.toBytes();
}

// ---------------------------------------------------------------------------
// NCX index
// ---------------------------------------------------------------------------

/// A TOC entry as it is stored in the NCX index (with a computed length and
/// position in the entry list).
class _IndexEntry {
  final int offset;
  int size;
  final int labelOffset;
  int index = 0;

  _IndexEntry({
    required this.offset,
    required this.size,
    required this.labelOffset,
  });
}

/// Filters and orders the book's TOC entries: keeps entries with a non-empty
/// title and an offset inside the text, drops duplicates by offset (like
/// Calibre's `seen` set) and sorts by offset (like `create_book_index`).
List<MobiTocEntry> _normalizeToc(List<MobiTocEntry> toc, int textLength) {
  final seen = <int>{};
  final result = <MobiTocEntry>[];
  for (final entry in toc) {
    final title = entry.title.trim();
    if (title.isEmpty || entry.offset < 0 || entry.offset >= textLength) {
      continue;
    }
    if (!seen.add(entry.offset)) {
      continue;
    }
    result.add(MobiTocEntry(title: title, offset: entry.offset));
  }
  result.sort((a, b) => a.offset.compareTo(b.offset));
  return result;
}

/// Builds the CNCX (index string) records and a map from each title to its
/// byte offset inside the concatenated CNCX stream (used as `labelOffset` in
/// the index entries). Replicates Calibre's `CNCX` class: each record holds
/// `<vwi length><utf-8 string>` pairs, is split at 0x10000-1024 bytes and
/// aligned to 4 bytes; duplicate titles share one offset.
class _CncxResult {
  final List<Uint8List> records;
  final Map<String, int> labels;

  const _CncxResult({required this.records, required this.labels});
}

_CncxResult _buildCncx(List<String> titles) {
  const recordLimit = 0x10000 - 1024;
  const maxStringLength = 500;

  final unique = <String>[];
  for (final title in titles) {
    if (!unique.contains(title)) {
      unique.add(title);
    }
  }

  final records = <BytesBuilder>[];
  final labels = <String, int>{};
  var recordIndex = 0;
  var offsetInRecord = 0;
  var current = BytesBuilder();
  for (final title in unique) {
    final bytes = utf8.encode(
        title.length > maxStringLength ? title.substring(0, maxStringLength) : title);
    final raw = BytesBuilder()
      ..add(encintForward(bytes.length))
      ..add(bytes);
    if (current.length + raw.length > recordLimit) {
      records.add(current);
      current = BytesBuilder();
      recordIndex += 1;
      offsetInRecord = 0;
    }
    current.add(raw.toBytes());
    labels[title] = recordIndex * 0x10000 + offsetInRecord;
    offsetInRecord += raw.length;
  }
  if (records.isEmpty || current.length > 0) {
    records.add(current);
  }
  return _CncxResult(
    records: records.map((b) => _pad4(b.toBytes())).toList(),
    labels: labels,
  );
}

/// The flat-book TAGX block from Calibre's `TAGX.flat_book` property: tags
/// 1 (offset), 2 (size), 3 (label offset), 4 (depth) and the end marker.
Uint8List _buildTagxBlock() {
  final b = BytesBuilder()
    ..add(utf8.encode('TAGX'))
    ..add(_putUint32Bytes(32)) // 12 + 4 bytes per tag x 5 tags
    ..add(_putUint32Bytes(1)); // control byte count
  b.add(const [0x01, 0x01, 0x01, 0x00]);
  b.add(const [0x02, 0x01, 0x02, 0x00]);
  b.add(const [0x03, 0x01, 0x04, 0x00]);
  b.add(const [0x04, 0x01, 0x08, 0x00]);
  b.add(const [0x00, 0x00, 0x00, 0x01]);
  return b.toBytes();
}

/// The main INDX header record, replicating Calibre's `Indexer.create_header`
/// for a flat (non-periodical) book.
Uint8List _buildIndexHeader({
  required int numEntries,
  required int lastIndex,
  required int cncxRecordCount,
}) {
  final tagx = _buildTagxBlock();
  final b = BytesBuilder()
    ..add(utf8.encode('INDX'))
    ..add(_putUint32Bytes(192)) // header length
    ..add(_putUint32Bytes(0))
    ..add(_putUint32Bytes(0))
    ..add(_putUint32Bytes(2)) // index type
    ..add(_putUint32Bytes(0)) // IDXT offset (patched below)
    ..add(_putUint32Bytes(1)) // number of index records
    ..add(_putUint32Bytes(65001)) // index encoding: utf-8
    ..add(_putUint32Bytes(0xFFFFFFFF))
    ..add(_putUint32Bytes(numEntries))
    ..add(_putUint32Bytes(0)) // ORDT offset
    ..add(_putUint32Bytes(0)) // LIGT offset
    ..add(_putUint32Bytes(0)) // number of LIGT entries
    ..add(_putUint32Bytes(cncxRecordCount))
    ..add(Uint8List(124)) // unknown
    ..add(_putUint32Bytes(192)) // TAGX offset
    ..add(_putUint32Bytes(0))
    ..add(_putUint32Bytes(0))
    ..add(tagx);

  // Index of the last entry in the NCX, hex-encoded with a leading length
  // byte (like Calibre's `encode_number_as_hex`).
  final hex = lastIndex.toRadixString(16).toUpperCase();
  final hexBytes = ascii.encode(hex.length.isOdd ? '0$hex' : hex);
  b.addByte(hexBytes.length);
  b.add(hexBytes);

  _putUint16(b, numEntries); // number of entries in the NCX
  _pad4InPlace(b);

  final idxtOffset = b.length;
  b.add(utf8.encode('IDXT'));
  _putUint16(b, 192 + tagx.length); // offset of the first index entry
  b.addByte(0);

  final out = _pad4(b.toBytes());
  // Patch the IDXT offset (byte 20 of the header).
  out[20] = (idxtOffset >> 24) & 0xFF;
  out[21] = (idxtOffset >> 16) & 0xFF;
  out[22] = (idxtOffset >> 8) & 0xFF;
  out[23] = idxtOffset & 0xFF;
  return out;
}

/// The INDX record holding all index entries, replicating Calibre's
/// `Indexer.create_index_record`: a 192-byte header, the entry bytes, the
/// IDXT block with 2-byte offsets to each entry.
Uint8List _buildIndexRecord(List<_IndexEntry> entries) {
  const headerLength = 192;

  final entryOffsets = <int>[];
  final indexBlockBody = BytesBuilder();
  for (final entry in entries) {
    entryOffsets.add(indexBlockBody.length);
    indexBlockBody.add(_encodeIndexEntry(entry));
  }
  final indexBlock = _pad4(indexBlockBody.toBytes());

  final idxtBody = BytesBuilder()..add(utf8.encode('IDXT'));
  for (final entryOffset in entryOffsets) {
    _putUint16(idxtBody, headerLength + entryOffset);
  }
  final idxtBlock = _pad4(idxtBody.toBytes());

  final header = BytesBuilder()
    ..add(utf8.encode('INDX'))
    ..add(_putUint32Bytes(headerLength))
    ..add(_putUint32Bytes(0))
    ..add(_putUint32Bytes(1)) // index record type
    ..add(_putUint32Bytes(0))
    ..add(_putUint32Bytes(headerLength + indexBlock.length)) // IDXT offset
    ..add(_putUint32Bytes(entries.length))
    ..add(_putUint32Bytes(0xFFFFFFFF))
    ..add(_putUint32Bytes(0xFFFFFFFF))
    ..add(Uint8List(156)); // unknown

  return Uint8List.fromList(
      [...header.toBytes(), ...indexBlock, ...idxtBlock]);
}

/// One index entry for a flat book, replicating Calibre's
/// `IndexEntry.bytestring`: `<hex index><entry type><vwi offset><vwi size>
/// <vwi label offset><vwi depth>`.
Uint8List _encodeIndexEntry(_IndexEntry entry) {
  final hex = entry.index.toRadixString(16).toUpperCase();
  final hexBytes = ascii.encode(hex.length.isOdd ? '0$hex' : hex);
  return (BytesBuilder()
        ..addByte(hexBytes.length)
        ..add(hexBytes)
        ..addByte(0x0F) // entry type: tags 1..4 present
        ..add(encintForward(entry.offset))
        ..add(encintForward(entry.size))
        ..add(encintForward(entry.labelOffset))
        ..add(encintForward(0))) // depth
      .toBytes();
}

// ---------------------------------------------------------------------------
// Trailing byte sequences (TBS)
// ---------------------------------------------------------------------------

/// Computes the TBS for every text record (indexed by record number 1..N),
/// replicating Calibre's `Indexer.calculate_trailing_byte_sequences` +
/// `TBS.book_tbs` for a flat book (all entries at depth 0, the deepest).
///
/// For each record the entries that start, complete, end or span it are
/// classified against the 4096-byte grid of the uncompressed text; the TBS
/// tells the reader which TOC entries are involved in that record, which is
/// how the Kindle maps TOC positions to records when paginating.
List<Uint8List> _calculateTrailingByteSequences(
    List<_IndexEntry> entries, int numTextRecords) {
  final result = <Uint8List>[];
  for (var record = 0; record < numTextRecords; record++) {
    final offset = record * _palmDocRecordSize;
    final nextOffset = offset + _palmDocRecordSize;

    final starts = <_IndexEntry>[];
    final completes = <_IndexEntry>[];
    final ends = <_IndexEntry>[];
    _IndexEntry? spans;
    for (final entry in entries) {
      final entryEnd = entry.offset + entry.size;
      if (entry.offset >= nextOffset) {
        break; // all entries are at the deepest depth
      }
      if (entryEnd <= offset) {
        continue;
      }
      if (entry.offset >= offset) {
        if (entryEnd <= nextOffset) {
          completes.add(entry);
        } else {
          starts.add(entry);
        }
      } else if (entryEnd <= nextOffset) {
        ends.add(entry);
      } else {
        spans = entry;
      }
    }

    Uint8List tbs;
    if (spans != null) {
      // The record is spanned by a single entry.
      tbs = encodeTbs(spans.index, {0x2: 0, 0x1: 0});
    } else if (completes.isEmpty &&
        ((starts.length == 1 && ends.isEmpty) ||
            (ends.length == 1 && starts.isEmpty))) {
      // Exactly one entry starts (or ends) in this record and none completes.
      final node = starts.isNotEmpty ? starts.first : ends.first;
      tbs = encodeTbs(node.index, {0x2: 0});
    } else {
      // Several entries start/complete/end in this record.
      final nodes = [...starts, ...completes, ...ends]
        ..sort((a, b) => a.index.compareTo(b.index));
      if (nodes.isEmpty) {
        tbs = Uint8List(0); // no TOC activity: empty TBS
      } else {
        tbs = encodeTbs(nodes.first.index, {0x2: 0, 0x4: nodes.length});
      }
    }
    result.add(tbs);
  }
  return result;
}

// ---------------------------------------------------------------------------
// PalmDOC compression
// ---------------------------------------------------------------------------

/// Computes how many bytes of the chunk starting at [end] are needed to
/// complete a UTF-8 character truncated at [end] (0-3). The truncated tail
/// bytes are appended raw to the record and repeated at the start of the
/// next record, which is what `extra_data_flags` bit 0 promises readers.
int _overlapLength(Uint8List bytes, int end) {
  if (end <= 0 || end >= bytes.length) {
    return 0;
  }
  // Walk back over continuation bytes to find the character's lead byte.
  var i = end;
  while (i > 0 && (bytes[i - 1] & 0xC0) == 0x80) {
    i--;
  }
  if (i == 0) {
    return 0;
  }
  final lead = bytes[i - 1];
  if (lead < 0x80) {
    return 0; // the character before the cut is pure ASCII
  }
  final int width;
  if (lead >= 0xF0) {
    width = 4;
  } else if (lead >= 0xE0) {
    width = 3;
  } else {
    width = 2;
  }
  final charEnd = i - 1 + width;
  if (charEnd <= end) {
    return 0; // the full character fits before the cut
  }
  return charEnd - end;
}

/// Compresses [data] with the PalmDOC scheme.
///
/// Byte-for-byte compatible with Calibre's `py_compress_doc` reference
/// implementation: literal runs, "space + letter" pairs (0xC0-0xFF) and
/// 2-byte back-references (0x80-0xBF).
Uint8List compressPalmDoc(Uint8List data) {
  final out = BytesBuilder();
  var i = 0;
  final ldata = data.length;
  while (i < ldata) {
    if (i > 10 && (ldata - i) > 10) {
      var match = -1;
      var matchLength = 0;
      for (var j = 10; j > 2; j--) {
        match = _lastIndexOfSub(data, i, j);
        if (match >= 0 && (i - match) <= 2047) {
          matchLength = j;
          break;
        }
        match = -1;
      }
      if (match >= 0) {
        final distance = i - match;
        final code = 0x8000 | ((distance << 3) & 0x3FF8) | (matchLength - 3);
        out.addByte((code >> 8) & 0xFF);
        out.addByte(code & 0xFF);
        i += matchLength;
        continue;
      }
    }
    final ch = data[i];
    i += 1;
    // "space + uppercase letter" pairs collapse into a single byte.
    if (ch == 0x20 && (i + 1) < ldata) {
      final next = data[i];
      if (next >= 0x40 && next < 0x80) {
        out.addByte(next ^ 0x80);
        i += 1;
        continue;
      }
    }
    if (ch == 0 || (ch > 8 && ch < 0x80)) {
      out.addByte(ch); // literal byte
    } else {
      // Run of up to 8 "binary" bytes that cannot be emitted raw.
      var j = i;
      final binaryRun = <int>[ch];
      while (j < ldata && binaryRun.length < 8) {
        final c = data[j];
        if (c == 0 || (c > 8 && c < 0x80)) {
          break;
        }
        binaryRun.add(c);
        j += 1;
      }
      out.addByte(binaryRun.length);
      out.add(binaryRun);
      i += binaryRun.length - 1;
    }
  }
  return out.toBytes();
}

/// Decompresses all text records of a complete MOBI file (as produced by
/// [buildMobi]) and returns the concatenated uncompressed text.
///
/// Mirrors the reader side (KindleUnpack's `getRawML` +
/// `trimTrailingDataEntries`): strips the TBS trailing entries and the
/// multibyte overlap bytes + count byte from every record before
/// decompressing, using `extra_data_flags` (0xf2) from the MOBI header.
Uint8List decompressTextRecords(Uint8List bytes) {
  final record0 = _recordFromPalm(bytes, 0);
  final numTextRecords = _u16At(record0, 0x08);
  final flags = _u16At(record0, 0xf2);
  final multibyte = flags & 1;
  var trailers = 0;
  var f = flags >> 1;
  while (f > 0) {
    if ((f & 1) != 0) {
      trailers += 1;
    }
    f >>= 1;
  }
  final pieces = <int>[];
  for (var i = 1; i <= numTextRecords; i++) {
    var data = _recordFromPalm(bytes, i);
    for (var t = 0; t < trailers; t++) {
      var num = 0;
      for (var v = data.length - 4; v < data.length; v++) {
        final b = data[v < 0 ? 0 : v];
        if ((b & 0x80) != 0) {
          num = 0;
        }
        num = (num << 7) | (b & 0x7f);
      }
      data = Uint8List.fromList(data.sublist(0, data.length - num));
    }
    if (multibyte != 0 && data.isNotEmpty) {
      final num = (data[data.length - 1] & 3) + 1;
      data = Uint8List.fromList(data.sublist(0, data.length - num));
    }
    pieces.addAll(decompressPalmDoc(data));
  }
  return Uint8List.fromList(pieces);
}

Uint8List _recordFromPalm(Uint8List bytes, int index) {
  final numRecords = _u16At(bytes, 76);
  final offset = _u32At(bytes, 78 + index * 8);
  final end = index == numRecords - 1
      ? bytes.length
      : _u32At(bytes, 78 + (index + 1) * 8);
  return Uint8List.fromList(bytes.sublist(offset, end));
}

int _u16At(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _u32At(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// Decompresses PalmDOC-compressed [data].
///
/// Mirrors KindleUnpack's `PalmdocReader` (and Calibre's C decoder):
/// back-references are expanded byte-by-byte so overlapping copies work.
Uint8List decompressPalmDoc(Uint8List data) {
  final out = <int>[];
  var i = 0;
  while (i < data.length) {
    final c = data[i];
    i += 1;
    if (c >= 1 && c <= 8) {
      // Literal run of c bytes.
      for (var j = 0; j < c; j++) {
        out.add(data[i]);
        i += 1;
      }
    } else if (c < 128) {
      out.add(c); // includes 0x00 and 0x09-0x7F literals
    } else if (c >= 192) {
      // Encoded "space + letter" pair.
      out.add(0x20);
      out.add(c ^ 0x80);
    } else {
      // Two-byte back-reference: distance (11 bits) + length-3 (3 bits).
      final c2 = data[i];
      i += 1;
      final code = (c << 8) | c2;
      final distance = (code >> 3) & 0x07FF;
      final length = (code & 7) + 3;
      if (distance == 0 || distance > out.length) {
        throw const FormatException('Invalid PalmDOC back-reference');
      }
      for (var j = 0; j < length; j++) {
        out.add(out[out.length - distance]);
      }
    }
  }
  return Uint8List.fromList(out);
}

/// Last occurrence of `data[start .. start+length)` inside `data[0 .. start)`.
int _lastIndexOfSub(Uint8List data, int start, int length) {
  if (start < length) {
    return -1;
  }
  final needle = Uint8List.fromList(data.sublist(start, start + length));
  for (var pos = start - length; pos >= 0; pos--) {
    var matches = true;
    for (var k = 0; k < length; k++) {
      if (data[pos + k] != needle[k]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return pos;
    }
  }
  return -1;
}

// ---------------------------------------------------------------------------
// Variable-width integers and trailing data
// ---------------------------------------------------------------------------

/// Encodes [value] as a forward variable-width integer (7 bits per byte, bit
/// 8 set on the last byte), byte-compatible with Calibre's `encint` with
/// `forward=True` (used inside index entries and CNCX lengths).
Uint8List encintForward(int value) {
  var byts = <int>[];
  while (true) {
    byts.add(value & 0x7F);
    value >>= 7;
    if (value == 0) {
      break;
    }
  }
  byts[0] |= 0x80;
  byts = byts.reversed.toList();
  return Uint8List.fromList(byts);
}

/// Encodes [value] as a backward variable-width integer (bit 8 set on the
/// first byte), byte-compatible with Calibre's `encint` with
/// `forward=False`. Used as the size of trailing data entries.
Uint8List encintBackward(int value) {
  var byts = <int>[];
  while (true) {
    byts.add(value & 0x7F);
    value >>= 7;
    if (value == 0) {
      break;
    }
  }
  byts[byts.length - 1] |= 0x80;
  byts = byts.reversed.toList();
  return Uint8List.fromList(byts);
}

/// Appends a backwards-encoded size to [raw], producing `<raw><size>` where
/// `size` is a backward vwi equal to the length of the whole returned
/// bytestring (Calibre's `encode_trailing_data`). Readers strip `size` bytes
/// from the end to recover [raw].
Uint8List encodeTrailingData(Uint8List raw) {
  var lsize = 1;
  Uint8List encoded;
  while (true) {
    encoded = encintBackward(raw.length + lsize);
    if (encoded.length == lsize) {
      break;
    }
    lsize += 1;
  }
  return Uint8List.fromList([...raw, ...encoded]);
}

/// Encodes one trailing byte sequence number, replicating Calibre's
/// `encode_tbs` with `flag_size=3`: a "fvwi" whose low 3 bits are flags
/// (`0b010`: entry index value follows, `0b100`: count byte follows,
/// `0b001`: extra value follows), then the extra data in flag order.
Uint8List encodeTbs(int val, Map<int, int> extra) {
  var flags = 0;
  for (final flag in extra.keys) {
    flags |= flag;
  }
  final b = BytesBuilder()..add(encintForward((val << 3) | (flags & 0x7)));
  if (extra.containsKey(0x2)) {
    b.add(encintForward(extra[0x2]!));
  }
  if (extra.containsKey(0x4)) {
    b.addByte(extra[0x4]! & 0xFF);
  }
  if (extra.containsKey(0x1)) {
    b.add(encintForward(extra[0x1]!));
  }
  return b.toBytes();
}

// ---------------------------------------------------------------------------
// EXTH and helpers
// ---------------------------------------------------------------------------

/// Builds the EXTH (extra header) block.
///
/// Layout per the MobileRead MOBI spec: `EXTH` + total length + record count,
/// then one entry per record (`type`, `length`, `data`). The whole block is
/// padded with null bytes to a multiple of four bytes; the padding is NOT
/// included in the header length (readers iterate the entries by their
/// explicit lengths, so entries themselves are not individually padded).
///
/// Emits the records kindlegen/Calibre write for a plain ebook:
///   * type 503 (updated title),
///   * type 100 (author), when known,
///   * type 501 (`cdetype`) = "EBOK" (ebook). The Kindle classifies the file
///     by this string (EBOK/PDOC/EBSP); writing an integer here, as the old
///     writer did, is invalid and makes the firmware treat the book as an
///     unknown type.
///   * type 116 (start reading), when the body start offset is known, so the
///     Kindle opens the book at the beginning of the content,
///   * types 204/205/206/207 (creator software) pretending to be kindlegen
///     1.2, exactly like Calibre does for compatibility.
Uint8List _buildExth(String? author, String title, int? bodyStartOffset) {
  final records = <(int, Uint8List)>[];
  final cleanTitle = title.trim();
  if (cleanTitle.isNotEmpty) {
    records.add((503, Uint8List.fromList(utf8.encode(cleanTitle))));
  }
  if (author != null && author.trim().isNotEmpty) {
    records.add((100, Uint8List.fromList(utf8.encode(author.trim()))));
  }
  records.add((501, Uint8List.fromList(utf8.encode('EBOK'))));
  if (bodyStartOffset != null && bodyStartOffset >= 0) {
    records.add((116, Uint8List.fromList([
      (bodyStartOffset >> 24) & 0xFF,
      (bodyStartOffset >> 16) & 0xFF,
      (bodyStartOffset >> 8) & 0xFF,
      bodyStartOffset & 0xFF,
    ])));
  }
  // Creator software: kindlegen 1.2 (201 = Linux), como Calibre.
  records.add((204, Uint8List.fromList(
      [(201 >> 24) & 0xFF, (201 >> 16) & 0xFF, (201 >> 8) & 0xFF, 201 & 0xFF])));
  records.add((205, Uint8List.fromList(
      [(1 >> 24) & 0xFF, (1 >> 16) & 0xFF, (1 >> 8) & 0xFF, 1 & 0xFF])));
  records.add((206, Uint8List.fromList(
      [(2 >> 24) & 0xFF, (2 >> 16) & 0xFF, (2 >> 8) & 0xFF, 2 & 0xFF])));
  records.add((207, Uint8List.fromList([
    (33307 >> 24) & 0xFF,
    (33307 >> 16) & 0xFF,
    (33307 >> 8) & 0xFF,
    33307 & 0xFF,
  ])));
  final out = BytesBuilder();
  out.add(utf8.encode('EXTH'));
  var totalLength = 12;
  for (final record in records) {
    totalLength += 8 + record.$2.length;
  }
  _putUint32(out, totalLength);
  _putUint32(out, records.length);
  for (final record in records) {
    _putUint32(out, record.$1); // type
    _putUint32(out, 8 + record.$2.length); // record length
    out.add(record.$2);
  }
  // Pad the whole block to a multiple of four bytes. The padding is not part
  // of the EXTH length; the caller places the title right after these bytes.
  final block = out.toBytes();
  final pad = block.length % 4;
  if (pad != 0) {
    return Uint8List.fromList([...block, ...List.filled(4 - pad, 0)]);
  }
  return block;
}

/// The FLIS record (byte-identical to Calibre's `FLIS` constant).
Uint8List _buildFlis() {
  return Uint8List.fromList(const [
    0x46, 0x4C, 0x49, 0x53, // 'FLIS'
    0x00, 0x00, 0x00, 0x08, 0x00, 0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x03,
    0x00, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF,
  ]);
}

/// The FCIS record (byte-identical to Calibre's `fcis()` helper), embedding
/// the uncompressed [textLength].
Uint8List _buildFcis(int textLength) {
  final out = BytesBuilder();
  out.add(const [
    0x46, 0x43, 0x49, 0x53, // 'FCIS'
    0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x00,
  ]);
  _putUint32(out, textLength);
  out.add(const [
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x08,
    0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
  ]);
  return out.toBytes();
}

/// The 32-byte database name: the title sanitized to ASCII (kindlegen and
/// Calibre use `ascii_filename`), truncated to 31 bytes, null padded. The
/// PalmDB name is an ASCII field; writing raw UTF-8 here (as the old writer
/// did) can produce an invalid name that the Kindle firmware rejects.
Uint8List _palmNameBytes(String title) {
  final raw = ascii.encode(title
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '_') // no ASCII -> '_'
      .replaceAll(' ', '_')); // espacios -> '_' (como Calibre)
  final name = <int>[...raw.take(31)];
  while (name.length < 32) {
    name.add(0);
  }
  return Uint8List.fromList(name);
}

void _putUint16(BytesBuilder out, int value) {
  out.addByte((value >> 8) & 0xFF);
  out.addByte(value & 0xFF);
}

void _putUint32(BytesBuilder out, int value) {
  out.addByte((value >> 24) & 0xFF);
  out.addByte((value >> 16) & 0xFF);
  out.addByte((value >> 8) & 0xFF);
  out.addByte(value & 0xFF);
}

Uint8List _putUint32Bytes(int value) => Uint8List.fromList([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);

void _patchUint32(Uint8List bytes, int offset, int value) {
  bytes[offset] = (value >> 24) & 0xFF;
  bytes[offset + 1] = (value >> 16) & 0xFF;
  bytes[offset + 2] = (value >> 8) & 0xFF;
  bytes[offset + 3] = value & 0xFF;
}

Uint8List _pad4(Uint8List bytes) {
  final pad = bytes.length % 4;
  if (pad == 0) {
    return bytes;
  }
  return Uint8List.fromList([...bytes, ...List.filled(4 - pad, 0)]);
}

void _pad4InPlace(BytesBuilder out) {
  final pad = out.length % 4;
  if (pad != 0) {
    out.add(List.filled(4 - pad, 0));
  }
}
