// Dart imports:
import 'dart:async';
import 'dart:io';

// Project imports:
import 'package:openlib/services/local_file_server.dart'
    show LocalFileServer, getLocalIpv4Addresses;

/// Herramienta de diagnóstico: sirve cualquier carpeta con el MISMO servidor
/// local que usa la app (`LocalFileServer`), para descartar que el problema de
/// un `.mobi` con páginas en blanco sea el servidor.
///
/// El listado del servidor muestra TODOS los archivos de la carpeta (sin
/// filtros de extensión ni de biblioteca), así que basta con dejar ahí el
/// `.mobi` convertido con una herramienta externa (p.ej. Calibre) y
/// descargarlo desde el navegador del Kindle.
///
/// Uso:
///   dart run tool/serve_folder.dart [carpeta] [puerto]
///
/// Ejemplos:
///   dart run tool/serve_folder.dart
///       -> sirve la carpeta actual en el primer puerto libre (8000, 8080...)
///   dart run tool/serve_folder.dart /ruta/al/mobi 8000
///       -> sirve la carpeta con el .mobi en el puerto 8000
Future<void> main(List<String> args) async {
  final String rootPath = args.isNotEmpty ? args[0] : Directory.current.path;
  final int? port = args.length > 1 ? int.tryParse(args[1]) : null;

  if (!Directory(rootPath).existsSync()) {
    stderr.writeln('La carpeta no existe: $rootPath');
    exitCode = 1;
    return;
  }

  final LocalFileServer server = LocalFileServer();
  final int boundPort = await server.start(rootPath: rootPath, port: port);

  stdout.writeln('Sirviendo: $rootPath');
  stdout.writeln(
      'El listado muestra todos los archivos de la carpeta (sin filtros).');
  stdout.writeln('');

  final List<String> addresses = await getLocalIpv4Addresses();
  if (addresses.isEmpty) {
    stdout.writeln('  http://localhost:$boundPort/');
  } else {
    for (final String address in addresses) {
      stdout.writeln('  http://$address:$boundPort/');
    }
  }
  stdout.writeln('');
  stdout.writeln(
      'Abre esa URL en el navegador del Kindle (misma red Wi-Fi) y descarga el .mobi.');
  stdout.writeln('Para comprobar la integridad en la PC:');
  stdout.writeln('  curl -o test.mobi http://<ip>:<puerto>/<archivo>.mobi');
  stdout.writeln('  md5sum test.mobi   # debe coincidir con el hash del archivo original');
  stdout.writeln('Pulsa Ctrl+C para detener.');

  final Completer<void> done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) {
    server.stop();
    done.complete();
  });
  await done.future;
}
