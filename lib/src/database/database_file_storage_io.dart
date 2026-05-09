import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart';
import 'package:random_string/random_string.dart';

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


  Future<void> storeFileStream(Uri mxcUri, Stream<List<int>> stream, int time) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) return;

    final file = _getFileFromMxc(mxcUri);
    if (await file.exists()) return;

    final sink = file.openWrite();
    try {
      await for (final chunk in stream) {
        sink.add(chunk);
      }
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<Stream<List<int>>?> getFileStream(Uri mxcUri) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) return null;

    final file = _getFileFromMxc(mxcUri);

    if (await file.exists()) return file.openRead();
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


  /// Downloads [stream] directly to a file, returning the [File] object.
  /// Uses a temporary file during download to ensure the target file is only created upon completion.
  /// Throws [UnsupportedError] if file storage is not supported or [fileStorageLocation] is null.
  Future<File> downloadToFileViaStream(
    Stream<List<int>> stream,
    Uri mxcUri, {
    void Function(int)? onProgress,
    CancellationToken? cancellationToken,
  }) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) {
      throw UnsupportedError('File storage is not supported or configured on this platform.');
    }

    final targetFile = _getFileFromMxc(mxcUri);
    
    // If the file already exists, we can return it immediately.
    if (await targetFile.exists()) {
       return targetFile;
    }

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
      
      // Rename temporary file to the final target file.
      // Rename is generally atomic on POSIX systems.
      return await tmpFile.rename(targetFile.path);
    } catch (e) {
      // In case of error (including cancellation), clean up the temporary file.
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await tmpFile.exists()) {
          await tmpFile.delete();
        }
      } catch (_) {}
      rethrow;
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
