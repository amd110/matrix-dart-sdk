import 'dart:io';

import 'package:matrix/matrix.dart';

mixin DatabaseFileStorage {
  bool get supportsFileStoring => false;

  late final Uri? fileStorageLocation;
  late final Duration? deleteFilesAfterDuration;

  Future<void> storeFileStream(Uri mxcUri, Stream<List<int>> stream, int time) async {
    await stream.drain();
  }

  Future<void> storeFileFromPath(Uri mxcUri, String path, int time) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  Future<File?> getFile(Uri mxcUri) async {
    return null;
  }

  Future<void> deleteOldFiles(int savedAt) async {
    return; // Not supported. Cache is cleared on every app restart anyway.
  }

  Future<bool> deleteFile(Uri mxcUri) async {
    return false;
  }

  Future<void> storeCacheFileAs(Uri srcUri, Uri dstUri) async {
    // stub: 不支持文件存储，无操作
  }

  /// Stub: never called because [supportsFileStoring] is always false on web.
  Future<File> downloadToFileViaStream(
    Stream<List<int>> stream,
    Uri mxcUri, {
    void Function(int)? onProgress,
    CancellationToken? cancellationToken,
  }) =>
      throw UnsupportedError(
        'downloadToFileViaStream is not supported on web/stub platform.',
      );
}

