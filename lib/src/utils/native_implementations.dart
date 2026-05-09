import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/compute_callback.dart';
import 'package:matrix/src/utils/crypto/encrypted_file.dart' as crypto_utils;

/// provides native implementations for demanding arithmetic operations
/// in order to prevent the UI from blocking
///
/// possible implementations might be:
/// - native code
/// - another Dart isolate
/// - a web worker
/// - a dummy implementations
///
/// Rules for extension (important for [noSuchMethod] implementations)
/// - always only accept exactly *one* positioned argument
/// - catch the corresponding case in [NativeImplementations.noSuchMethod]
/// - always write a dummy implementations
abstract class NativeImplementations {
  const NativeImplementations();

  /// a dummy implementation executing all calls in the same thread causing
  /// the UI to likely freeze
  static const dummy = NativeImplementationsDummy();

  FutureOr<RoomKeys> generateUploadKeys(
    GenerateUploadKeysArgs args, {
    bool retryInDummy = true,
  });

  FutureOr<Uint8List> keyFromPassphrase(
    KeyFromPassphraseArgs args, {
    bool retryInDummy = true,
  });

  FutureOr<Uint8List?> decryptFile(
    EncryptedFile file, {
    bool retryInDummy = true,
  });

  FutureOr<Stream<List<int>>> decryptFileStream(
    EncryptedFile file, {
    String? path,
    bool retryInDummy = true,
  });

  FutureOr<EncryptedFile> encryptFile(
    Uint8List bytes, {
    bool retryInDummy = true,
  });

  FutureOr<EncryptedFile> encryptFileStream(
    Stream<List<int>> stream, {
    int? size,
    String? path,
    bool retryInDummy = true,
  });

  FutureOr<MatrixImageFileResizedResponse?> shrinkImage(
    MatrixImageFileResizeArguments args, {
    bool retryInDummy = false,
  });

  FutureOr<MatrixImageFileResizedResponse?> calcImageMetadata(
    Uint8List bytes, {
    bool retryInDummy = false,
  });

  /// this implementation will catch any non-implemented method
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
      // we need to pass the futures right through or we will run into type errors later!
      case 'generateUploadKeys':
        // ignore: discarded_futures
        return dummy.generateUploadKeys(argument);
      case 'keyFromPassphrase':
        // ignore: discarded_futures
        return dummy.keyFromPassphrase(argument);
      case 'decryptFile':
        // ignore: discarded_futures
        return dummy.decryptFile(argument);
      case 'decryptFileStream':
        // ignore: discarded_futures
        return dummy.decryptFileStream(argument);
      case 'encryptFile':
        // ignore: discarded_futures
        return dummy.encryptFile(argument);
      case 'encryptFileStream':
        // ignore: discarded_futures
        return dummy.encryptFileStream(argument);
      case 'shrinkImage':
        return dummy.shrinkImage(argument);
      case 'calcImageMetadata':
        return dummy.calcImageMetadata(argument);
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

class NativeImplementationsDummy extends NativeImplementations {
  const NativeImplementationsDummy();

  @override
  Future<Uint8List?> decryptFile(
    EncryptedFile file, {
    bool retryInDummy = true,
  }) {
    return decryptFileImplementation(file);
  }

  @override
  Future<Stream<List<int>>> decryptFileStream(
    EncryptedFile file, {
    String? path,
    bool retryInDummy = true,
  }) async {
    final stream = crypto_utils.decryptFileStreamImplementation(file, path: path);
    if (stream == null) throw Exception('Unable to decrypt file stream');
    return stream;
  }

  @override
  FutureOr<EncryptedFile> encryptFile(
    Uint8List bytes, {
    bool retryInDummy = true,
  }) {
    return crypto_utils.encryptFile(bytes);
  }

  @override
  Future<EncryptedFile> encryptFileStream(
    Stream<List<int>> stream, {
    int? size,
    String? path,
    bool retryInDummy = true,
  }) async {
    return crypto_utils.encryptFileStream(stream, path: path);
  }

  @override
  Future<RoomKeys> generateUploadKeys(
    GenerateUploadKeysArgs args, {
    bool retryInDummy = true,
  }) async {
    return generateUploadKeysImplementation(args);
  }

  @override
  Future<Uint8List> keyFromPassphrase(
    KeyFromPassphraseArgs args, {
    bool retryInDummy = true,
  }) {
    return generateKeyFromPassphrase(args);
  }

  @override
  MatrixImageFileResizedResponse? shrinkImage(
    MatrixImageFileResizeArguments args, {
    bool retryInDummy = false,
  }) {
    return MatrixImageFile.resizeImplementation(args);
  }

  @override
  MatrixImageFileResizedResponse? calcImageMetadata(
    Uint8List bytes, {
    bool retryInDummy = false,
  }) {
    return MatrixImageFile.calcMetadataImplementation(bytes);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 持久化 Isolate 实现：vodozemac 只初始化一次，所有操作复用同一个 Isolate
// ─────────────────────────────────────────────────────────────────────────────

/// 持久化 isolate 的请求消息
class _NativeRequest {
  final String method;
  final Object? arg;
  final SendPort replyPort;
  const _NativeRequest(this.method, this.arg, this.replyPort);
}

/// 持久化 isolate 的初始化参数
class _NativeIsolateInitArgs {
  final SendPort readyPort;
  final Future<void> Function()? vodozemacInit;
  const _NativeIsolateInitArgs(this.readyPort, this.vodozemacInit);
}

/// 持久化 isolate 入口：初始化一次 vodozemac，然后进入消息循环处理所有请求
Future<void> _persistentIsolateMain(_NativeIsolateInitArgs args) async {
  await args.vodozemacInit?.call();

  final receivePort = ReceivePort();
  // 通知外部：isolate 已就绪，返回 SendPort
  args.readyPort.send(receivePort.sendPort);

  const dummy = NativeImplementations.dummy;

  await for (final message in receivePort) {
    if (message is! _NativeRequest) continue;
    try {
      final result = switch (message.method) {
        'decryptFile' =>
          await dummy.decryptFile(message.arg as EncryptedFile),
        'encryptFile' =>
          await dummy.encryptFile(message.arg as Uint8List),
        'encryptFileStream' =>
          await dummy.encryptFileStream(Stream.empty(), path: message.arg as String),
        'generateUploadKeys' =>
          await dummy.generateUploadKeys(message.arg as GenerateUploadKeysArgs),
        'keyFromPassphrase' =>
          await dummy.keyFromPassphrase(message.arg as KeyFromPassphraseArgs),
        'shrinkImage' =>
          dummy.shrinkImage(message.arg as MatrixImageFileResizeArguments),
        'calcImageMetadata' =>
          dummy.calcImageMetadata(message.arg as Uint8List),
        _ => throw UnsupportedError('Unknown method: ${message.method}'),
      };
      message.replyPort.send((result: result, error: null));
    } catch (e) {
      message.replyPort.send((result: null, error: e));
    }
  }
}

/// [NativeImplementations] 的持久化 Isolate 实现。
///
/// 与 [NativeImplementationsIsolate]（基于 `compute`，每次调用都启动临时 isolate
/// 并重新执行 vodozemacInit）不同，本实现只创建一个长生命周期的后台 isolate，
/// vodozemac 仅初始化一次，所有后续操作都复用同一个 isolate 通道。
///
/// 适用于需要频繁解密（如消息列表中大量加密图片/视频）的场景，可避免因反复
/// 初始化 Rust 库导致的线程积压和 iOS Watchdog 超时崩溃。
///
/// ```dart
/// final client = Client(
///   'MyApp',
///   nativeImplementations: NativeImplementationsPersistentIsolate(
///     vodozemacInit: () => vod.init(wasmPath: '...'),
///   ),
/// );
/// ```
class NativeImplementationsPersistentIsolate extends NativeImplementations {
  final Future<void> Function()? vodozemacInit;

  NativeImplementationsPersistentIsolate({this.vodozemacInit});

  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _initFuture;

  /// 确保 isolate 已启动，返回可用的 SendPort
  Future<SendPort> _ensureStarted() async {
    if (_sendPort != null) return _sendPort!;
    _initFuture ??= _spawnIsolate();
    await _initFuture;
    return _sendPort!;
  }

  Future<void> _spawnIsolate() async {
    final readyPort = ReceivePort();
    _isolate = await Isolate.spawn(
      _persistentIsolateMain,
      _NativeIsolateInitArgs(readyPort.sendPort, vodozemacInit),
      debugName: 'matrix_crypto_worker',
    );
    _sendPort = await readyPort.first as SendPort;
    readyPort.close();
  }

  Future<T> _call<T>(String method, Object? arg) async {
    final sendPort = await _ensureStarted();
    final replyPort = ReceivePort();
    sendPort.send(_NativeRequest(method, arg, replyPort.sendPort));
    final reply = await replyPort.first as ({Object? result, Object? error});
    replyPort.close();
    if (reply.error != null) throw reply.error!;
    return reply.result as T;
  }

  /// 释放持久化 isolate。通常不需要手动调用，进程退出时会自动清理。
  void dispose() {
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _sendPort = null;
    _initFuture = null;
  }

  @override
  Future<Uint8List?> decryptFile(EncryptedFile file, {bool retryInDummy = true}) =>
      _call('decryptFile', file);

  @override
  Future<Stream<List<int>>> decryptFileStream(EncryptedFile file, {String? path, bool retryInDummy = true}) async {
    return NativeImplementations.dummy.decryptFileStream(file, path: path);
  }

  @override
  Future<EncryptedFile> encryptFile(Uint8List bytes, {bool retryInDummy = true}) =>
      _call('encryptFile', bytes);

  @override
  Future<EncryptedFile> encryptFileStream(Stream<List<int>> stream, {int? size, String? path, bool retryInDummy = true}) async {
    if (path == null) {
      return NativeImplementations.dummy.encryptFileStream(stream, size: size);
    }
    return _call('encryptFileStream', path);
  }

  @override
  Future<RoomKeys> generateUploadKeys(GenerateUploadKeysArgs args, {bool retryInDummy = true}) =>
      _call('generateUploadKeys', args);

  @override
  Future<Uint8List> keyFromPassphrase(KeyFromPassphraseArgs args, {bool retryInDummy = true}) =>
      _call('keyFromPassphrase', args);

  @override
  Future<MatrixImageFileResizedResponse?> shrinkImage(
    MatrixImageFileResizeArguments args, {
    bool retryInDummy = false,
  }) =>
      _call('shrinkImage', args);

  @override
  Future<MatrixImageFileResizedResponse?> calcImageMetadata(
    Uint8List bytes, {
    bool retryInDummy = false,
  }) =>
      _call('calcImageMetadata', bytes);
}

/// a [NativeImplementations] based on Flutter's `compute` function
///
/// this implementations simply wraps the given [compute] function around
/// the implementation of [NativeImplementations.dummy]
class NativeImplementationsIsolate extends NativeImplementations {
  /// pass by Flutter's compute function here
  final ComputeCallback compute;
  final Future<void> Function()? vodozemacInit;

  NativeImplementationsIsolate(
    this.compute, {
    /// To generate upload keys, vodozemac needs to be initialized in the isolate.
    this.vodozemacInit,
  });

  Future<T> runInBackground<T, U>(
    FutureOr<T> Function(U arg) function,
    U arg,
  ) async {
    final compute = this.compute;
    return await compute(function, arg);
  }

  @override
  Future<Uint8List?> decryptFile(
    EncryptedFile file, {
    bool retryInDummy = true,
  }) {
    return runInBackground<Uint8List?, EncryptedFile>(
      (EncryptedFile args) async {
        await vodozemacInit?.call();
        return NativeImplementations.dummy.decryptFile(args);
      },
      file,
    );
  }

  @override
  Future<Stream<List<int>>> decryptFileStream(
    EncryptedFile file, {
    String? path,
    bool retryInDummy = true,
  }) async {
    return NativeImplementations.dummy.decryptFileStream(file, path: path);
  }

  @override
  Future<EncryptedFile> encryptFile(
    Uint8List bytes, {
    bool retryInDummy = true,
  }) {
    return runInBackground<EncryptedFile, Uint8List>(
      (Uint8List args) async {
        await vodozemacInit?.call();
        return NativeImplementations.dummy.encryptFile(args);
      },
      bytes,
    );
  }
@override
Future<EncryptedFile> encryptFileStream(
  Stream<List<int>> stream, {
  int? size,
  String? path,
  bool retryInDummy = true,
}) {
  if (path == null) {
    // If we don't have a path, we cannot send the stream to the isolate.
    // We must run it locally on the main thread.
    return NativeImplementations.dummy.encryptFileStream(stream, size: size);
  }

  // We can safely send the path to the isolate
  return runInBackground<EncryptedFile, String>(
    (String isolatePath) async {
      await vodozemacInit?.call();
      // Run dummy implementation in isolate, ignoring the stream and using the path
      return NativeImplementations.dummy.encryptFileStream(Stream.empty(), path: isolatePath);
    },
    path,
  );
}

  @override
  Future<RoomKeys> generateUploadKeys(
    GenerateUploadKeysArgs args, {
    bool retryInDummy = true,
  }) async {
    return runInBackground<RoomKeys, GenerateUploadKeysArgs>(
      (GenerateUploadKeysArgs args) async {
        await vodozemacInit?.call();
        return NativeImplementations.dummy.generateUploadKeys(args);
      },
      args,
    );
  }

  @override
  Future<Uint8List> keyFromPassphrase(
    KeyFromPassphraseArgs args, {
    bool retryInDummy = true,
  }) {
    return runInBackground<Uint8List, KeyFromPassphraseArgs>(
      (KeyFromPassphraseArgs args) async {
        await vodozemacInit?.call();
        return NativeImplementations.dummy.keyFromPassphrase(args);
      },
      args,
    );
  }

  @override
  Future<MatrixImageFileResizedResponse?> shrinkImage(
    MatrixImageFileResizeArguments args, {
    bool retryInDummy = false,
  }) {
    return runInBackground<MatrixImageFileResizedResponse?,
        MatrixImageFileResizeArguments>(
      NativeImplementations.dummy.shrinkImage,
      args,
    );
  }

  @override
  FutureOr<MatrixImageFileResizedResponse?> calcImageMetadata(
    Uint8List bytes, {
    bool retryInDummy = false,
  }) {
    return runInBackground<MatrixImageFileResizedResponse?, Uint8List>(
      NativeImplementations.dummy.calcImageMetadata,
      bytes,
    );
  }
}
