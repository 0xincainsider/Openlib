// Flutter imports:
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Package imports:
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';

// Project imports:
import 'package:openlib/services/convert_to_mobi.dart';
import 'package:openlib/services/files.dart'
    show getBookFileName, getFilePath, registerConvertedFile, renameDownloadedFile;
import 'package:openlib/state/state.dart' show myLibraryProvider;
import 'package:openlib/ui/components/delete_dialog_widget.dart';
import 'package:openlib/ui/components/snack_bar_widget.dart';
import 'package:openlib/ui/epub_viewer.dart' show launchEpubViewer;
import 'package:openlib/ui/pdf_viewer.dart' show launchPdfViewer;

class FileOpenAndDeleteButtons extends ConsumerWidget {
  final String id;
  final String format;
  final String? title;
  final String? author;
  final Function onDelete;

  const FileOpenAndDeleteButtons(
      {super.key,
      required this.id,
      required this.format,
      this.title,
      this.author,
      required this.onDelete});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canConvert = format == 'pdf' || format == 'epub';
    return Padding(
      padding: const EdgeInsets.only(top: 21, bottom: 21),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          TextButton(
            style: TextButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.secondary,
                textStyle: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: Theme.of(context).colorScheme.primary,
                )),
            onPressed: () async {
              final fileName = await getBookFileName(id, format);
              if (!context.mounted) {
                return;
              }
              if (format == 'pdf') {
                await launchPdfViewer(
                    fileName: fileName, context: context, ref: ref);
              } else if (format == 'epub') {
                await launchEpubViewer(
                    fileName: fileName, context: context, ref: ref);
              } else {
                await openCbrAndCbz(fileName: fileName, context: context);
              }
            },
            child: const Padding(
              padding: EdgeInsets.fromLTRB(17, 8, 17, 8),
              child: Text('Open'),
            ),
          ),
          if (canConvert)
            TextButton(
              style: TextButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  textStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: Theme.of(context).colorScheme.primary,
                  )),
              onPressed: () => _convertFile(context, ref, 'mobi'),
              child: const Padding(
                padding: EdgeInsets.fromLTRB(17, 8, 17, 8),
                child: Text('Convert to MOBI'),
              ),
            ),
          if (canConvert)
            TextButton(
              style: TextButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  textStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: Theme.of(context).colorScheme.primary,
                  )),
              onPressed: () => _convertFile(context, ref, 'azw'),
              child: const Padding(
                padding: EdgeInsets.fromLTRB(17, 8, 17, 8),
                child: Text('Convert to AZW'),
              ),
            ),
          IconButton(
            tooltip: 'Rename',
            icon: Icon(
              Icons.drive_file_rename_outline,
              color: Theme.of(context).colorScheme.tertiary,
            ),
            iconSize: 21,
            onPressed: () => _renameFile(context),
          ),
          TextButton(
            style: ButtonStyle(
              shape: WidgetStateProperty.all(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(50.0),
                  side: BorderSide(
                      width: 3, color: Theme.of(context).colorScheme.secondary),
                ),
              ),
            ),
            onPressed: () {
              showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (BuildContext context) {
                    return ShowDeleteDialog(
                      id: id,
                      format: format,
                      onDelete: onDelete,
                    );
                  });
            },
            child: Padding(
              padding: const EdgeInsets.all(5.3),
              child: Text(
                'Delete',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Converts the downloaded file to MOBI or AZW in a background isolate and
  /// reports the outcome with a snackbar. [outputExtension] is `mobi` or
  /// `azw` (AZW is the same Mobipocket container; the Kindle reads `.azw`
  /// files as native ebooks, which avoids the blank-page bug some firmwares
  /// show for sideloaded `.mobi` files).
  Future<void> _convertFile(
      BuildContext context, WidgetRef ref, String outputExtension) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    String path;
    try {
      final fileName = await getBookFileName(id, format);
      path = await getFilePath(fileName);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('File not found!')));
      return;
    }
    if (!context.mounted) {
      return;
    }

    final outputLabel = outputExtension.toUpperCase();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 25,
                height: 25,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Text(
                  'Converting to $outputLabel...',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    final request = ConvertRequest(
      sourcePath: path,
      sourceFormat: format,
      title: title,
      author: author,
    );
    try {
      final result = outputExtension == 'azw'
          ? await compute(convertToAzwInBackground, request)
          : await compute(convertToMobiInBackground, request);
      navigator.pop(); // close progress dialog
      // Registra el archivo en la biblioteca para que aparezca en "My Library"
      // y se pueda abrir, renombrar y eliminar.
      final fileName = result.outputPath.split(RegExp(r'[/\\]')).last;
      try {
        await registerConvertedFile(
            sourceId: id, format: outputExtension, fileName: fileName);
        // ignore: unused_result
        ref.refresh(myLibraryProvider);
      } catch (_) {
        // El archivo ya está escrito; si el registro falla, el artefacto
        // sigue accesible desde el servidor local.
      }
      messenger.showSnackBar(SnackBar(
        content: Text('Converted! Saved as $fileName'),
      ));
    } catch (e) {
      navigator.pop(); // close progress dialog
      messenger.showSnackBar(SnackBar(
        content: Text('Conversion failed: $e'),
      ));
    }
  }

  /// Renames the downloaded file, keeping the format extension.
  Future<void> _renameFile(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    String currentFileName;
    try {
      currentFileName = await getBookFileName(id, format);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('File not found!')));
      return;
    }
    if (!context.mounted) {
      return;
    }

    // Prefill with the current name without its extension.
    final currentBase = currentFileName.contains('.')
        ? currentFileName.substring(0, currentFileName.lastIndexOf('.'))
        : currentFileName;
    final controller = TextEditingController(text: currentBase);

    final newName = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Rename file',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.tertiary,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'New name (.$format is added automatically)',
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );

    if (newName == null || newName.trim().isEmpty) {
      return;
    }
    try {
      final result = await renameDownloadedFile(
        id: id,
        format: format,
        newName: newName,
      );
      messenger.showSnackBar(SnackBar(content: Text('Renamed to $result')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Rename failed: $e')));
    }
  }
}

Future<void> openCbrAndCbz(
    {required String fileName, required BuildContext context}) async {
  try {
    String path = await getFilePath(fileName);
    await OpenFile.open(path, linuxByProcess: true);
  } catch (e) {
    // ignore: avoid_print
    // print(e);
    // ignore: use_build_context_synchronously
    showSnackBar(context: context, message: 'Unable to open file!');
  }
}
