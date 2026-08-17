// Dart imports:
import 'dart:io';

// Package imports:
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Project imports:
import 'package:openlib/services/database.dart';
import 'package:openlib/services/files.dart';

void main() {
  // Inicialización única por archivo: la BD usa una ruta propia en /tmp para
  // que los archivos de test (que corren en paralelo) no compartan la ruta
  // por defecto (`.dart_tool/...`) y provoquen "database is locked".
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbDir = Directory.systemTemp.createTempSync('openlib_db');
    addTearDown(() => dbDir.deleteSync(recursive: true));
    // ignore: deprecated_member_use
    databaseFactory.setDatabasesPath(dbDir.path);
  });

  group('validateFileName', () {
    test('rechaza nombres vacíos o solo espacios', () {
      expect(validateFileName(''), isNotNull);
      expect(validateFileName('   '), isNotNull);
    });

    test('rechaza "." y ".."', () {
      expect(validateFileName('.'), isNotNull);
      expect(validateFileName('..'), isNotNull);
    });

    test('rechaza separadores de ruta y caracteres de control', () {
      expect(validateFileName('a/b'), isNotNull);
      expect(validateFileName('a\\b'), isNotNull);
      expect(validateFileName('a\nb'), isNotNull);
    });

    test('rechaza nombres demasiado largos', () {
      expect(validateFileName('a' * 200), isNotNull);
      expect(validateFileName('a' * 149), isNull);
    });

    test('acepta nombres normales (incluido unicode)', () {
      expect(validateFileName('Pride and Prejudice'), isNull);
      expect(validateFileName('Cien años de soledad'), isNull);
      expect(validateFileName('El túnel'), isNull);
    });
  });

  group('buildRenamedFileName', () {
    test('agrega la extensión del formato si no viene', () {
      expect(buildRenamedFileName('Pride and Prejudice', 'epub'),
          'Pride and Prejudice.epub');
      expect(buildRenamedFileName('El túnel', 'pdf'), 'El túnel.pdf');
      expect(buildRenamedFileName('Comic 1', 'cbr'), 'Comic 1.cbr');
    });

    test('respeta la extensión ya puesta (case-insensitive)', () {
      expect(buildRenamedFileName('book.EPUB', 'epub'), 'book.epub');
      expect(buildRenamedFileName('book.epub', 'epub'), 'book.epub');
    });

    test('reemplaza una extensión de otro formato', () {
      expect(buildRenamedFileName('book.pdf', 'epub'), 'book.epub');
      expect(buildRenamedFileName('book.epub', 'pdf'), 'book.pdf');
    });

    test('limpia espacios y puntos alrededor', () {
      expect(buildRenamedFileName('  book  ', 'pdf'), 'book.pdf');
      expect(buildRenamedFileName('.hidden.', 'pdf'), 'hidden.pdf');
    });
  });

  group('renameBookFile (operación de archivo)', () {
    test('renombra el archivo y conserva el contenido', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_rename');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/abc123.epub').writeAsStringSync('contenido');

      final newName =
          await renameBookFile(directory: dir.path, oldFileName: 'abc123.epub', newFileName: 'Mi Libro.epub');

      expect(newName, 'Mi Libro.epub');
      expect(File('${dir.path}/Mi Libro.epub').existsSync(), isTrue);
      expect(File('${dir.path}/Mi Libro.epub').readAsStringSync(), 'contenido');
      expect(File('${dir.path}/abc123.epub').existsSync(), isFalse);
    });

    test('falla si el destino ya existe y no toca nada', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_rename');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/abc123.epub').writeAsStringSync('original');
      File('${dir.path}/Mi Libro.epub').writeAsStringSync('otro');

      await expectLater(
        renameBookFile(directory: dir.path, oldFileName: 'abc123.epub', newFileName: 'Mi Libro.epub'),
        throwsA(isA<StateError>()),
      );
      expect(File('${dir.path}/abc123.epub').readAsStringSync(), 'original');
      expect(File('${dir.path}/Mi Libro.epub').readAsStringSync(), 'otro');
    });

    test('falla si el archivo original no existe', () async {
      final dir = await Directory.systemTemp.createTemp('openlib_rename');
      addTearDown(() => dir.deleteSync(recursive: true));
      await expectLater(
        renameBookFile(directory: dir.path, oldFileName: 'nada.epub', newFileName: 'otro.epub'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('renameDownloadedFile (flujo completo con BD)', () {
    late Directory storageDir;

    setUp(() async {
      storageDir = await Directory.systemTemp.createTemp('openlib_storage');
      addTearDown(() => storageDir.deleteSync(recursive: true));

      // path_provider debe devolver algo para abrir la BD en el host.
      PathProviderPlatform.instance = _FakePathProvider(storageDir.path);

      final db = await MyLibraryDb.instance.database;
      await db.delete('mybooks');
      await db.delete('bookposition');
      await db.delete('preferences');
      await MyLibraryDb.instance
          .savePreference('bookStorageDirectory', storageDir.path);
    });

    test('renombra el archivo, actualiza la BD y conserva la posición', () async {
      await MyLibraryDb.instance.insert(MyBook(
        id: 'abc123',
        title: 'Libro',
        author: 'Autor',
        thumbnail: null,
        link: 'http://x',
        publisher: null,
        info: null,
        format: 'epub',
        description: null,
      ));
      File('${storageDir.path}/abc123.epub').writeAsStringSync('libro');
      await MyLibraryDb.instance.saveBookState('abc123.epub', '42');

      final newName = await renameDownloadedFile(
          id: 'abc123', format: 'epub', newName: 'Mi Libro');

      expect(newName, 'Mi Libro.epub');
      expect(File('${storageDir.path}/abc123.epub').existsSync(), isFalse);
      expect(File('${storageDir.path}/Mi Libro.epub').existsSync(), isTrue);
      expect(await MyLibraryDb.instance.getStoredFileName('abc123'),
          'Mi Libro.epub');
      expect(await getBookFileName('abc123', 'epub'), 'Mi Libro.epub');
      // La posición de lectura migra al nombre nuevo.
      expect(await MyLibraryDb.instance.getBookState('Mi Libro.epub'), '42');
      expect(await MyLibraryDb.instance.getBookState('abc123.epub'), isNull);
    });

    test('getBookFileName usa el fallback md5.format sin renombrar', () async {
      await MyLibraryDb.instance.insert(MyBook(
        id: 'zzz99',
        title: 'Viejo',
        author: null,
        thumbnail: null,
        link: 'http://x',
        publisher: null,
        info: null,
        format: 'pdf',
        description: null,
      ));
      expect(await MyLibraryDb.instance.getStoredFileName('zzz99'), isNull);
      expect(await getBookFileName('zzz99', 'pdf'), 'zzz99.pdf');
    });

    test('falla con nombre inválido y no toca el archivo', () async {
      await MyLibraryDb.instance.insert(MyBook(
        id: 'abc123',
        title: 'Libro',
        author: null,
        thumbnail: null,
        link: 'http://x',
        publisher: null,
        info: null,
        format: 'epub',
        description: null,
      ));
      File('${storageDir.path}/abc123.epub').writeAsStringSync('libro');

      await expectLater(
        renameDownloadedFile(id: 'abc123', format: 'epub', newName: 'a/b'),
        throwsA(isA<ArgumentError>()),
      );
      expect(File('${storageDir.path}/abc123.epub').existsSync(), isTrue);
      expect(await MyLibraryDb.instance.getStoredFileName('abc123'), isNull);
    });

    test('falla si el nombre nuevo ya está en uso', () async {
      await MyLibraryDb.instance.insert(MyBook(
        id: 'abc123',
        title: 'Libro',
        author: null,
        thumbnail: null,
        link: 'http://x',
        publisher: null,
        info: null,
        format: 'epub',
        description: null,
      ));
      File('${storageDir.path}/abc123.epub').writeAsStringSync('original');
      File('${storageDir.path}/Ocupado.epub').writeAsStringSync('otro');

      await expectLater(
        renameDownloadedFile(id: 'abc123', format: 'epub', newName: 'Ocupado'),
        throwsA(isA<StateError>()),
      );
      expect(File('${storageDir.path}/abc123.epub').readAsStringSync(),
          'original');
      expect(File('${storageDir.path}/Ocupado.epub').readAsStringSync(), 'otro');
    });
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;

  _FakePathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
