// Dart imports:
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Package imports:
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Repara malformaciones del OPF que hacen que `EpubReader` (epubx, usado por
/// el lector interno vía `epub_view` y por el conversor MOBI/AZW) rechace
/// EPUBs que sí son legibles.
///
/// El caso conocido: la portada se declara con
/// `<meta name="cover" content="images/cover.png"/>` donde el valor es el
/// *href* del item (o una referencia huérfana) en lugar de su *id*. epubx
/// busca el valor entre los ids del manifest (`BookCoverReader`) y lanza
/// `Incorrect EPUB manifest: item with ID = ... is missing`, rompiendo tanto
/// la apertura del libro como la conversión. Cuando el valor coincide con el
/// href de un item (imagen presente en el archivo), este se reescribe al id
/// de ese item; cuando no resuelve a ningún item utilizable, el elemento
/// `meta` se elimina — la portada es decorativa y no debe impedir la lectura.
///
/// Devuelve [bytes] tal cual (la misma instancia) si no hay nada que reparar
/// o si el archivo no es un EPUB legible; el llamador decide cómo reportarlo.
Uint8List repairEpubBytes(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return bytes; // no es ni un zip: no es un epub, el llamador lo reporta
  }

  // 1) Ruta del OPF desde META-INF/container.xml.
  final container = archive.findFile('META-INF/container.xml');
  if (container == null) {
    return bytes;
  }
  String? opfPath;
  try {
    final containerText = _decodeText(_toBytes(container.content));
    if (containerText == null) {
      return bytes;
    }
    final containerDoc = XmlDocument.parse(containerText);
    for (final rootfile
        in containerDoc.findAllElements('rootfile', namespace: '*')) {
      final fullPath = rootfile.getAttribute('full-path');
      if (fullPath != null && fullPath.trim().isNotEmpty) {
        opfPath = fullPath.trim();
        break;
      }
    }
  } catch (_) {
    return bytes;
  }
  if (opfPath == null) {
    return bytes;
  }

  // 2) OPF: manifest (id/href) y metadatos (meta cover).
  final opf = archive.findFile(opfPath);
  if (opf == null) {
    return bytes;
  }
  final opfText = _decodeText(_toBytes(opf.content));
  if (opfText == null) {
    return bytes;
  }
  final XmlDocument opfDoc;
  try {
    opfDoc = XmlDocument.parse(opfText);
  } catch (_) {
    return bytes;
  }

  final manifests = opfDoc.findAllElements('manifest', namespace: '*');
  if (manifests.isEmpty) {
    return bytes;
  }
  final itemsById = <String, XmlElement>{};
  final itemsByHref = <String, XmlElement>{};
  for (final item in manifests.first.findElements('item', namespace: '*')) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');
    if (id != null && id.trim().isNotEmpty) {
      itemsById[_norm(id)] = item;
    }
    if (href != null && href.trim().isNotEmpty) {
      itemsByHref[_norm(href)] = item;
      itemsByHref[_norm(_simplifyPath(href))] = item;
    }
  }
  if (itemsById.isEmpty) {
    return bytes;
  }

  final opfDir = _parentDir(opfPath);
  var changed = false;
  final metadatas = opfDoc.findAllElements('metadata', namespace: '*');
  if (metadatas.isNotEmpty) {
    for (final meta
        in metadatas.first.findElements('meta', namespace: '*').toList()) {
      final name = meta.getAttribute('name');
      if (name == null || name.trim().toLowerCase() != 'cover') {
        continue;
      }
      final content = meta.getAttribute('content');
      if (content == null || content.trim().isEmpty) {
        continue;
      }
      final key = _norm(content);
      final item = itemsById[key] ?? itemsByHref[key];
      if (item != null && _isUsableCoverItem(item, archive, opfDir)) {
        // El item de portada existe y es una imagen presente en el archivo.
        // Si el valor era el href (no el id), lo reescribimos al id.
        final id = item.getAttribute('id')!;
        if (id != content) {
          meta.setAttribute('content', id);
          changed = true;
        }
      } else {
        // Referencia irresoluble: la portada no debe bloquear la lectura.
        meta.remove();
        changed = true;
      }
    }
  }
  if (!changed) {
    return bytes;
  }

  // 3) Reempaqueta el zip con el OPF corregido. El resto de entradas se
  // conserva byte a byte (ZipEncoder reutiliza el rawContent de los archivos
  // ya comprimidos); la entrada `mimetype` pasará a comprimida, algo que los
  // lectores basados en ZipDecoder (epubx, epub_view) aceptan sin problema.
  final newArchive = Archive();
  for (final file in archive.files) {
    if (file.name == opfPath) {
      final newOpf = utf8.encode(opfDoc.toXmlString());
      newArchive.addFile(ArchiveFile(opfPath, newOpf.length, newOpf));
    } else {
      newArchive.addFile(file);
    }
  }
  final encoded = ZipEncoder().encode(newArchive);
  if (encoded == null) {
    return bytes;
  }
  return Uint8List.fromList(encoded);
}

/// Lee [path], repara lo que haga falta con [repairEpubBytes] y reescribe el
/// archivo **solo** si algo cambió. Devuelve true si se reescribió.
Future<bool> repairEpubFile(String path) async {
  final file = File(path);
  final bytes = await file.readAsBytes();
  final repaired = repairEpubBytes(bytes);
  if (identical(repaired, bytes)) {
    return false;
  }
  await file.writeAsBytes(repaired, flush: true);
  return true;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// True cuando [item] es una imagen declarada en el manifest que existe
/// dentro del zip: solo así epubx la coloca en `Content.Images` y puede leer
/// sus bytes sin lanzar.
bool _isUsableCoverItem(XmlElement item, Archive archive, String opfDir) {
  final mediaType = item.getAttribute('media-type');
  if (mediaType == null || !mediaType.toLowerCase().startsWith('image/')) {
    return false;
  }
  final href = item.getAttribute('href');
  if (href == null || href.trim().isEmpty) {
    return false;
  }
  final resolved = _resolveZipPath(opfDir, href.trim());
  return archive.findFile(resolved) != null;
}

String _resolveZipPath(String opfDir, String href) {
  final joined = p.posix.join(opfDir.isEmpty ? '' : opfDir, href);
  return p.posix.normalize(joined);
}

String _parentDir(String path) {
  final normalized = p.posix.normalize(path);
  final idx = normalized.lastIndexOf('/');
  return idx <= 0 ? '' : normalized.substring(0, idx);
}

/// Quita `./`, `/` iniciales y `/` finales de un href para compararlo con el
/// valor del meta cover (los productores escriben `./images/x.png` y el meta
/// `images/x.png` indistintamente).
String _simplifyPath(String href) {
  var result = href.trim();
  while (result.startsWith('./')) {
    result = result.substring(2);
  }
  while (result.startsWith('/')) {
    result = result.substring(1);
  }
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

/// Comparación de ids/hrefs a la manera de epubx: sin espacios y sin
/// distinguir mayúsculas.
String _norm(String value) => value.trim().toLowerCase();

String? _decodeText(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

Uint8List _toBytes(dynamic content) {
  if (content is Uint8List) {
    return content;
  }
  if (content is List<int>) {
    return Uint8List.fromList(content);
  }
  if (content is InputStreamBase) {
    return content.toUint8List();
  }
  return Uint8List.fromList(content as List<int>);
}
