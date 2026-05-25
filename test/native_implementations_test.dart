/// native_implementations_test.dart
///
/// 分两组：
///   1. 无需 vodozemac 的 isolate 生命周期测试（无 olm 标签）
///   2. 需要 vodozemac 的加密 round-trip 测试（olm 标签）
library;

import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';

import 'package:matrix/matrix.dart' show CancellationToken, DownloadCancelledException;
import 'package:matrix/src/utils/crypto/encrypted_file.dart' as crypto_utils;
import 'package:matrix/src/utils/native_implementations.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：暴露内部状态的可测试子类
// ─────────────────────────────────────────────────────────────────────────────

class _TestableIsolate extends NativeImplementationsPersistentIsolate {
  _TestableIsolate({super.vodozemacInit, super.spawnTimeout});

  bool get hasActiveSendPort => sendPort != null;
}

// ─────────────────────────────────────────────────────────────────────────────
// 顶层函数：可安全地跨 isolate 传递（无闭包捕获）
// ─────────────────────────────────────────────────────────────────────────────

/// 始终抛出，用于测试 vodozemacInit 失败时的恢复行为。
Future<void> _alwaysFailInit() async {
  throw Exception('test: vodozemacInit 故意失败');
}


// ─────────────────────────────────────────────────────────────────────────────
// isolate 生命周期测试（无 olm 标签，不需要 vodozemac）
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('NativeImplementationsPersistentIsolate 生命周期', () {
    // isolate 被 kill 后调用应立即感知（通过 onExit 端口），而非等待超时
    test('isolate 被 kill 后调用立即抛出 IsolateDeadError，无需等待超时', () async {
      final impl = _TestableIsolate(spawnTimeout: const Duration(seconds: 5));
      addTearDown(impl.dispose);

      await impl.ensureStartedForTest();
      expect(
        impl.hasActiveSendPort,
        isTrue,
        reason: 'ensureStartedForTest 后 sendPort 应已就绪',
      );

      impl.killIsolateForTest();

      // 应立即（远快于任何超时）抛出表示 isolate 已死的错误，而非 TimeoutException
      final stopwatch = Stopwatch()..start();
      Object? thrown;
      try {
        await impl.encryptFile(File('/dev/null'), retryInDummy: false);
      } catch (e) {
        thrown = e;
      }
      stopwatch.stop();

      expect(thrown, isNotNull, reason: '应抛出错误');
      expect(thrown, isA<IsolateDeadError>(), reason: '应抛出 IsolateDeadError 而非 TimeoutException');
      // 应在 1 秒内感知到 isolate 死亡（onExit 通知），远比 30s 超时快
      expect(
        stopwatch.elapsed.inMilliseconds,
        lessThan(1000),
        reason: '通过 onExit 端口应在 1 秒内感知到 isolate 死亡',
      );
    });

    // isolate 死亡后所有等待中的请求应同时收到错误，不泄漏 ReceivePort
    test('isolate 死亡时所有并发等待请求均收到 IsolateDeadError', () async {
      final impl = _TestableIsolate(spawnTimeout: const Duration(seconds: 5));
      addTearDown(impl.dispose);

      await impl.ensureStartedForTest();

      // 发起 3 个并发请求（均不降级到 dummy）
      final futures = List.generate(
        3,
        (_) => impl
            .decryptFile(
              crypto_utils.EncryptedFile(
                path: '/no_such_file_${DateTime.now().microsecondsSinceEpoch}.enc',
                k: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                iv: 'AAAAAAAAAAAAAAAA',
                sha256: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
              ),
              retryInDummy: false,
            )
            .then<Object?>((v) => v)
            .catchError((e) => e),
      );

      // kill isolate，此时 3 个请求都在等待
      impl.killIsolateForTest();

      final results = await Future.wait(futures);
      for (final r in results) {
        expect(
          r,
          isA<IsolateDeadError>(),
          reason: '所有并发请求都应收到 IsolateDeadError',
        );
      }
    });

    // isolate 死亡后应自动重启，下次调用可以成功（而非状态卡死）
    test('isolate 死亡后对象自动重置，下次调用重新启动 isolate', () async {
      final impl = _TestableIsolate(spawnTimeout: const Duration(seconds: 5));
      addTearDown(impl.dispose);

      await impl.ensureStartedForTest();
      final firstSendPort = impl.sendPort;

      impl.killIsolateForTest();

      // 等待 onExit 通知被处理（状态被重置）
      await Future.delayed(const Duration(milliseconds: 200));

      // 再次 ensureStarted 应重新 spawn
      await impl.ensureStartedForTest();
      expect(impl.hasActiveSendPort, isTrue, reason: '重启后应有新的 sendPort');
      expect(
        impl.sendPort,
        isNot(equals(firstSendPort)),
        reason: '重启后 sendPort 应是新实例',
      );
    });

    // Bug #2：dispose/spawn 竞态 — dispose 后 sendPort 必须被清理
    test('dispose 后 sendPort 被清理，对象处于安全状态', () async {
      final impl = _TestableIsolate(spawnTimeout: const Duration(seconds: 5));

      // 触发 spawn 但不 await（制造竞态窗口）
      final spawnFuture = impl.ensureStartedForTest().catchError((_) {});

      // 立即 dispose
      impl.dispose();

      await spawnFuture;

      expect(
        impl.hasActiveSendPort,
        isFalse,
        reason: 'dispose 后 sendPort 必须被清除',
      );
    });

    // Bug #4：_initFuture 失败后无法恢复
    test('vodozemacInit 失败后 _initFuture 被重置为 null，允许重新尝试', () async {
      final impl = _TestableIsolate(
        vodozemacInit: _alwaysFailInit,
        spawnTimeout: const Duration(seconds: 5),
      );
      addTearDown(impl.dispose);

      Object? firstError;
      try {
        await impl.ensureStartedForTest();
      } catch (e) {
        firstError = e;
      }
      expect(firstError, isNotNull, reason: 'vodozemacInit 始终失败，应抛出错误');

      expect(
        impl.initFutureForTest,
        isNull,
        reason: 'spawn 失败后 _initFuture 应被重置为 null，否则后续调用永远无法重试',
      );
    });

    // Bug #3：错误携带 stack trace
    test('isolate 内的错误携带非空 stack trace', () async {
      final impl = _TestableIsolate(spawnTimeout: const Duration(seconds: 5));
      addTearDown(impl.dispose);

      final missing = crypto_utils.EncryptedFile(
        path:
            '/no_such_matrix_sdk_test_${DateTime.now().microsecondsSinceEpoch}.enc',
        k: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        iv: 'AAAAAAAAAAAAAAAA',
        sha256: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );

      StackTrace? captured;
      try {
        await impl.decryptFile(missing, retryInDummy: false);
      } catch (_, s) {
        captured = s;
      }

      expect(captured, isNotNull, reason: '缺失文件时应抛出异常');
      expect(
        captured.toString(),
        isNot(equals(StackTrace.empty.toString())),
        reason: '来自 isolate 的 stack trace 不应为空',
      );
    });

    // Bug #5：retryInDummy — isolate 死亡时降级到 dummy，不抛出 IsolateDeadError
    test('retryInDummy=true 时 isolate 死亡后降级到 dummy', () async {
      final impl = _TestableIsolate(spawnTimeout: const Duration(seconds: 5));
      addTearDown(impl.dispose);

      await impl.ensureStartedForTest();
      impl.killIsolateForTest();

      // 等待 onExit 通知处理
      await Future.delayed(const Duration(milliseconds: 200));

      Object? thrown;
      try {
        await impl.encryptFile(File('/dev/null'), retryInDummy: true);
      } catch (e) {
        thrown = e;
      }

      // 不应是 IsolateDeadError（已被 retryInDummy 捕获并降级到 dummy）
      if (thrown != null) {
        expect(
          thrown,
          isNot(isA<IsolateDeadError>()),
          reason: 'retryInDummy=true 时不应向上抛出 IsolateDeadError',
        );
      }
    });

    // 取消：取消 token 发出后，排队中的请求应抛出 DownloadCancelledException
    test('取消 token 已触发时排队请求抛出 DownloadCancelledException', () async {
      final impl = _TestableIsolate(spawnTimeout: const Duration(seconds: 5));
      addTearDown(impl.dispose);

      await impl.ensureStartedForTest();

      // 构造一个不存在的加密文件（isolate 会立即报错），但取消先于 isolate 处理
      final missingFile = crypto_utils.EncryptedFile(
        path: '/no_such_file_cancel_test_${DateTime.now().microsecondsSinceEpoch}.enc',
        k: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        iv: 'AAAAAAAAAAAAAAAA',
        sha256: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );

      final token = CancellationToken();
      // 取消先于请求发出
      token.cancel();

      Object? thrown;
      try {
        await impl.decryptFile(missingFile, cancellationToken: token, retryInDummy: false);
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<DownloadCancelledException>(), reason: '已取消的 token 应立即抛出 DownloadCancelledException');
    });

    // 取消：正在排队中途取消，应跳过该请求
    test('请求进入队列后取消 token，isolate 跳过执行并抛出 DownloadCancelledException', () async {
      final impl = _TestableIsolate(spawnTimeout: const Duration(seconds: 5));
      addTearDown(impl.dispose);

      await impl.ensureStartedForTest();

      // 用一个会实际执行的文件（/dev/null）构造第一个"占坑"请求，让 isolate 忙碌
      final occupyToken = CancellationToken();
      final occupyFuture = impl.encryptFile(
        File('/dev/null'),
        cancellationToken: occupyToken,
        retryInDummy: false,
      ).catchError((_) => crypto_utils.EncryptedFile(path: '', k: '', iv: '', sha256: ''));

      // 第二个请求：先入队，稍后取消
      final cancelToken = CancellationToken();
      final missingFile = crypto_utils.EncryptedFile(
        path: '/no_such_file_queue_cancel_${DateTime.now().microsecondsSinceEpoch}.enc',
        k: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        iv: 'AAAAAAAAAAAAAAAA',
        sha256: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );
      final cancelFuture = impl.decryptFile(
        missingFile,
        cancellationToken: cancelToken,
        retryInDummy: false,
      );

      // 在第二个请求被 isolate 取出前取消
      cancelToken.cancel();

      Object? thrown;
      try {
        await cancelFuture;
      } catch (e) {
        thrown = e;
      }

      await occupyFuture;

      expect(
        thrown,
        isA<DownloadCancelledException>(),
        reason: '排队中的请求被取消后应抛出 DownloadCancelledException',
      );
    });

    test('CancellationToken whenCancelled 连续/并发获取不会抛出 Completer StateError', () async {
      final token = CancellationToken();
      token.cancel();

      // 连续/并发获取多次 whenCancelled 都不应该触发 StateError
      await expectLater(token.whenCancelled, completes);
      await expectLater(token.whenCancelled, completes);
    });
  }); // end group 生命周期

  // ─────────────────────────────────────────────────────────────────────────
  // 加密 round-trip 测试（需要 vodozemac，打 olm 标签）
  // ─────────────────────────────────────────────────────────────────────────
  group('NativeImplementationsPersistentIsolate 加密 round-trip', tags: 'olm', () {
    late _TestableIsolate impl;

    setUp(() {
      impl = _TestableIsolate(spawnTimeout: const Duration(seconds: 30));
    });
    tearDown(() => impl.dispose());

    test('encrypt + decrypt 内容完整还原', () async {
      const text = '持久 isolate 加密测试内容';
      final tmp = File(
        '${Directory.systemTemp.path}/ni_test_${DateTime.now().microsecondsSinceEpoch}.txt',
      );
      await tmp.writeAsString(text);
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete();
      });

      final encrypted = await impl.encryptFile(tmp);
      addTearDown(() async {
        final f = File(encrypted.path);
        if (await f.exists()) await f.delete();
      });

      final decrypted = await impl.decryptFile(encrypted);
      addTearDown(() async {
        if (await decrypted.exists()) await decrypted.delete();
      });

      expect(await decrypted.readAsString(), text);
    });
  });
}
