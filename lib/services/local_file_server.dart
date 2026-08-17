// Dart imports:
import 'dart:convert';
import 'dart:io';

// Package imports:
import 'package:path/path.dart' as p;

/// Puertos que se prueban en orden hasta encontrar uno libre.
/// Si todos están ocupados, el sistema operativo asigna uno automáticamente.
const List<int> _preferredPorts = [8000, 8080, 8888, 9000];

const Map<String, String> _mimeTypes = {
  'pdf': 'application/pdf',
  'epub': 'application/epub+zip',
  'cbz': 'application/vnd.comicbook+zip',
  'cbr': 'application/vnd.comicbook-rar',
  'mobi': 'application/x-mobipocket-ebook',
  'azw3': 'application/vnd.amazon.ebook',
  'azw': 'application/vnd.amazon.ebook',
  'djvu': 'image/vnd.djvu',
  'txt': 'text/plain; charset=utf-8',
  'zip': 'application/zip',
  'rar': 'application/vnd.rar',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'mp3': 'audio/mpeg',
  'mp4': 'video/mp4',
  'html': 'text/html; charset=utf-8',
  'htm': 'text/html; charset=utf-8',
};

/// Servidor HTTP temporal que expone una carpeta (la de libros descargados)
/// con directory listing, únicamente accesible desde la red local.
class LocalFileServer {
  HttpServer? _server;
  String? _rootPath;

  bool get isRunning => _server != null;

  /// Arranca el servidor sirviendo [rootPath] y devuelve el puerto en uso.
  Future<int> start({required String rootPath, int? port}) async {
    await stop();
    _rootPath = p.normalize(rootPath);
    final server = await _bind(port);
    server.listen(_handleRequest, onError: (_) {});
    _server = server;
    return server.port;
  }

  /// Detiene el servidor (si estaba corriendo).
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _rootPath = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<HttpServer> _bind(int? requestedPort) async {
    if (requestedPort != null) {
      return HttpServer.bind(InternetAddress.anyIPv4, requestedPort);
    }
    for (final port in _preferredPorts) {
      try {
        return await HttpServer.bind(InternetAddress.anyIPv4, port);
      } on SocketException {
        // Puerto ocupado: se prueba el siguiente.
      }
    }
    // Puerto 0: el SO asigna uno libre.
    return HttpServer.bind(InternetAddress.anyIPv4, 0);
  }

  void _handleRequest(HttpRequest request) {
    if (request.method != 'GET' && request.method != 'HEAD') {
      _sendError(request.response, HttpStatus.methodNotAllowed,
          'Method not allowed');
      return;
    }
    try {
      final requestPath = request.uri.path;
      final String decodedPath = Uri.decodeComponent(requestPath);
      final String relativePath =
          decodedPath.startsWith('/') ? decodedPath.substring(1) : decodedPath;
      final root = p.normalize(_rootPath!);
      final requested = p.normalize(p.join(root, relativePath));

      // Protección contra path traversal: nada fuera de la carpeta raíz.
      if (requested != root && !requested.startsWith('$root${p.separator}')) {
        _sendError(request.response, HttpStatus.forbidden, 'Forbidden');
        return;
      }

      final type = FileSystemEntity.typeSync(requested, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        _sendDirectoryListing(request.response, requested, requestPath);
      } else if (type == FileSystemEntityType.file) {
        _sendFile(request.response, File(requested));
      } else {
        _sendError(request.response, HttpStatus.notFound, 'Not found');
      }
    } catch (_) {
      _sendError(request.response, HttpStatus.notFound, 'Not found');
    }
  }

  void _sendDirectoryListing(
      HttpResponse response, String dirPath, String requestPath) {
    try {
      final Directory dir = Directory(dirPath);
      final List<FileSystemEntity> entries =
          dir.listSync(followLinks: false).toList()
            ..sort((a, b) {
              final bool aIsDir =
                  FileSystemEntity.typeSync(a.path, followLinks: false) ==
                      FileSystemEntityType.directory;
              final bool bIsDir =
                  FileSystemEntity.typeSync(b.path, followLinks: false) ==
                      FileSystemEntityType.directory;
              if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
              return a.path
                  .toLowerCase()
                  .compareTo(b.path.toLowerCase());
            });

      final List<String> segments = requestPath
          .split('/')
          .where((s) => s.isNotEmpty)
          .toList();
      final bool isRoot = segments.isEmpty;
      final String? parentHref = isRoot
          ? null
          : '/${segments.sublist(0, segments.length - 1).join('/')}';

      final String title =
          'Openlib — index of /${segments.join('/')}';

      final StringBuffer html = StringBuffer()
        ..writeln('<!DOCTYPE html>')
        ..writeln('<html lang="en">')
        ..writeln('<head>')
        ..writeln('<meta charset="utf-8">')
        ..writeln(
            '<meta name="viewport" content="width=device-width, initial-scale=1">')
        ..writeln('<title>${_htmlEscape.convert(title)}</title>')
        ..writeln('<style>')
        ..writeln('body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",'
            'Roboto,sans-serif;background:#fafafa;color:#1f1f1f;'
            'margin:0;padding:24px;max-width:800px;margin:0 auto;}')
        ..writeln('h1{font-size:1.2rem;margin-bottom:16px;}')
        ..writeln('ul{list-style:none;padding:0;margin:0;}')
        ..writeln('li{padding:10px 8px;border-bottom:1px solid #e0e0e0;'
            'display:flex;justify-content:space-between;align-items:center;'
            'gap:12px;}')
        ..writeln('a{color:#1565c0;text-decoration:none;font-weight:500;'
            'overflow-wrap:anywhere;}')
        ..writeln('.meta{color:#757575;font-size:0.85rem;white-space:nowrap;}')
        ..writeln('.folder{color:#2e7d32;}')
        ..writeln('</style>')
        ..writeln('</head>')
        ..writeln('<body>')
        ..writeln('<h1>$title</h1>')
        ..writeln('<ul>');

      if (!isRoot) {
        html.writeln(
            '<li><a href="$parentHref">⬆️ ..</a></li>');
      }

      for (final entity in entries) {
        final name = p.basename(entity.path);
        final hrefSegments = [...segments, name];
        final href = '/${hrefSegments.map(Uri.encodeComponent).join('/')}';
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
            FileSystemEntityType.directory) {
          html.writeln(
              '<li><a class="folder" href="$href/">📁 ${_htmlEscape.convert(name)}</a>'
              '<span class="meta">folder</span></li>');
        } else {
          final stat = entity.statSync();
          final size = _bytesToFileSize(stat.size);
          final modified = _formatDate(stat.modified);
          html.writeln(
              '<li><a href="$href">📄 ${_htmlEscape.convert(name)}</a>'
              '<span class="meta">$size · $modified</span></li>');
        }
      }

      html.writeln('</ul>');
      html.writeln('</body>');
      html.writeln('</html>');

      response.headers.contentType = ContentType.html;
      response.write(html.toString());
      response.close();
    } catch (_) {
      _sendError(response, HttpStatus.internalServerError,
          'Could not read directory');
    }
  }

  void _sendFile(HttpResponse response, File file) {
    try {
      final stat = file.statSync();
      final String name = p.basename(file.path);
      final String extension =
          name.contains('.') ? name.split('.').last.toLowerCase() : '';
      final String mime = _mimeTypes[extension] ?? 'application/octet-stream';

      response.headers.contentType = ContentType.parse(mime);
      response.headers.set(HttpHeaders.contentLengthHeader, stat.size);
      response.headers.set('Content-Disposition', _contentDisposition(name));
      response.addStream(file.openRead()).then((_) => response.close());
    } catch (_) {
      _sendError(response, HttpStatus.internalServerError,
          'Could not read file');
    }
  }

  void _sendError(HttpResponse response, int statusCode, String message) {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.html;
    response.write(
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<title>$statusCode</title></head><body>'
        '<h1>$statusCode — ${_htmlEscape.convert(message)}</h1></body></html>');
    response.close();
  }

  String _bytesToFileSize(int bytes) {
    const List<String> suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    if (bytes <= 0) return '0 B';
    var i = 0;
    double value = bytes.toDouble();
    while (value >= 1024 && i < suffixes.length - 1) {
      value /= 1024;
      i++;
    }
    final String formatted =
        i == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '$formatted ${suffixes[i]}';
  }

  String _formatDate(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }
}

const HtmlEscape _htmlEscape = HtmlEscape();

/// Construye la cabecera `Content-Disposition` para la descarga de [fileName].
///
/// El navegador del Kindle solo acepta de forma fiable la forma simple
/// `filename=` con un nombre ASCII limpio: si el servidor envía únicamente la
/// forma RFC 5987 `filename*=UTF-8''...`, el Kindle rechaza el archivo o lo
/// guarda con nombre/ubicación incorrectos (calibre-web issue #1149). Por eso
/// se envían ambas formas: la simple con el nombre saneado a ASCII (la que
/// usa el Kindle) y la RFC 5987 con el nombre real percent-encoded, para los
/// clientes que la soportan.
String _contentDisposition(String fileName) {
  final simpleName = fileName
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '_')
      .replaceAll('"', '');
  final encodedName = Uri.encodeComponent(fileName);
  return 'attachment; filename="$simpleName"; filename*=UTF-8\'\'$encodedName';
}

/// Devuelve las direcciones IPv4 locales (sin loopback) para mostrarlas
/// como URL de acceso desde otros dispositivos de la red.
Future<List<String>> getLocalIpv4Addresses() async {
  final List<String> addresses = [];
  try {
    final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.address.isNotEmpty && !addresses.contains(addr.address)) {
          addresses.add(addr.address);
        }
      }
    }
  } catch (_) {
    // Sin interfaces de red: se devuelve lista vacía.
  }
  return addresses;
}
