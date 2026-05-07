import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart';
import 'package:random_string/random_string.dart';

import 'package:matrix/matrix.dart';

// ignore: unused-code
mixin DatabaseFileStorage {
  bool get supportsFileStoring => fileStorageLocation != null;

  late final Uri? fileStorageLocation;
  late final Duration? deleteFilesAfterDuration;

  /// Map an MXC URI to a local File path
  File _getFileFromMxc(Uri mxcUri) {
    // Replace all special characters with underscores to avoid PathNotFoundException on Windows.
    final host = mxcUri.host.replaceAll('.', '_');
    final path = mxcUri.pathSegments.join('_');
    final query = mxcUri.queryParameters.entries
        .map((entry) => '${entry.key}${entry.value}')
        .join('_');
    final fileName = '${host}_${path}_$query';
    return File(
      join(Directory.fromUri(fileStorageLocation!).path, fileName),
    );
  }

  Future<void> storeFile(Uri mxcUri, Uint8List bytes, int time) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) return;

    final file = _getFileFromMxc(mxcUri);

    if (await file.exists()) return;
    await file.writeAsBytes(bytes);
  }

  Future<Uint8List?> getFile(Uri mxcUri) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) return null;

    final file = _getFileFromMxc(mxcUri);

    if (await file.exists()) return await file.readAsBytes();
    return null;
  }

  Future<bool> deleteFile(Uri mxcUri) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) return false;

    final file = _getFileFromMxc(mxcUri);

    if (await file.exists() == false) return false;

    await file.delete();
    return true;
  }

  /// Downloads [stream] to memory, buffering through a temporary file when
  /// [fileStorageLocation] is available to reduce peak heap usage.
  /// Falls back to direct in-memory collection when file storage is disabled.
  Future<Uint8List> downloadToMemoryViaStream(
    Stream<List<int>> stream, {
    void Function(int)? onProgress,
    CancellationToken? cancellationToken,
  }) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) {
      // 降级：内存收集（与 toBytesWithProgress 等效）
      final chunks = <Uint8List>[];
      var received = 0;
      await for (final chunk in stream) {
        cancellationToken?.throwIfCancelled();
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        chunks.add(bytes);
        received += bytes.length;
        onProgress?.call(received);
      }
      if (chunks.isEmpty) return Uint8List(0);
      if (chunks.length == 1) return chunks.first;
      final result = Uint8List(received);
      var offset = 0;
      for (final c in chunks) {
        result.setRange(offset, offset + c.length, c);
        offset += c.length;
      }
      return result;
    }

    // Use timestamp + random suffix to avoid naming collisions on concurrent downloads.
    final tmpFile = File(
      join(
        Directory.fromUri(fileStorageLocation).path,
        '${DateTime.now().millisecondsSinceEpoch}${randomAlphaNumeric(16)}.tmp',
      ),
    );
    final sink = tmpFile.openWrite();
    try {
      var received = 0;
      await for (final chunk in stream) {
        cancellationToken?.throwIfCancelled();
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
      }
      await sink.close();
      return await tmpFile.readAsBytes();
    } finally {
      // Always clean up the temporary buffer file — even on the success path
      // the data has already been read into memory via readAsBytes() above.
      await sink.close().catchError((_) {});
      if (await tmpFile.exists()) await tmpFile.delete();
    }
  }

  Future<void> deleteOldFiles(int savedAt) async {
    final dirUri = fileStorageLocation;
    final deleteFilesAfterDuration = this.deleteFilesAfterDuration;
    if (!supportsFileStoring ||
        dirUri == null ||
        deleteFilesAfterDuration == null) {
      return;
    }
    final dir = Directory.fromUri(dirUri);
    final entities = await dir.list().toList();
    for (final file in entities) {
      if (file is! File) continue;
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified) > deleteFilesAfterDuration) {
        Logs().v('Delete old file', file.path);
        await file.delete();
      }
    }
  }
}
