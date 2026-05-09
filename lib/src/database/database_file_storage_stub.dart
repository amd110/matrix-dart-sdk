import 'dart:io';

import 'package:matrix/matrix.dart';

mixin DatabaseFileStorage {
  bool get supportsFileStoring => false;

  late final Uri? fileStorageLocation;
  late final Duration? deleteFilesAfterDuration;

  Future<void> storeFileStream(Uri mxcUri, Stream<List<int>> stream, int time) async {
    await stream.drain();
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

