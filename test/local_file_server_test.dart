// Dart imports:
import 'dart:io';

// Package imports:
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

// Project imports:
import 'package:openlib/services/local_file_server.dart';

void main() {
  late Directory tempDir;
  late LocalFileServer server;
  late int port;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('openlib_server_test');
    File('${tempDir.path}/libro.pdf').writeAsStringSync('contenido pdf');
    Directory('${tempDir.path}/carpeta').createSync();
    File('${tempDir.path}/carpeta/otro.epub')
        .writeAsStringSync('contenido epub');
    server = LocalFileServer();
    port = await server.start(rootPath: tempDir.path);
  });

  tearDown(() async {
    await server.stop();
    tempDir.deleteSync(recursive: true);
  });

  test('sirve el directory listing de la raíz', () async {
    final res = await http.get(Uri.parse('http://127.0.0.1:$port/'));
    expect(res.statusCode, 200);
    expect(res.body, contains('libro.pdf'));
    expect(res.body, contains('carpeta'));
  });

  test('permite descargar un archivo', () async {
    final res = await http.get(Uri.parse('http://127.0.0.1:$port/libro.pdf'));
    expect(res.statusCode, 200);
    expect(res.body, 'contenido pdf');
    expect(res.headers['content-type'], 'application/pdf');
    expect(res.headers['content-disposition'], contains('attachment'));
  });

  test('muestra el nombre real de los archivos (no "Instance of '
      'HtmlEscape")', () async {
    final res = await http.get(Uri.parse('http://127.0.0.1:$port/'));
    expect(res.statusCode, 200);
    expect(res.body, isNot(contains("Instance of 'HtmlEscape'")));
  });

  test('Content-Disposition usa la forma doble RFC 6266: filename ASCII '
      'limpio + filename*=UTF-8 para que el Kindle guarde bien el archivo',
      () async {
    File('${tempDir.path}/Ángeles y demonios.mobi').writeAsStringSync('x');
    final res = await http.get(Uri.parse(
        'http://127.0.0.1:$port/%C3%81ngeles%20y%20demonios.mobi'));
    expect(res.statusCode, 200);
    final disposition = res.headers['content-disposition']!;
    expect(disposition, contains('attachment;'));
    // Forma simple: solo ASCII (sin bytes no-ASCII que rompan al Kindle).
    expect(disposition, contains('filename="_ngeles y demonios.mobi"'));
    // Forma RFC 5987 con el nombre real percent-encoded.
    expect(disposition, contains(
        "filename*=UTF-8''%C3%81ngeles%20y%20demonios.mobi"));
  });

  test('escapa caracteres especiales del nombre en el listing', () async {
    File('${tempDir.path}/Harry & Potter.epub').writeAsStringSync('x');
    final res = await http.get(Uri.parse('http://127.0.0.1:$port/'));
    expect(res.statusCode, 200);
    expect(res.body, contains('Harry &amp; Potter.epub'));
    expect(res.body, isNot(contains("Instance of 'HtmlEscape'")));
  });

  test('lista subdirectorios', () async {
    final res =
        await http.get(Uri.parse('http://127.0.0.1:$port/carpeta/'));
    expect(res.statusCode, 200);
    expect(res.body, contains('otro.epub'));
  });

  test('descarga archivos dentro de subdirectorios', () async {
    final res = await http
        .get(Uri.parse('http://127.0.0.1:$port/carpeta/otro.epub'));
    expect(res.statusCode, 200);
    expect(res.body, 'contenido epub');
  });

  test('no filtra archivos fuera de la carpeta servida', () async {
    // Archivo secreto FUERA de la carpeta servida.
    final outsideDir =
        await Directory.systemTemp.createTemp('openlib_outside');
    File('${outsideDir.path}/secret.txt').writeAsStringSync('TOP SECRET');
    addTearDown(() => outsideDir.deleteSync(recursive: true));
    final String outsideName = p.basename(outsideDir.path);

    // Intento de traversal con '..' y con '%2e%2e' codificado.
    for (final traversal in [
      '/../$outsideName/secret.txt',
      '/%2e%2e/$outsideName/secret.txt',
    ]) {
      final res =
          await http.get(Uri.parse('http://127.0.0.1:$port$traversal'));
      // Nunca debe devolverse el contenido del archivo externo.
      expect(res.body, isNot(contains('TOP SECRET')));
      expect(res.statusCode, isNot(200));
    }
  });

  test('lista y sirve un archivo ajeno a la app añadido con el servidor '
      'corriendo (p.ej. un .mobi de Calibre), transmitiéndolo byte a byte',
      () async {
    // Archivo NO descargado ni convertido por la app: se simula copiarlo a la
    // carpeta servida (vía ADB/MTP/carpeta compartida) con el servidor activo.
    final List<int> mobiBytes = List<int>.generate(2048, (i) => i % 251);
    File('${tempDir.path}/calibre_externo.mobi').writeAsBytesSync(mobiBytes);

    // Aparece en el directory listing sin filtros de biblioteca/extensión.
    final listing = await http.get(Uri.parse('http://127.0.0.1:$port/'));
    expect(listing.statusCode, 200);
    expect(listing.body, contains('calibre_externo.mobi'));

    // Se descarga idéntico: mismos bytes, tamaño y Content-Type correctos.
    final res = await http
        .get(Uri.parse('http://127.0.0.1:$port/calibre_externo.mobi'));
    expect(res.statusCode, 200);
    expect(res.bodyBytes, mobiBytes);
    expect(res.headers['content-length'], '2048');
    expect(res.headers['content-type'], 'application/x-mobipocket-ebook');
    expect(res.headers['content-disposition'], contains('attachment'));
  });

  test('devuelve 404 para archivos inexistentes', () async {
    final res =
        await http.get(Uri.parse('http://127.0.0.1:$port/no_existe.txt'));
    expect(res.statusCode, 404);
  });

  test('stop detiene el servidor', () async {
    expect(server.isRunning, true);
    await server.stop();
    expect(server.isRunning, false);
  });
}
