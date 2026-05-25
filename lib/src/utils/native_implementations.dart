import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/compute_callback.dart';
import 'package:matrix/src/utils/crypto/encrypted_file.dart' as crypto_utils;

/// 提供耗时运算的原生实现，防止 UI 线程阻塞。
///
/// 可用实现：
/// - [NativeImplementationsDummy]：内联执行，会阻塞 UI
/// - [NativeImplementationsIsolate]：基于 Flutter `compute` 的临时 isolate
/// - [NativeImplementationsPersistentIsolate]：单一长期存活的 isolate
abstract class NativeImplementations {
  const NativeImplementations();

  static const dummy = NativeImplementationsDummy();

  FutureOr<MatrixImageFileResizedResponse?> shrinkImage(
    MatrixImageFileResizeArguments args, {
    bool retryInDummy = false,
  });

  FutureOr<MatrixImageFileResizedResponse?> calcImageMetadata(
    Uint8List bytes, {
    bool retryInDummy = false,
  });

  FutureOr<RoomKeys> generateUploadKeys(
    GenerateUploadKeysArgs args, {
    bool retryInDummy = true,
  });

  FutureOr<Uint8List> keyFromPassphrase(
    KeyFromPassphraseArgs args, {
    bool retryInDummy = true,
  });

  /// 将 [file] 加密到临时文件并返回元数据。
  /// [cancellationToken] 触发时抛出 [DownloadCancelledException]。
  FutureOr<EncryptedFile> encryptFile(
    File file, {
    bool retryInDummy = true,
    CancellationToken? cancellationToken,
  });

  /// 将 [encryptedFile] 解密到临时文件并返回。
  /// [cancellationToken] 触发时抛出 [DownloadCancelledException]。
  FutureOr<File> decryptFile(
    EncryptedFile encryptedFile, {
    bool retryInDummy = true,
    CancellationToken? cancellationToken,
  });

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final dynamic argument = invocation.positionalArguments.single;
    final memberName = invocation.memberName.toString().split('"')[1];

    Logs().d(
      'Missing implementations of Client.nativeImplementations.$memberName. '
      'You should consider implementing it. '
      'Fallback from NativeImplementations.dummy used.',
    );
    switch (memberName) {
      case 'shrinkImage':
        return dummy.shrinkImage(argument);
      case 'calcImageMetadata':
        return dummy.calcImageMetadata(argument);
      case 'generateUploadKeys':
        // ignore: discarded_futures
        return dummy.generateUploadKeys(argument);
      case 'keyFromPassphrase':
        // ignore: discarded_futures
        return dummy.keyFromPassphrase(argument);
      case 'encryptFile':
        // ignore: discarded_futures
        return dummy.encryptFile(argument);
      case 'decryptFile':
        // ignore: discarded_futures
        return dummy.decryptFile(argument);
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

class NativeImplementationsDummy extends NativeImplementations {
  const NativeImplementationsDummy();

  @override
  MatrixImageFileResizedResponse? shrinkImage(
    MatrixImageFileResizeArguments args, {
    bool retryInDummy = false,
  }) =>
      MatrixImageFile.resizeImplementation(args);

  @override
  MatrixImageFileResizedResponse? calcImageMetadata(
    Uint8List bytes, {
    bool retryInDummy = false,
  }) =>
      MatrixImageFile.calcMetadataImplementation(bytes);

  @override
  Future<RoomKeys> generateUploadKeys(
    GenerateUploadKeysArgs args, {
    bool retryInDummy = true,
  }) async =>
      generateUploadKeysImplementation(args);

  @override
  Future<Uint8List> keyFromPassphrase(
    KeyFromPassphraseArgs args, {
    bool retryInDummy = true,
  }) =>
      generateKeyFromPassphrase(args);

  @override
  Future<EncryptedFile> encryptFile(
    File file, {
    bool retryInDummy = true,
    CancellationToken? cancellationToken,
  }) =>
      crypto_utils.encryptFile(file);

  @override
  Future<File> decryptFile(
    EncryptedFile encryptedFile, {
    bool retryInDummy = true,
    CancellationToken? cancellationToken,
  }) =>
      crypto_utils.decryptFile(encryptedFile);
}

// ─────────────────────────────────────────────────────────────────────────────
// 持久 Isolate：vodozemac 只初始化一次，所有操作复用同一 isolate 通道。
// ─────────────────────────────────────────────────────────────────────────────

class _NativeRequest {
  final int id;
  final String method;
  final Object? arg;
  final SendPort replyPort;
  const _NativeRequest(this.id, this.method, this.arg, this.replyPort);
}

/// Worker 收到此消息后，若对应 id 的请求尚未开始执行则跳过。
class _CancelRequest {
  final int id;
  const _CancelRequest(this.id);
}

/// isolate 返回给调用方的回复记录。
/// [stackTrace] 仅在 [error] 非空时有值，用于还原 isolate 内部栈轨迹。
typedef _NativeReply = ({Object? result, Object? error, StackTrace? stackTrace});

class _NativeIsolateInitArgs {
  final SendPort readyPort;
  final Future<void> Function()? vodozemacInit;
  const _NativeIsolateInitArgs(this.readyPort, this.vodozemacInit);
}

/// isolate 意外死亡时向所有等待中的调用方抛出此错误。
class IsolateDeadError extends Error {
  @override
  String toString() => 'IsolateDeadError: matrix_crypto_worker 已意外终止';
}

Future<void> _persistentIsolateMain(_NativeIsolateInitArgs args) async {
  // 若 vodozemacInit 抛出，向 readyPort 发送错误字符串，
  // 让主 isolate 能立即感知失败，而非在 readyPort.first 上永久挂起。
  try {
    await args.vodozemacInit?.call();
  } catch (e) {
    args.readyPort.send(e.toString());
    return;
  }

  final receivePort = ReceivePort();
  // 发送 SendPort 表示初始化成功。
  args.readyPort.send(receivePort.sendPort);

  const dummy = NativeImplementations.dummy;

  // 收集已取消的请求 id；在实际执行前检查，跳过已取消的任务。
  final cancelledIds = <int>{};

  await for (final message in receivePort) {
    if (message is _CancelRequest) {
      cancelledIds.add(message.id);
      continue;
    }
    if (message is! _NativeRequest) continue;

    // 执行前检查取消标志：已取消则直接回复 DownloadCancelledException，不执行加解密。
    if (cancelledIds.remove(message.id)) {
      message.replyPort.send(
        (
          result: null,
          error: const DownloadCancelledException(),
          stackTrace: StackTrace.empty,
        ) as _NativeReply,
      );
      continue;
    }

    try {
      final result = await Future.value(switch (message.method) {
        'encryptFile' => dummy.encryptFile(message.arg as File),
        'decryptFile' => dummy.decryptFile(message.arg as EncryptedFile),
        'generateUploadKeys' =>
          dummy.generateUploadKeys(message.arg as GenerateUploadKeysArgs),
        'keyFromPassphrase' =>
          dummy.keyFromPassphrase(message.arg as KeyFromPassphraseArgs),
        'shrinkImage' => Future.value(
            dummy.shrinkImage(message.arg as MatrixImageFileResizeArguments),
          ),
        'calcImageMetadata' => Future.value(
            dummy.calcImageMetadata(message.arg as Uint8List),
          ),
        _ => throw UnsupportedError('Unknown method: ${message.method}'),
      },);
      // 每次回复都携带 stackTrace 字段，便于调用方还原错误现场。
      message.replyPort.send(
        (result: result, error: null, stackTrace: null) as _NativeReply,
      );
    } catch (e, s) {
      message.replyPort.send(
        (result: null, error: e, stackTrace: s) as _NativeReply,
      );
    }
  }
}

/// 基于单一长期存活 isolate 的 [NativeImplementations]。
///
/// vodozemac 只初始化一次，后续调用均复用同一 isolate 通道，
/// 避免每次调用都要重新启动 Rust 库的开销。
///
/// **生命周期感知**：通过 `onExit`/`onError` 端口监听 isolate 意外死亡，
/// 而非依赖调用超时。这样可以：
/// - 立即通知所有等待中的调用方（[IsolateDeadError]），无需等待任何超时
/// - 不限制合法的大文件加解密时间（可能超过任何固定超时值）
/// - 自动将内部状态重置为可重试状态
///
/// [spawnTimeout]：isolate 启动的最长等待时间（默认 30 秒）。
class NativeImplementationsPersistentIsolate extends NativeImplementations {
  final Future<void> Function()? vodozemacInit;
  final Duration _spawnTimeout;

  NativeImplementationsPersistentIsolate({
    this.vodozemacInit,
    Duration spawnTimeout = const Duration(seconds: 30),
  }) : _spawnTimeout = spawnTimeout;

  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _initFuture;

  // generation 计数器用于检测 dispose() 与 _spawnIsolate() 的竞态。
  // dispose() 会递增此值，_spawnIsolate() 完成后比对，若不一致则抛弃新 isolate。
  int _generation = 0;

  // 自增请求 id，用于将取消消息与对应请求匹配。
  int _requestIdCounter = 0;

  // 所有等待中的请求。isolate 死亡时统一向这些 completer 投递 IsolateDeadError。
  final List<Completer<Object?>> _pendingCompleters = [];

  @visibleForTesting
  SendPort? get sendPort => _sendPort;

  /// 强制启动 isolate（若尚未启动），供测试验证 isolate 已就绪。
  @visibleForTesting
  Future<void> ensureStartedForTest() => _ensureStarted().then((_) {});

  /// 暴露 _initFuture 内部状态，供测试验证失败后是否被正确重置为 null。
  @visibleForTesting
  Future<void>? get initFutureForTest => _initFuture;

  Future<SendPort> _ensureStarted() async {
    if (_sendPort != null) return _sendPort!;
    _initFuture ??= _spawnIsolate();
    // spawn 失败时重置 _initFuture，确保下次调用能重新尝试启动。
    try {
      await _initFuture;
    } catch (_) {
      _initFuture = null;
      rethrow;
    }
    return _sendPort!;
  }

  Future<void> _spawnIsolate() async {
    // 记录当前 generation，spawn 完成后核验，检测 dispose() 竞态。
    final generation = _generation;
    final readyPort = ReceivePort();

    // onExitPort：isolate 正常或异常退出时发送一条消息（null）。
    // onErrorPort：isolate 未捕获异常时发送 [errorDescription, stackTrace]。
    // 两者都用于驱动 _onIsolateDead()，通知所有等待中的调用方。
    final onExitPort = ReceivePort();
    final onErrorPort = ReceivePort();

    final isolate = await Isolate.spawn(
      _persistentIsolateMain,
      _NativeIsolateInitArgs(readyPort.sendPort, vodozemacInit),
      debugName: 'matrix_crypto_worker',
      onExit: onExitPort.sendPort,
      onError: onErrorPort.sendPort,
      // errorsAreFatal=false：让 onError 端口接收错误，而非终止整个程序。
      errorsAreFatal: false,
    );

    // 监听 onExit：正常退出（包括被 kill）时重置状态并通知等待者。
    onExitPort.listen((_) {
      onExitPort.close();
      onErrorPort.close();
      _onIsolateDead();
    });

    // 监听 onError：isolate 内未捕获异常（不含正常操作错误，那些通过 replyPort 返回）。
    onErrorPort.listen((_) {
      onExitPort.close();
      onErrorPort.close();
      _onIsolateDead();
    });

    // 等待 isolate 就绪信号；加 spawnTimeout 防止 isolate 崩溃前未发信号时的无限挂起。
    final Object? response;
    try {
      response = await readyPort.first.timeout(_spawnTimeout);
    } on TimeoutException {
      readyPort.close();
      onExitPort.close();
      onErrorPort.close();
      isolate.kill(priority: Isolate.immediate);
      throw TimeoutException(
        'matrix_crypto_worker 未能在 $_spawnTimeout 内完成启动',
        _spawnTimeout,
      );
    }
    readyPort.close();

    // 若在等待期间 dispose() 已被调用，则放弃此 isolate。
    if (_generation != generation) {
      onExitPort.close();
      onErrorPort.close();
      isolate.kill(priority: Isolate.beforeNextEvent);
      throw StateError('NativeImplementationsPersistentIsolate 在 spawn 期间被 dispose');
    }

    if (response is! SendPort) {
      // vodozemacInit 抛出异常并发回了错误字符串。
      onExitPort.close();
      onErrorPort.close();
      isolate.kill(priority: Isolate.immediate);
      throw Exception(
        'NativeImplementationsPersistentIsolate: vodozemacInit 失败：$response',
      );
    }

    _isolate = isolate;
    _sendPort = response;
  }

  /// isolate 意外死亡时的处理：重置状态，并通知所有等待中的调用方。
  void _onIsolateDead() {
    // 仅在 isolate 确实是当前活跃实例时重置（防止 dispose 后的残留通知）。
    if (_isolate == null) return;
    _isolate = null;
    _sendPort = null;
    _initFuture = null;

    // 通知所有等待中的请求，让它们立即失败而非永久挂起。
    final error = IsolateDeadError();
    final completers = List<Completer<Object?>>.from(_pendingCompleters);
    _pendingCompleters.clear();
    for (final c in completers) {
      if (!c.isCompleted) c.completeError(error, StackTrace.current);
    }
  }

  /// 通过 isolate 通道发起一次调用，等待回复。
  /// 调用方不限时；isolate 死亡时通过 [IsolateDeadError] 立即通知。
  /// [cancellationToken] 触发时立即向 isolate 发送取消消息，
  /// isolate 在两次操作间隙检测到取消后跳过执行并回复 [DownloadCancelledException]。
  Future<T> _call<T>(
    String method,
    Object? arg, {
    bool retryInDummy = false,
    CancellationToken? cancellationToken,
  }) async {
    // 调用前已取消，直接抛出，无需发消息给 isolate。
    cancellationToken?.throwIfCancelled();

    try {
      final sendPort = await _ensureStarted();
      final replyPort = ReceivePort();

      final id = ++_requestIdCounter;

      // 注册到等待列表，以便 isolate 死亡时能立即收到通知。
      final completer = Completer<Object?>();
      _pendingCompleters.add(completer);

      sendPort.send(_NativeRequest(id, method, arg, replyPort.sendPort));

      // 监听取消信号：token 触发时向 isolate 发送 _CancelRequest，
      // 同时在调用方侧立即完成 completer，让 Future 提前结束。
      if (cancellationToken != null) {
        cancellationToken.whenCancelled.then((_) {
          sendPort.send(_CancelRequest(id));
          _pendingCompleters.remove(completer);
          if (!completer.isCompleted) {
            completer.completeError(const DownloadCancelledException());
          }
        });
      }

      // replyPort 和 completer 竞争：先到先得。
      // - 正常情况：isolate 通过 replyPort 发回结果，completer 未被使用
      // - isolate 死亡：_onIsolateDead() 完成 completer，replyPort 关闭后无人发送
      // - 取消：上方 whenCancelled 回调完成 completer
      replyPort.listen(
        (msg) {
          replyPort.close();
          _pendingCompleters.remove(completer);
          if (!completer.isCompleted) completer.complete(msg);
        },
        onDone: () {
          // replyPort 被外部关闭（如 dispose）时确保 completer 得到处理。
          _pendingCompleters.remove(completer);
          if (!completer.isCompleted) {
            completer.completeError(IsolateDeadError(), StackTrace.current);
          }
        },
      );

      final raw = await completer.future;

      // 使用 Error.throwWithStackTrace 还原 isolate 内的原始栈轨迹。
      final reply = raw as _NativeReply;
      if (reply.error != null) {
        Error.throwWithStackTrace(
          reply.error!,
          reply.stackTrace ?? StackTrace.empty,
        );
      }
      return reply.result as T;
    } catch (e) {
      // DownloadCancelledException 不应降级到 dummy，直接向上传播。
      if (e is DownloadCancelledException) rethrow;
      // retryInDummy=true 时降级到进程内 dummy 实现，而非向上抛出。
      if (retryInDummy) {
        return await Future.sync(() => _callDummy<T>(method, arg));
      }
      rethrow;
    }
  }

  /// 在进程内直接调用 dummy 实现（不经过 isolate）。
  FutureOr<T> _callDummy<T>(String method, Object? arg) {
    const d = NativeImplementations.dummy;
    return switch (method) {
      'encryptFile' => d.encryptFile(arg as File) as FutureOr<T>,
      'decryptFile' => d.decryptFile(arg as EncryptedFile) as FutureOr<T>,
      'generateUploadKeys' =>
        d.generateUploadKeys(arg as GenerateUploadKeysArgs) as FutureOr<T>,
      'keyFromPassphrase' =>
        d.keyFromPassphrase(arg as KeyFromPassphraseArgs) as FutureOr<T>,
      'shrinkImage' =>
        d.shrinkImage(arg as MatrixImageFileResizeArguments) as FutureOr<T>,
      'calcImageMetadata' =>
        d.calcImageMetadata(arg as Uint8List) as FutureOr<T>,
      _ => throw UnsupportedError('Unknown method: $method'),
    };
  }

  /// 释放持久 isolate。通常不需要手动调用——进程退出时会自动清理。
  void dispose() {
    // 先递增 generation，使任何正在执行的 _spawnIsolate() 感知到 dispose。
    _generation++;
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _sendPort = null;
    _initFuture = null;

    // 清空等待中的请求，防止内存泄漏。
    final completers = List<Completer<Object?>>.from(_pendingCompleters);
    _pendingCompleters.clear();
    final error = IsolateDeadError();
    for (final c in completers) {
      if (!c.isCompleted) c.completeError(error, StackTrace.current);
    }
  }

  /// 仅 kill 底层 isolate 而不清理状态，模拟 OOM 等系统级意外终止。仅供测试使用。
  @visibleForTesting
  void killIsolateForTest() {
    _isolate?.kill(priority: Isolate.immediate);
  }

  @override
  Future<EncryptedFile> encryptFile(
    File file, {
    bool retryInDummy = true,
    CancellationToken? cancellationToken,
  }) =>
      _call('encryptFile', file, retryInDummy: retryInDummy, cancellationToken: cancellationToken);

  @override
  Future<File> decryptFile(
    EncryptedFile encryptedFile, {
    bool retryInDummy = true,
    CancellationToken? cancellationToken,
  }) =>
      _call('decryptFile', encryptedFile, retryInDummy: retryInDummy, cancellationToken: cancellationToken);

  @override
  Future<RoomKeys> generateUploadKeys(
    GenerateUploadKeysArgs args, {
    bool retryInDummy = true,
  }) =>
      _call('generateUploadKeys', args, retryInDummy: retryInDummy);

  @override
  Future<Uint8List> keyFromPassphrase(
    KeyFromPassphraseArgs args, {
    bool retryInDummy = true,
  }) =>
      _call('keyFromPassphrase', args, retryInDummy: retryInDummy);

  @override
  Future<MatrixImageFileResizedResponse?> shrinkImage(
    MatrixImageFileResizeArguments args, {
    bool retryInDummy = false,
  }) =>
      _call('shrinkImage', args, retryInDummy: retryInDummy);

  @override
  Future<MatrixImageFileResizedResponse?> calcImageMetadata(
    Uint8List bytes, {
    bool retryInDummy = false,
  }) =>
      _call('calcImageMetadata', bytes, retryInDummy: retryInDummy);
}

/// 基于 Flutter `compute` 的 [NativeImplementations]。
///
/// 每次调用都会启动一个全新的临时 isolate 并重新执行 [vodozemacInit]。
/// 适合低频操作；高频解密场景建议改用 [NativeImplementationsPersistentIsolate]。
class NativeImplementationsIsolate extends NativeImplementations {
  final ComputeCallback compute;
  final Future<void> Function()? vodozemacInit;

  NativeImplementationsIsolate(
    this.compute, {
    this.vodozemacInit,
  });

  Future<T> _run<T, U>(FutureOr<T> Function(U) fn, U arg) =>
      compute(fn, arg);

  @override
  Future<EncryptedFile> encryptFile(
    File file, {
    bool retryInDummy = true,
    CancellationToken? cancellationToken,
  }) =>
      _run(
        (File f) async {
          await vodozemacInit?.call();
          return NativeImplementations.dummy.encryptFile(f);
        },
        file,
      );

  @override
  Future<File> decryptFile(
    EncryptedFile encryptedFile, {
    bool retryInDummy = true,
    CancellationToken? cancellationToken,
  }) =>
      _run(
        (EncryptedFile ef) async {
          await vodozemacInit?.call();
          return NativeImplementations.dummy.decryptFile(ef);
        },
        encryptedFile,
      );

  @override
  Future<RoomKeys> generateUploadKeys(
    GenerateUploadKeysArgs args, {
    bool retryInDummy = true,
  }) =>
      _run(
        (GenerateUploadKeysArgs a) async {
          await vodozemacInit?.call();
          return NativeImplementations.dummy.generateUploadKeys(a);
        },
        args,
      );

  @override
  Future<Uint8List> keyFromPassphrase(
    KeyFromPassphraseArgs args, {
    bool retryInDummy = true,
  }) =>
      _run(
        (KeyFromPassphraseArgs a) async {
          await vodozemacInit?.call();
          return NativeImplementations.dummy.keyFromPassphrase(a);
        },
        args,
      );

  @override
  Future<MatrixImageFileResizedResponse?> shrinkImage(
    MatrixImageFileResizeArguments args, {
    bool retryInDummy = false,
  }) =>
      _run(NativeImplementations.dummy.shrinkImage, args);

  @override
  FutureOr<MatrixImageFileResizedResponse?> calcImageMetadata(
    Uint8List bytes, {
    bool retryInDummy = false,
  }) =>
      _run(NativeImplementations.dummy.calcImageMetadata, bytes);
}
