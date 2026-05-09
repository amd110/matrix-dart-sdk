import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/compute_callback.dart';
import 'package:matrix/src/utils/crypto/encrypted_file.dart' as crypto_utils;

/// Provides native implementations for demanding arithmetic operations
/// in order to prevent the UI from blocking.
///
/// Possible implementations:
/// - [NativeImplementationsDummy]: inline, blocks UI
/// - [NativeImplementationsIsolate]: Flutter `compute`-based, ephemeral isolate
/// - [NativeImplementationsPersistentIsolate]: single long-lived isolate
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

  /// Encrypts [file] to a temporary file and returns metadata.
  FutureOr<EncryptedFile> encryptFile(
    File file, {
    bool retryInDummy = true,
  });

  /// Decrypts [encryptedFile] to a temporary file and returns it.
  FutureOr<File> decryptFile(
    EncryptedFile encryptedFile, {
    bool retryInDummy = true,
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
  }) =>
      crypto_utils.encryptFile(file);

  @override
  Future<File> decryptFile(
    EncryptedFile encryptedFile, {
    bool retryInDummy = true,
  }) =>
      crypto_utils.decryptFile(encryptedFile);
}

// ─────────────────────────────────────────────────────────────────────────────
// Persistent Isolate: vodozemac is initialised once and all operations reuse
// the same isolate.
// ─────────────────────────────────────────────────────────────────────────────

class _NativeRequest {
  final String method;
  final Object? arg;
  final SendPort replyPort;
  const _NativeRequest(this.method, this.arg, this.replyPort);
}

class _NativeIsolateInitArgs {
  final SendPort readyPort;
  final Future<void> Function()? vodozemacInit;
  const _NativeIsolateInitArgs(this.readyPort, this.vodozemacInit);
}

Future<void> _persistentIsolateMain(_NativeIsolateInitArgs args) async {
  await args.vodozemacInit?.call();

  final receivePort = ReceivePort();
  args.readyPort.send(receivePort.sendPort);

  const dummy = NativeImplementations.dummy;

  await for (final message in receivePort) {
    if (message is! _NativeRequest) continue;
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
      message.replyPort.send((result: result, error: null));
    } catch (e) {
      message.replyPort.send((result: null, error: e));
    }
  }
}

/// [NativeImplementations] backed by a single long-lived isolate.
///
/// vodozemac is initialised only once; all subsequent calls reuse the same
/// isolate channel, avoiding the per-call Rust library bootstrap cost.
class NativeImplementationsPersistentIsolate extends NativeImplementations {
  final Future<void> Function()? vodozemacInit;

  NativeImplementationsPersistentIsolate({this.vodozemacInit});

  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _initFuture;

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

  /// Releases the persistent isolate. Usually not needed — the process exit
  /// handles cleanup automatically.
  void dispose() {
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _sendPort = null;
    _initFuture = null;
  }

  @override
  Future<EncryptedFile> encryptFile(
    File file, {
    bool retryInDummy = true,
  }) =>
      _call('encryptFile', file);

  @override
  Future<File> decryptFile(
    EncryptedFile encryptedFile, {
    bool retryInDummy = true,
  }) =>
      _call('decryptFile', encryptedFile);

  @override
  Future<RoomKeys> generateUploadKeys(
    GenerateUploadKeysArgs args, {
    bool retryInDummy = true,
  }) =>
      _call('generateUploadKeys', args);

  @override
  Future<Uint8List> keyFromPassphrase(
    KeyFromPassphraseArgs args, {
    bool retryInDummy = true,
  }) =>
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

/// [NativeImplementations] backed by Flutter's `compute` function.
///
/// Each call spawns a fresh ephemeral isolate and re-runs [vodozemacInit].
/// Suitable for infrequent operations; for frequent decryption prefer
/// [NativeImplementationsPersistentIsolate].
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
