import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

extension ToBytesWithProgress on http.ByteStream {
  /// Collects the data of this stream in a [Uint8List].
  ///
  /// When [contentLength] is provided the buffer is pre-allocated to avoid
  /// repeated resizing (and the associated peak-memory doubling) for large
  /// files such as videos.
  Future<Uint8List> toBytesWithProgress(
    void Function(int)? onProgress, {
    int? contentLength,
  }) async {
    final chunks = <Uint8List>[];
    var received = 0;

    await for (final chunk in this) {
      chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
      received += chunk.length;
      onProgress?.call(received);
    }

    if (chunks.isEmpty) return Uint8List(0);
    if (chunks.length == 1) return chunks.first;

    // Pre-allocate the exact output buffer instead of letting ByteConversionSink
    // grow a List<int> dynamically (which can peak at 2–3× the file size).
    final totalLength = contentLength ?? received;
    final result = Uint8List(totalLength);
    var offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }
}
