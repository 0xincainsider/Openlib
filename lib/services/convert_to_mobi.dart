// Dart imports:
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Package imports:
import 'package:epubx/epubx.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;
import 'package:syncfusion_flutter_pdf/pdf.dart'
    show PdfDocument, PdfTextExtractor;

// Project imports:
import 'package:openlib/services/epub_repair.dart' show repairEpubBytes;
import 'package:openlib/services/mobi_writer.dart';

/// A chapter (or page) of extracted text content.
class MobiChapter {
  final String title;
  final String htmlContent;

  const MobiChapter({required this.title, required this.htmlContent});
}

/// Result of extracting the readable content of a book file.
class ExtractedBook {
  final String title;
  final String? author;
  final List<MobiChapter> chapters;

  const ExtractedBook({
    required this.title,
    this.author,
    required this.chapters,
  });
}

/// Result of a successful conversion.
class ConvertResult {
  final String outputPath;
  final String title;
  final String? author;
  final int chapterCount;

  const ConvertResult({
    required this.outputPath,
    required this.title,
    this.author,
    required this.chapterCount,
  });
}

/// Converts the downloaded file at [sourcePath] into a Mobipocket ebook
/// written next to it (same directory, same base name). [sourceFormat] is
/// `epub` or `pdf`.
///
/// [title] and [author] come from the app's library when known and override
/// the metadata found inside the file.
///
/// [outputExtension] is `mobi` (default) or `azw`. AZW is Amazon's name for
/// the same Mobipocket container, so the bytes are identical; the Kindle
/// treats `.azw` files as native ebooks, which sidesteps the blank-page bug
/// some Kindle firmwares show for sideloaded `.mobi` files.
Future<ConvertResult> convertToMobi({
  required String sourcePath,
  required String sourceFormat,
  String? title,
  String? author,
  String outputExtension = 'mobi',
}) async {
  final normalizedFormat = sourceFormat.toLowerCase();
  if (normalizedFormat != 'epub' && normalizedFormat != 'pdf') {
    throw ArgumentError.value(sourceFormat, 'sourceFormat',
        'Only "epub" and "pdf" are supported');
  }

  final source = File(sourcePath);
  final bytes = await source.readAsBytes();

  final ExtractedBook extracted = normalizedFormat == 'epub'
      ? await _extractEpub(bytes, title: title, author: author)
      : await _extractPdf(bytes, title: title, author: author);

  if (extracted.chapters.isEmpty) {
    throw StateError(
        'No readable text was found in this file, so it cannot be converted '
        'to MOBI.');
  }

  final htmlResult = buildMobiHtml(
    title: extracted.title,
    author: extracted.author,
    chapters: extracted.chapters,
  );
  final mobi = buildMobi(MobiBook(
    // Kindle fonts cannot render emoji (astral-plane characters): they show
    // as broken glyphs, so strip them from everything that goes into the
    // file (header title, EXTH author and HTML content).
    title: _stripAstral(extracted.title),
    author: extracted.author == null
        ? null
        : _stripAstral(extracted.author!),
    contentHtml: htmlResult.html,
    // The NCX index: the Kindle needs it to paginate a MOBI6 book (without
    // it, sideloaded books open with blank pages).
    tocEntries: htmlResult.tocEntries,
    bodyStartOffset: htmlResult.bodyStartOffset,
  ));

  final outputPath = _outputPath(sourcePath, outputExtension);
  await File(outputPath).writeAsBytes(mobi);
  return ConvertResult(
    outputPath: outputPath,
    title: extracted.title,
    author: extracted.author,
    chapterCount: extracted.chapters.length,
  );
}

/// Top-level entry point suitable for `compute()` in a background isolate
/// (`.mobi` output).
Future<ConvertResult> convertToMobiInBackground(ConvertRequest request) =>
    convertToMobi(
      sourcePath: request.sourcePath,
      sourceFormat: request.sourceFormat,
      title: request.title,
      author: request.author,
    );

/// Top-level entry point suitable for `compute()` in a background isolate
/// (`.azw` output: the same Mobipocket container, with the extension the
/// Kindle reads as a native ebook).
Future<ConvertResult> convertToAzwInBackground(ConvertRequest request) =>
    convertToMobi(
      sourcePath: request.sourcePath,
      sourceFormat: request.sourceFormat,
      title: request.title,
      author: request.author,
      outputExtension: 'azw',
    );

/// Arguments for [convertToMobiInBackground] (must be sendable across
/// isolates).
class ConvertRequest {
  final String sourcePath;
  final String sourceFormat;
  final String? title;
  final String? author;

  const ConvertRequest({
    required this.sourcePath,
    required this.sourceFormat,
    this.title,
    this.author,
  });
}

// ---------------------------------------------------------------------------
// HTML building
// ---------------------------------------------------------------------------

/// The result of [buildMobiHtml]: the rawml HTML plus the metadata needed to
/// build the MOBI's NCX index.
class MobiHtmlResult {
  final String html;
  final List<MobiTocEntry> tocEntries;

  /// Byte offset of the first content after `<body>`, used for the EXTH
  /// "start reading" record so the Kindle opens at the beginning.
  final int? bodyStartOffset;

  const MobiHtmlResult({
    required this.html,
    required this.tocEntries,
    this.bodyStartOffset,
  });
}

/// Builds the rawml HTML stored inside the MOBI: an `<h1>` book title, then
/// one `<mbp:pagebreak/>` + `<h2>` + paragraphs per chapter.
///
/// Returns the HTML together with the UTF-8 byte offset of every chapter
/// heading (the MOBI index entries point at these positions) and the byte
/// offset where the body content starts. The byte offsets are measured over
/// the UTF-8 encoding of the final string, matching how readers (and the
/// Kindle) navigate the text.
MobiHtmlResult buildMobiHtml({
  required String title,
  String? author,
  required List<MobiChapter> chapters,
}) {
  // The head is emitted first; its byte length is fixed (the guide's filepos
  // placeholder is exactly 10 digits), so the body offsets can be computed
  // against it before the guide value is known. The placeholder is patched
  // with the real TOC page offset at the end, exactly like Calibre's
  // `fixup_links` (the value never changes the byte length).
  const headPrefix = '<html>\n<head>\n'
      '<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>\n';
  // The space before `/>` is REQUIRED: without it the HTML parser reads the
  // `/` as part of the unquoted filepos value and the reference is dropped
  // (Calibre: "Space required or won't work, I kid you not").
  const guideTemplate =
      '<guide><reference type="toc" title="Table of Contents" '
      'filepos=0000000000 /></guide>\n';
  const headSuffix = '</head>\n<body>\n';
  final bodyStartOffset = utf8.encode(headPrefix + guideTemplate + headSuffix)
      .length;

  final buffer = StringBuffer();
  buffer.write(headPrefix);
  // The filepos placeholder: patched below with the TOC page offset without
  // changing any byte offset (it is exactly 10 digits, like Calibre's
  // `filepos=0000000000` placeholder).
  buffer.write(guideTemplate);
  buffer.write(headSuffix);

  final tocEntries = <MobiTocEntry>[];
  var bytePos = bodyStartOffset;
  void emit(String text) {
    buffer.write(text);
    bytePos += utf8.encode(text).length;
  }

  if (title.trim().isNotEmpty) {
    emit('<h1>${_escape(title)}</h1>\n');
  }
  for (final chapter in chapters) {
    emit('<mbp:pagebreak/>\n');
    if (chapter.title.trim().isNotEmpty) {
      tocEntries.add(MobiTocEntry(title: chapter.title, offset: bytePos));
      emit('<h2>${_escape(chapter.title)}</h2>\n');
    }
    emit(_xhtmlToMobi(chapter.htmlContent));
    emit('\n');
  }

  // In-book table of contents page at the end of the book, exactly like
  // Calibre/Convertio: the guide's `type="toc"` reference points here, and
  // every entry is a `<a filepos=...>` link to the same byte offset used by
  // the NCX index entry. The Kindle's "Go to → Table of Contents" jumps to
  // this page.
  if (tocEntries.isNotEmpty) {
    emit('<mbp:pagebreak/>\n');
    // The guide's `type="toc"` filepos points at the TOC heading itself
    // (after the pagebreak), exactly like Calibre.
    final tocPageOffset = bytePos;
    emit('<p height="1em" width="0pt" align="center"><font size="5">'
        '<b>Table of Contents</b></font></p>\n');
    for (final entry in tocEntries) {
      emit('<p height="0pt" width="-14pt"><a filepos='
          '${entry.offset.toString().padLeft(10, '0')}>'
          '${_escape(entry.title)}</a></p>\n');
    }
    // Patch the guide placeholder with the real TOC page offset.
    final html = buffer.toString().replaceFirst(
        'filepos=0000000000 />', 'filepos=${tocPageOffset.toString().padLeft(10, '0')} />');
    return MobiHtmlResult(
      html: html,
      tocEntries: tocEntries,
      bodyStartOffset: bodyStartOffset,
    );
  }

  emit('</body>\n</html>\n');
  return MobiHtmlResult(
    html: buffer.toString(),
    tocEntries: tocEntries,
    bodyStartOffset: bodyStartOffset,
  );
}

const _blockTags = {
  'p', 'div', 'blockquote', 'pre', 'li', 'td', 'th', 'tr', 'section',
  'article', 'figure', 'figcaption', 'ul', 'ol', 'dl', 'dt', 'dd',
};

const _skipTags = {'script', 'style', 'head', 'title', 'img', 'svg', 'link'};

/// Inline formatting tags that the MOBI renderer understands and that we
/// preserve around their text content.
const _inlineTags = {'b', 'strong', 'i', 'em', 'u', 'sup', 'sub', 'q', 'small', 'big', 'code', 'tt'};

/// Converts XHTML into the simple paragraph-based HTML that MOBI renders.
String _xhtmlToMobi(String xhtml) {
  final document = parse(xhtml);
  final body = document.body;
  if (body == null) {
    return '';
  }
  final buffer = StringBuffer();
  _emitBlocks(body, buffer);
  return buffer.toString();
}

void _emitBlocks(Node node, StringBuffer out) {
  for (final child in node.nodes) {
    if (child is! Element) {
      continue;
    }
    final tag = child.localName?.toLowerCase() ?? '';
    if (_skipTags.contains(tag)) {
      continue;
    }
    if (tag == 'br') {
      out.write('<br/>');
      continue;
    }
    final isHeading = tag.length == 2 && tag.startsWith('h') &&
        '123456'.contains(tag[1]);
    if (_blockTags.contains(tag) || isHeading) {
      out.write(isHeading ? '<h2>' : '<p>');
      _emitInline(child, out);
      out.write(isHeading ? '</h2>\n' : '</p>\n');
    } else {
      _emitBlocks(child, out);
    }
  }
}

void _emitInline(Node node, StringBuffer out) {
  for (final child in node.nodes) {
    if (child is Text) {
      out.write(_escape(child.text));
      continue;
    }
    if (child is! Element) {
      continue;
    }
    final tag = child.localName?.toLowerCase() ?? '';
    if (_skipTags.contains(tag)) {
      continue;
    }
    if (tag == 'br') {
      out.write('<br/>');
      continue;
    }
    if (_blockTags.contains(tag)) {
      // Nested block inside an inline context: paragraph break.
      out.write('</p>\n<p>');
      _emitInline(child, out);
    } else if (_inlineTags.contains(tag)) {
      out.write('<$tag>');
      _emitInline(child, out);
      out.write('</$tag>');
    } else {
      _emitInline(child, out);
    }
  }
}

/// Astral-plane code points (U+10000 and above) are emoji in practice:
/// Kindle fonts cannot render them, so they are removed from the content
/// before writing the file. BMP characters (accents, dashes, smart quotes)
/// are preserved: the Kindle renders those fine.
final RegExp _astralPattern = RegExp(r'[\u{10000}-\u{10FFFF}]', unicode: true);

String _stripAstral(String text) => text.replaceAll(_astralPattern, '');

String _escape(String text) => _stripAstral(text)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

// ---------------------------------------------------------------------------
// EPUB extraction
// ---------------------------------------------------------------------------

Future<ExtractedBook> _extractEpub(
  Uint8List bytes, {
  String? title,
  String? author,
}) async {
  final EpubBook book;
  try {
    // Repara primero las malformaciones del OPF que hacen que epubx rechace
    // EPUBs legibles (p.ej. un `<meta name="cover">` cuyo content es el href
    // del item en vez de su id): si no hay nada que reparar, devuelve los
    // mismos bytes sin tocar nada.
    book = await EpubReader.readBook(repairEpubBytes(bytes));
  } catch (e) {
    throw StateError('The file is not a valid EPUB archive: $e');
  }

  final chapters = <MobiChapter>[];
  // 1) Preferred: chapters from the NCX/nav document, in reading order.
  try {
    for (final chapter in book.Chapters ?? const <EpubChapter>[]) {
      final html = chapter.HtmlContent;
      if (html == null || html.trim().isEmpty) {
        continue;
      }
      chapters.add(MobiChapter(title: chapter.Title ?? '', htmlContent: html));
    }
  } catch (_) {
    chapters.clear(); // malformed navigation: fall through
  }

  // 2) Fallback: reading order from the spine, resolved through the manifest.
  if (chapters.isEmpty) {
    try {
      final manifestById = <String, String>{};
      for (final item in book.Schema?.Package?.Manifest?.Items ??
          const <EpubManifestItem>[]) {
        if (item.Id != null && item.Href != null) {
          manifestById[item.Id!] = item.Href!;
        }
      }
      final htmlFiles =
          book.Content?.Html ?? const <String, EpubTextContentFile>{};
      for (final ref in book.Schema?.Package?.Spine?.Items ??
          const <EpubSpineItemRef>[]) {
        final href = manifestById[ref.IdRef];
        if (href == null) {
          continue;
        }
        final content = htmlFiles[href]?.Content;
        if (content == null || content.trim().isEmpty) {
          continue;
        }
        chapters.add(MobiChapter(title: '', htmlContent: content));
      }
    } catch (_) {
      chapters.clear();
    }
  }

  // 3) Last resort: every XHTML file in the manifest.
  if (chapters.isEmpty) {
    for (final file in book.Content?.Html?.values ??
        const <EpubTextContentFile>[]) {
      final content = file.Content;
      if (content == null || content.trim().isEmpty) {
        continue;
      }
      chapters.add(MobiChapter(title: '', htmlContent: content));
    }
  }

  return ExtractedBook(
    title: _nonEmpty(title) ?? _nonEmpty(book.Title) ?? '',
    author: _nonEmpty(author) ?? _nonEmpty(book.Author),
    chapters: chapters,
  );
}

// ---------------------------------------------------------------------------
// PDF extraction
// ---------------------------------------------------------------------------

Future<ExtractedBook> _extractPdf(
  Uint8List bytes, {
  String? title,
  String? author,
}) async {
  final PdfDocument document;
  try {
    document = PdfDocument(inputBytes: bytes);
  } catch (_) {
    throw StateError('The file is not a valid PDF document.');
  }

  try {
    final rawText = PdfTextExtractor(document).extractText().trim();
    if (rawText.isEmpty) {
      throw StateError(
          'This PDF has no extractable text (it may be a scanned book), so '
          'it cannot be converted to MOBI.');
    }
    final paragraphs = rawText
        .split(RegExp(r'\n\s*\n'))
        .where((paragraph) => paragraph.trim().isNotEmpty)
        .map((paragraph) =>
            '<p>${_escape(paragraph.trim()).replaceAll('\n', '<br/>')}</p>')
        .join('\n');

    String? pdfTitle;
    String? pdfAuthor;
    try {
      final info = document.documentInformation;
      pdfTitle = info.title;
      pdfAuthor = info.author;
    } catch (_) {
      // PDF metadata is best-effort only.
    }

    return ExtractedBook(
      title: _nonEmpty(title) ?? _nonEmpty(pdfTitle) ?? '',
      author: _nonEmpty(author) ?? _nonEmpty(pdfAuthor),
      chapters: [MobiChapter(title: '', htmlContent: paragraphs)],
    );
  } finally {
    document.dispose();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

String _outputPath(String sourcePath, String outputExtension) {
  final file = File(sourcePath);
  final name = file.uri.pathSegments.last;
  final base = name.contains('.')
      ? name.substring(0, name.lastIndexOf('.'))
      : name;
  return '${file.parent.path}/$base.$outputExtension';
}
