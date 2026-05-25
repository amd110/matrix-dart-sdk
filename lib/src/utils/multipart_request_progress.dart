import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 通过 [CancellationToken] 取消下载时抛出的异常。
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => 'DownloadCancelledException: 下载已被取消';
}

/// 下载取消句柄，传入 [downloadAndDecryptAttachment] 使用。
///
/// 调用 [cancel] 可中止正在进行的下载或解密操作，
/// 操作会在下一个取消检查点抛出 [DownloadCancelledException]。
class CancellationToken {
  bool _cancelled = false;
  Completer<void>? _completer;

  /// 是否已调用过 [cancel]。
  bool get isCancelled => _cancelled;

  /// 取消时完成的 Future，用于 await 竞争场景。
  Future<void> get whenCancelled {
    _completer ??= Completer<void>();
    if (_cancelled) _completer!.complete();
    return _completer!.future;
  }

  /// 请求取消所有正在监听此 token 的操作。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completer?.complete();
  }

  /// 若已取消则抛出 [DownloadCancelledException]。
  void throwIfCancelled() {
    if (_cancelled) throw const DownloadCancelledException();
  }
}

extension ToBytesWithProgress on http.ByteStream {
  /// 将流中的数据收集为 [Uint8List]。
  ///
  /// 提供 [contentLength] 时会预分配精确大小的缓冲区，避免大文件（如视频）
  /// 动态扩容时峰值内存达到文件大小 2–3 倍的问题。
  ///
  /// 提供 [cancellationToken] 时，调用 [CancellationToken.cancel] 即可中止下载；
  /// 底层 StreamSubscription 会被立即取消（关闭 TCP 连接），
  /// future 以 [DownloadCancelledException] 完成。
  Future<Uint8List> toBytesWithProgress(
    void Function(int)? onProgress, {
    int? contentLength,
    CancellationToken? cancellationToken,
  }) {
    final completer = Completer<Uint8List>();
    final chunks = <Uint8List>[];
    var received = 0;

    // 使用手动订阅而非 await for，以便取消时能立即调用 sub.cancel() 关闭连接
    late StreamSubscription<List<int>> sub;
    sub = listen(
      (chunk) {
        // 每个数据块到达时检查取消标志
        if (cancellationToken?.isCancelled == true) {
          sub.cancel(); // 立即关闭底层 TCP 连接，停止接收数据
          if (!completer.isCompleted) {
            completer.completeError(const DownloadCancelledException());
          }
          return;
        }
        chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
        received += chunk.length;
        onProgress?.call(received);
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
      onDone: () {
        if (completer.isCompleted) return;

        if (chunks.isEmpty) {
          completer.complete(Uint8List(0));
          return;
        }
        if (chunks.length == 1) {
          completer.complete(chunks.first);
          return;
        }

        // 预分配精确大小的输出缓冲区，用 setRange 一次性写入，
        // 避免 ByteConversionSink 动态增长 List<int> 造成的额外内存峰值
        final totalLength = contentLength ?? received;
        final result = Uint8List(totalLength);
        var offset = 0;
        for (final c in chunks) {
          result.setRange(offset, offset + c.length, c);
          offset += c.length;
        }
        completer.complete(result);
      },
      cancelOnError: true,
    );

    return completer.future;
  }
}
