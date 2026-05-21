import 'dart:async';
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
    // 'ext' query param carries the file extension so iOS AVPlayer can detect the codec.
    final ext = mxcUri.queryParameters['ext'];
    final query = mxcUri.queryParameters.entries
        .where((e) => e.key != 'ext')
        .map((entry) => '${entry.key}${entry.value}')
        .join('_');
    final parts = [host, path, if (query.isNotEmpty) query];
    final fileName = '${parts.join('_')}${ext != null ? '.$ext' : ''}';
    return File(
      join(Directory.fromUri(fileStorageLocation!).path, fileName),
    );
  }


  Future<void> storeFileStream(Uri mxcUri, Stream<List<int>> stream, int time) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) {
      await stream.drain();
      return;
    }

    final file = _getFileFromMxc(mxcUri);
    final tmpFile = File('${file.path}_${DateTime.now().millisecondsSinceEpoch}_${randomAlphaNumeric(6)}.tmp');
    final sink = tmpFile.openWrite();
    var bytesWritten = 0;
    try {
      await sink.addStream(stream.map((chunk) {
        bytesWritten += chunk.length;
        return chunk;
      }));
      await sink.close();
      
      if (bytesWritten == 0) {
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}
        return;
      }

      if (await file.exists()) {
        await file.delete();
      }
      await tmpFile.rename(file.path);
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> storeFileFromPath(Uri mxcUri, String path, int time) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) {
      try {
        await File(path).delete();
      } catch (_) {}
      return;
    }

    final file = _getFileFromMxc(mxcUri);
    final srcFile = File(path);

    try {
      if (await file.exists()) {
        await file.delete();
      }
      await srcFile.rename(file.path);
    } catch (e) {
      // Fallback to copy if rename fails (e.g. across different filesystems)
      try {
        await srcFile.copy(file.path);
        await srcFile.delete();
      } catch (_) {}
    }
  }

  Future<File?> getFile(Uri mxcUri) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) return null;

    final file = _getFileFromMxc(mxcUri);

    if (await file.exists()) return file;
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

    // 文件已存在时必须先 drain stream，否则底层 HTTP socket 无法释放，
    // 会持续占用 IO 线程直到连接超时（defaultNetworkRequestTimeout），导致 CPU 持续高。
    if (await targetFile.exists()) {
      unawaited(stream.drain<void>().catchError((_) {}));
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
      await sink.addStream(stream.map((chunk) {
        cancellationToken?.throwIfCancelled();
        received += chunk.length;
        onProgress?.call(received);
        return chunk;
      }));
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
