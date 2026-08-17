// Dart imports:
import 'dart:io';

// Package imports:
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

// Project imports:
import 'package:openlib/services/database.dart';
import 'package:openlib/state/state.dart' show myLibraryProvider;

MyLibraryDb dataBase = MyLibraryDb.instance;

Future<String> get getBookStorageDefaultDirectory async {
  if (Platform.isAndroid) {
    final directory = await getExternalStorageDirectory();
    return directory!.path;
  } else {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }
}

Future<void> moveFilesToAndroidInternalStorage() async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    final directoryExternal = await getExternalStorageDirectory();
    List<FileSystemEntity> files = Directory(directory.path).listSync();
    for (var element in files) {
      if ((element.path.contains('pdf')) || element.path.contains('epub')) {
        String fileName = element.path.split('/').last;
        File file = File(element.path);
        file.copySync('${directoryExternal!.path}/$fileName');
        file.deleteSync();
      }
    }
  } catch (e) {
    // ignore: avoid_print
    print(e);
  }
}

Future<void> moveFolderContents(
    String source_path, String destination_path) async {
  final source = Directory(source_path);
  source.listSync(recursive: false).forEach((var entity) {
    if (entity is Directory) {
      var newDirectory =
          Directory('${destination_path}/${entity.path.split('/').last}');
      newDirectory.createSync();
      moveFolderContents(entity.path, newDirectory.path);
      entity.deleteSync();
    } else if (entity is File) {
      entity.copySync('${destination_path}/${entity.path.split('/').last}');
      entity.deleteSync();
    }
  });
}

Future<bool> isFileExists(String filePath) async {
  return await File(filePath).exists();
}

Future<void> deleteFile(String filePath) async {
  if (await isFileExists(filePath) == true) {
    await File(filePath).delete();
  }
}

Future<String> getFilePath(String fileName) async {
  final bookStorageDirectory =
      await dataBase.getPreference('bookStorageDirectory');
  String filePath = '$bookStorageDirectory/$fileName';
  bool isExists = await isFileExists(filePath);
  if (isExists == true) {
    return filePath;
  }
  throw "File Not Exists";
}

/// Nombre real del archivo de un libro descargado: el nombre renombrado
/// guardado en la BD si existe, o el nombre por defecto `\$md5.\$format`.
Future<String> getBookFileName(String id, String format) async {
  final stored = await dataBase.getStoredFileName(id);
  if (stored != null && stored.isNotEmpty) {
    return stored;
  }
  return '$id.$format';
}

/// Valida un nombre de archivo propuesto por el usuario. Devuelve un mensaje
/// de error o null si el nombre es válido.
String? validateFileName(String name, {int maxLength = 150}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return 'The name cannot be empty';
  }
  if (trimmed == '.' || trimmed == '..') {
    return 'Invalid file name';
  }
  if (trimmed.length > maxLength) {
    return 'The name is too long (max $maxLength characters)';
  }
  if (trimmed.contains('/') || trimmed.contains('\\')) {
    return 'The name cannot contain / or \\';
  }
  if (trimmed.codeUnits.any((unit) => unit < 0x20)) {
    return 'The name contains invalid characters';
  }
  return null;
}

/// Construye el nombre final del archivo: limpia el nombre propuesto y le
/// agrega (o conserva) la extensión del formato.
String buildRenamedFileName(String name, String format) {
  var base = name.trim().replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  if (format.isEmpty) {
    return base;
  }
  const knownFormats = ['pdf', 'epub', 'cbr', 'cbz', 'mobi', 'azw'];
  for (final known in knownFormats) {
    if (base.toLowerCase().endsWith('.$known')) {
      base = base.substring(0, base.length - known.length - 1).trim();
      break;
    }
  }
  return '$base.$format';
}

/// Renombra físicamente un archivo dentro de [directory]. Devuelve el nombre
/// nuevo. Lanza [StateError] si el origen no existe o el destino ya existe.
Future<String> renameBookFile({
  required String directory,
  required String oldFileName,
  required String newFileName,
}) async {
  final oldPath = '$directory/$oldFileName';
  final newPath = '$directory/$newFileName';
  if (!await isFileExists(oldPath)) {
    throw StateError('File not found');
  }
  if (await isFileExists(newPath)) {
    throw StateError('A file named "$newFileName" already exists');
  }
  await File(oldPath).rename(newPath);
  return newFileName;
}

/// Construye el nombre de archivo por defecto a partir del título del libro:
/// solo letras y números ASCII (sin espacios, sin emojis ni caracteres raros),
/// con la extensión del formato. Devuelve null si no queda ningún carácter
/// seguro (p.ej. un título compuesto solo de emojis).
String? buildDownloadFileName(String title, String format) {
  final cleaned =
      _stripDiacritics(title).replaceAll(RegExp(r'[^A-Za-z0-9]+'), '');
  if (cleaned.isEmpty) {
    return null;
  }
  final base = cleaned.length > 100 ? cleaned.substring(0, 100) : cleaned;
  return '$base.$format';
}

/// Sustituye las vocales/consonantes acentuadas más comunes por su
/// equivalente ASCII (para que el nombre de archivo no se rompa).
String _stripDiacritics(String input) {
  const map = {
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
    'Á': 'A', 'À': 'A', 'Â': 'A', 'Ä': 'A', 'Ã': 'A', 'Å': 'A', 'Ā': 'A',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ė': 'e', 'ę': 'e',
    'É': 'E', 'È': 'E', 'Ê': 'E', 'Ë': 'E', 'Ē': 'E', 'Ė': 'E', 'Ę': 'E',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'į': 'i', 'ı': 'i',
    'Í': 'I', 'Ì': 'I', 'Î': 'I', 'Ï': 'I', 'Ī': 'I', 'Į': 'I',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ō': 'o', 'ő': 'o',
    'Ó': 'O', 'Ò': 'O', 'Ô': 'O', 'Ö': 'O', 'Õ': 'O', 'Ō': 'O', 'Ő': 'O',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ů': 'u', 'ű': 'u',
    'Ú': 'U', 'Ù': 'U', 'Û': 'U', 'Ü': 'U', 'Ū': 'U', 'Ů': 'U', 'Ű': 'U',
    'ñ': 'n', 'Ñ': 'N', 'ç': 'c', 'Ç': 'C', 'ý': 'y', 'ÿ': 'y', 'Ý': 'Y',
    'š': 's', 'Š': 'S', 'ž': 'z', 'Ž': 'Z', 'č': 'c', 'Č': 'C', 'ř': 'r',
    'Ř': 'R', 'ď': 'd', 'Ď': 'D', 'ť': 't', 'Ť': 'T', 'ň': 'n', 'Ň': 'N',
    'ľ': 'l', 'Ľ': 'L', 'æ': 'ae', 'Æ': 'AE', 'œ': 'oe', 'Œ': 'OE',
    'ß': 'ss', 'ø': 'o', 'Ø': 'O', 'đ': 'd', 'Đ': 'D', 'ð': 'd', 'Ð': 'D',
  };
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    buffer.write(map[String.fromCharCode(rune)] ?? String.fromCharCode(rune));
  }
  return buffer.toString();
}

/// Aplica el nombre por defecto (título saneado) a un archivo recién
/// descargado y lo guarda en la BD. Devuelve el nombre final del archivo.
/// Si el nombre saneado es null o ya existe un archivo con ese nombre, se
/// conserva `\$id.\$format` sin tocar nada.
Future<String> applyDefaultDownloadName({
  required String id,
  required String title,
  required String format,
}) async {
  final bookStorageDirectory =
      await dataBase.getPreference('bookStorageDirectory');
  final fallback = '$id.$format';
  final defaultName = buildDownloadFileName(title, format);
  if (defaultName == null || defaultName == fallback) {
    return fallback;
  }
  final newPath = '$bookStorageDirectory/$defaultName';
  if (await isFileExists(newPath)) {
    return fallback;
  }
  await File('$bookStorageDirectory/$fallback').rename(newPath);
  await dataBase.updateFileName(id, defaultName);
  return defaultName;
}

/// Registra el `.mobi` generado en la biblioteca con los metadatos del libro
/// fuente (equivalente a [registerConvertedFile] con formato `mobi`).
Future<void> registerMobiInLibrary({
  required String sourceId,
  required String mobiFileName,
}) =>
    registerConvertedFile(
      sourceId: sourceId,
      format: 'mobi',
      fileName: mobiFileName,
    );

/// Registra un archivo convertido (`.mobi` o `.azw`) en la biblioteca con los
/// metadatos del libro fuente, para que aparezca en "My Library" y se pueda
/// abrir, renombrar y eliminar. No hace nada si el libro fuente no existe en
/// la BD.
Future<void> registerConvertedFile({
  required String sourceId,
  required String format,
  required String fileName,
}) async {
  final source = await dataBase.getId(sourceId);
  if (source == null) {
    return;
  }
  await dataBase.insert(MyBook(
    id: '$sourceId.$format',
    title: source.title,
    author: source.author,
    thumbnail: source.thumbnail,
    link: source.link,
    publisher: source.publisher,
    info: source.info,
    format: format,
    description: source.description,
    fileName: fileName,
  ));
}

/// Renombra un libro descargado: mueve el archivo, guarda el nombre nuevo en
/// la BD y migra la posición de lectura. Devuelve el nombre final del archivo.
Future<String> renameDownloadedFile({
  required String id,
  required String format,
  required String newName,
}) async {
  final validationError = validateFileName(newName);
  if (validationError != null) {
    throw ArgumentError(validationError);
  }
  final bookStorageDirectory =
      await dataBase.getPreference('bookStorageDirectory');
  final oldFileName = await getBookFileName(id, format);
  final newFileName = buildRenamedFileName(newName, format);

  await renameBookFile(
    directory: bookStorageDirectory,
    oldFileName: oldFileName,
    newFileName: newFileName,
  );
  await dataBase.updateFileName(id, newFileName);

  // Migra la posición de lectura guardada con el nombre anterior.
  final position = await dataBase.getBookState(oldFileName);
  if (position != null) {
    await dataBase.deleteBookState(oldFileName);
    await dataBase.saveBookState(newFileName, position);
  }
  return newFileName;
}

Future<void> deleteFileWithDbData(
    FutureProviderRef ref, String md5, String format) async {
  try {
    String fileName = await getBookFileName(md5, format);
    final bookStorageDirectory =
        await dataBase.getPreference('bookStorageDirectory');
    await deleteFile('$bookStorageDirectory/$fileName');
    await dataBase.delete(md5);
    await dataBase.deleteBookState(fileName);
    // ignore: unused_result
    ref.refresh(myLibraryProvider);
  } catch (e) {
    // print(e);
    rethrow;
  }
}
