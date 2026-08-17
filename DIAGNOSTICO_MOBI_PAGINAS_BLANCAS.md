# Diagnóstico: archivo .mobi con páginas en blanco en Kindle

Análisis del flujo completo: cómo se genera el `.mobi`, cómo se almacena y cómo lo sirve el servidor local de la app.

---

## 1. Manejo de la respuesta HTTP (cómo se sirve el archivo)

**Archivo: `lib/services/local_file_server.dart`**

El handler principal valida método (solo `GET`/`HEAD`), protege contra path traversal y decide entre listing de directorio o envío de archivo:

```dart
void _handleRequest(HttpRequest request) {
  if (request.method != 'GET' && request.method != 'HEAD') {
    _sendError(request.response, HttpStatus.methodNotAllowed, 'Method not allowed');
    return;
  }
  try {
    final requestPath = request.uri.path;
    final String decodedPath = Uri.decodeComponent(requestPath);
    final String relativePath = decodedPath.startsWith('/') ? decodedPath.substring(1) : decodedPath;
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
```

El envío del archivo (la parte clave):

```dart
void _sendFile(HttpResponse response, File file) {
  try {
    final stat = file.statSync();
    final String name = p.basename(file.path);
    final String extension = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final String mime = _mimeTypes[extension] ?? 'application/octet-stream';

    response.headers.contentType = ContentType.parse(mime);
    response.headers.set(HttpHeaders.contentLengthHeader, stat.size);
    response.headers.set(
        'Content-Disposition',
        'attachment; filename="${name.replaceAll('"', '')}"');
    response.addStream(file.openRead()).then((_) => response.close());
  } catch (_) {
    _sendError(response, HttpStatus.internalServerError, 'Could not read file');
  }
}
```

**Resumen punto 1:**

- **Lectura**: `file.openRead()` → `response.addStream(...)` (streaming, no carga el archivo en memoria; byte a byte desde el disco).
- **Content-Type**: `application/x-mobipocket-ebook` para `.mobi`, `application/vnd.amazon.ebook` para `.azw` (mapa `_mimeTypes`).
- **Content-Length**: `stat.size` (correcto, tomado del `statSync`).
- **Content-Disposition**: `attachment; filename="..."` (descarga, no renderiza).
- No hay cabecera `Content-Encoding`, `Accept-Ranges` ni soporte de Range requests.

---

## 2. Origen y almacenamiento del archivo .mobi

El `.mobi` **no viene de assets ni de la base de datos** — es un archivo plano generado y escrito en el almacenamiento externo de Android.

**Escritura del .mobi — `lib/services/convert_to_mobi.dart`:**

```dart
final source = File(sourcePath);
final bytes = await source.readAsBytes();          // lee el epub/pdf completo

final ExtractedBook extracted = normalizedFormat == 'epub'
    ? await _extractEpub(bytes, title: title, author: author)
    : await _extractPdf(bytes, title: title, author: author);
...
final mobi = buildMobi(MobiBook(...));

final outputPath = _outputPath(sourcePath, outputExtension);  // mismo dir, mismo base, .mobi/.azw
await File(outputPath).writeAsBytes(mobi);                    // escritura completa en disco
```

**Origen del archivo fuente — `lib/services/download_file.dart`:** el epub/pdf original se descarga con **Dio** directamente al disco, con nombre `$md5.$format`:

```dart
String path = await _getFilePath('$md5.$format');   // bookStorageDirectory/$md5.$format
...
dio.download(workingMirror, path, options: Options(headers: {...}), ...);
```

**Registro en la BD — `lib/services/files.dart`:** tras convertir, el archivo se registra en SQLite (`MyBook` con `id: '$sourceId.$format'` y `fileName`) para que aparezca en "My Library":

```dart
Future<void> registerConvertedFile({
  required String sourceId, required String format, required String fileName,
}) async {
  final source = await dataBase.getId(sourceId);
  if (source == null) return;
  await dataBase.insert(MyBook(
    id: '$sourceId.$format', ... format: format, fileName: fileName));
}
```

**Resumen punto 2:** el flujo completo es:

1. Descarga: Dio escribe `bookStorageDirectory/<md5>.<format>` (epub/pdf).
2. Conversión: `convertToMobi` lee ese archivo, genera los bytes MOBI con `buildMobi()` y escribe `bookStorageDirectory/<nombre>.mobi` con `writeAsBytes`.
3. Registro: SQLite guarda la referencia (id = `<md5>.mobi`).
4. Servido: el server expone `bookStorageDirectory` completo.

**`bookStorageDirectory`** es, en Android, `getExternalStorageDirectory()` (`lib/services/files.dart`).

---

## 3. Configuración del servidor web

**No usa shelf ni shelf_static — es `dart:io HttpServer` puro**, sin middleware ni pipeline. El listener se monta así:

```dart
// lib/services/local_file_server.dart
const List<int> _preferredPorts = [8000, 8080, 8888, 9000];

Future<int> start({required String rootPath, int? port}) async {
  await stop();
  _rootPath = p.normalize(rootPath);
  final server = await _bind(port);
  server.listen(_handleRequest, onError: (_) {});
  _server = server;
  return server.port;
}

Future<HttpServer> _bind(int? requestedPort) async {
  if (requestedPort != null) {
    return HttpServer.bind(InternetAddress.anyIPv4, requestedPort);
  }
  for (final port in _preferredPorts) { try { return await HttpServer.bind(...); } on SocketException {} }
  return HttpServer.bind(InternetAddress.anyIPv4, 0);  // puerto efímero
}
```

Se arranca desde la configuración con la carpeta de libros como raíz (`lib/ui/settings_page.dart`):

```dart
final dynamic dir = await dataBase.getPreference('bookStorageDirectory');
final int port = await server.start(rootPath: dir.toString());
```

Y se instancia como singleton vía Riverpod (`lib/state/state.dart`):

```dart
final localFileServerProvider = Provider<LocalFileServer>((ref) => LocalFileServer());
```

**Resumen punto 3:** `HttpServer.bind(InternetAddress.anyIPv4, puerto)` (0.0.0.0 → accesible desde el Kindle en la LAN), sin shelf, sin middlewares, sin compresión, sin gzip, sin CORS ni Range support.

---

## Diagnóstico orientado al problema (páginas en blanco en Kindle)

Lo que el código demuestra:

1. **La transferencia es byte-por-byte fiel**: `openRead()` → `addStream()` sirve exactamente lo que hay en disco. Si en la PC lo lees bien, **el servidor casi seguro no está corrompiendo nada** — lo que llega al Kindle es idéntico a lo que lees en la PC.

2. **Verificación rápida**: descarga el `.mobi` desde la PC con `curl` y compara el hash:

   ```bash
   curl -o test.mobi http://<ip-del-telefono>:<puerto>/<nombre>.mobi
   md5sum test.mobi        # vs el hash del archivo en el teléfono
   ```

   Si coinciden, el problema está en **cómo el Kindle interpreta el archivo**, no en la transmisión — que es justo lo que ataca el botón "Convert to AZW" (mismo contenedor, extensión `.azw` que el Kindle trata como ebook nativo en vez de "documento personal" `.mobi`).

3. **Dato relevante del writer**: `lib/services/mobi_writer.dart` ya tiene un fix específico para el Kindle — `first image record` apunta más allá del último registro (si no, el Kindle intenta decodificar FLIS/FCIS como imagen y muestra páginas en blanco/bloqueadas). Si el AZW aún fallara, el siguiente paso sería inspeccionar un archivo real generado con KindleUnpack/Calibre para ver si algún otro campo del header MOBI (EXTH, encoding, etc.) no le gusta al firmware.
