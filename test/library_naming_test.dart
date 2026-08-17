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

  group('buildDownloadFileName', () {
    test('quita espacios, emojis y puntuación', () {
      expect(
          buildDownloadFileName("Harry Potter and the Sorcerer's Stone",
              'epub'),
          'HarryPotterandtheSorcerersStone.epub');
      expect(buildDownloadFileName('Don Quixote: Part 1!', 'pdf'),
          'DonQuixotePart1.pdf');
      expect(buildDownloadFileName('Harry 📚 Potter 🧙', 'epub'),
          'HarryPotter.epub');
    });

    test('translitera acentos a ASCII', () {
      expect(buildDownloadFileName('Cien años de soledad', 'pdf'),
          'Cienanosdesoledad.pdf');
      expect(buildDownloadFileName('Ángeles y demonios', 'epub'),
          'Angelesydemonios.epub');
      expect(buildDownloadFileName('El túnel', 'cbr'), 'Eltunel.cbr');
    });

    test('conserva la extensión del formato', () {
      expect(buildDownloadFileName('Pride and Prejudice', 'mobi'),
          'PrideandPrejudice.mobi');
      expect(buildDownloadFileName('Metamorphosis', 'pdf'), 'Metamorphosis.pdf');
    });

    test('devuelve null si no queda ningún carácter seguro', () {
      expect(buildDownloadFileName('📚🎉', 'epub'), isNull);
      expect(buildDownloadFileName('   ---   ', 'pdf'), isNull);
    });

    test('limita la longitud a 100 caracteres', () {
      final name = buildDownloadFileName('A' * 250, 'epub')!;
      expect(name.length, 105); // 100 + '.epub'
      expect(name.endsWith('.epub'), isTrue);
    });
  });

  group('applyDefaultDownloadName (flujo de descarga con BD)', () {
    late Directory storageDir;

    setUp(() async {
      storageDir = await Directory.systemTemp.createTemp('openlib_storage');
      addTearDown(() => storageDir.deleteSync(recursive: true));

      PathProviderPlatform.instance = _FakePathProvider(storageDir.path);

      final db = await MyLibraryDb.instance.database;
      await db.delete('mybooks');
      await db.delete('bookposition');
      await db.delete('preferences');
      await MyLibraryDb.instance
          .savePreference('bookStorageDirectory', storageDir.path);
    });

    test('renombra el archivo recién descargado al título saneado', () async {
      await MyLibraryDb.instance.insert(MyBook(
        id: 'abc123',
        title: 'Harry Potter',
        author: null,
        thumbnail: null,
        link: 'http://x',
        publisher: null,
        info: null,
        format: 'epub',
        description: null,
      ));
      File('${storageDir.path}/abc123.epub').writeAsStringSync('libro');

      final name = await applyDefaultDownloadName(
          id: 'abc123', title: 'Harry Potter', format: 'epub');

      expect(name, 'HarryPotter.epub');
      expect(File('${storageDir.path}/abc123.epub').existsSync(), isFalse);
      expect(File('${storageDir.path}/HarryPotter.epub').readAsStringSync(),
          'libro');
      expect(await MyLibraryDb.instance.getStoredFileName('abc123'),
          'HarryPotter.epub');
      expect(await getBookFileName('abc123', 'epub'), 'HarryPotter.epub');
    });

    test('si el nombre saneado ya existe, conserva el md5.format sin '
        'sobrescribir nada', () async {
      await MyLibraryDb.instance.insert(MyBook(
        id: 'abc123',
        title: 'Harry Potter',
        author: null,
        thumbnail: null,
        link: 'http://x',
        publisher: null,
        info: null,
        format: 'epub',
        description: null,
      ));
      File('${storageDir.path}/abc123.epub').writeAsStringSync('nuevo');
      File('${storageDir.path}/HarryPotter.epub').writeAsStringSync('otro');

      final name = await applyDefaultDownloadName(
          id: 'abc123', title: 'Harry Potter', format: 'epub');

      expect(name, 'abc123.epub');
      expect(File('${storageDir.path}/HarryPotter.epub').readAsStringSync(),
          'otro');
      expect(File('${storageDir.path}/abc123.epub').readAsStringSync(), 'nuevo');
      expect(await MyLibraryDb.instance.getStoredFileName('abc123'), isNull);
    });

    test('título sin caracteres seguros conserva el md5.format', () async {
      await MyLibraryDb.instance.insert(MyBook(
        id: 'abc123',
        title: '📚',
        author: null,
        thumbnail: null,
        link: 'http://x',
        publisher: null,
        info: null,
        format: 'epub',
        description: null,
      ));
      File('${storageDir.path}/abc123.epub').writeAsStringSync('libro');

      final name =
          await applyDefaultDownloadName(id: 'abc123', title: '📚', format: 'epub');

      expect(name, 'abc123.epub');
      expect(File('${storageDir.path}/abc123.epub').existsSync(), isTrue);
      expect(await MyLibraryDb.instance.getStoredFileName('abc123'), isNull);
    });
  });

  group('registerMobiInLibrary (flujo de conversión con BD)', () {
    late Directory storageDir;

    setUp(() async {
      storageDir = await Directory.systemTemp.createTemp('openlib_storage');
      addTearDown(() => storageDir.deleteSync(recursive: true));

      PathProviderPlatform.instance = _FakePathProvider(storageDir.path);

      final db = await MyLibraryDb.instance.database;
      await db.delete('mybooks');
      await db.delete('bookposition');
      await db.delete('preferences');
      await MyLibraryDb.instance
          .savePreference('bookStorageDirectory', storageDir.path);
    });

    test('registra el mobi con los metadatos del libro fuente', () async {
      await MyLibraryDb.instance.insert(MyBook(
        id: 'abc123',
        title: 'Harry Potter',
        author: 'J.K. Rowling',
        thumbnail: 'http://img/cover.jpg',
        link: 'http://x',
        publisher: 'Bloomsbury',
        info: 'info',
        format: 'epub',
        description: 'desc',
      ));
      File('${storageDir.path}/HarryPotter.mobi').writeAsStringSync('mobidata');

      await registerMobiInLibrary(
          sourceId: 'abc123', mobiFileName: 'HarryPotter.mobi');

      final mobi = await MyLibraryDb.instance.getId('abc123.mobi');
      expect(mobi, isNotNull);
      expect(mobi!.format, 'mobi');
      expect(mobi.fileName, 'HarryPotter.mobi');
      expect(mobi.title, 'Harry Potter');
      expect(mobi.author, 'J.K. Rowling');
      expect(mobi.thumbnail, 'http://img/cover.jpg');
      expect(mobi.publisher, 'Bloomsbury');
      expect(mobi.description, 'desc');
      expect(await getBookFileName('abc123.mobi', 'mobi'), 'HarryPotter.mobi');

      // Aparece en la biblioteca junto al libro fuente.
      final all = await MyLibraryDb.instance.getAll();
      expect(all.length, 2);
      expect(all.map((b) => b.id), containsAll(['abc123', 'abc123.mobi']));
    });

    test('no hace nada si el libro fuente no existe en la BD', () async {
      await registerMobiInLibrary(
          sourceId: 'nohay', mobiFileName: 'x.mobi');
      expect(await MyLibraryDb.instance.getAll(), isEmpty);
    });

    test('el mobi se puede renombrar con el flujo existente', () async {
      await MyLibraryDb.instance.insert(MyBook(
        id: 'abc123',
        title: 'Harry Potter',
        author: null,
        thumbnail: null,
        link: 'http://x',
        publisher: null,
        info: null,
        format: 'epub',
        description: null,
      ));
      File('${storageDir.path}/abc123.epub').writeAsStringSync('epub');
      File('${storageDir.path}/HarryPotter.mobi').writeAsStringSync('mobi');
      await registerMobiInLibrary(
          sourceId: 'abc123', mobiFileName: 'HarryPotter.mobi');

      final newName = await renameDownloadedFile(
          id: 'abc123.mobi', format: 'mobi', newName: 'Mi MOBI');

      expect(newName, 'Mi MOBI.mobi');
      expect(File('${storageDir.path}/HarryPotter.mobi').existsSync(), isFalse);
      expect(File('${storageDir.path}/Mi MOBI.mobi').readAsStringSync(), 'mobi');
      expect(await getBookFileName('abc123.mobi', 'mobi'), 'Mi MOBI.mobi');
    });
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;

  _FakePathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
