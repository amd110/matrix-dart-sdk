# 流式下载与解密文件缓存 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 让 `downloadAndDecryptAttachment` 在 IO 平台下载时流式写入临时文件以降低峰值内存，并将解密后的内容缓存到数据库，后续调用可跳过下载和解密。

**Architecture:** 在 `DatabaseFileStorage` IO mixin 中新增 `downloadToMemoryViaStream` 方法，将响应流逐块写入临时文件，读回后删除临时文件；`downloadAndDecryptAttachment` 使用带 `?decrypted=1` 的派生 key 读写已解密内容缓存，加密事件不再写加密原文缓存。

**Tech Stack:** Dart, `dart:io`（`IOSink`、`File`、`Uuid`），`package:http`（`StreamedResponse`），`package:matrix` 内部 `DatabaseFileStorage` mixin，`CancellationToken`。

---

## 文件结构

| 文件 | 变更 |
|------|------|
| `lib/src/database/database_file_storage_io.dart` | 新增 `downloadToMemoryViaStream` 方法 |
| `lib/src/event.dart` | 改造 `downloadAndDecryptAttachment` |
| `test/event_test.dart` | 新增解密缓存测试；更新流式下载路径相关断言 |

---

## Task 1：为 `DatabaseFileStorage` IO mixin 新增 `downloadToMemoryViaStream`

**Files:**
- Modify: `lib/src/database/database_file_storage_io.dart`

- [x] **Step 1：确认现有 mixin 结构**

  阅读 `lib/src/database/database_file_storage_io.dart`，确认 mixin 名称为 `DatabaseFileStorage`，已有字段 `fileStorageLocation`（`Uri?`）和 `supportsFileStoring`（`bool`）。

- [x] **Step 2：新增 `downloadToMemoryViaStream` 方法**

  在 `deleteOldFiles` 方法之前（文件末尾 `}` 之前）插入以下方法：

  ```dart
  Future<Uint8List> downloadToMemoryViaStream(
    Stream<List<int>> stream, {
    void Function(int)? onProgress,
    CancellationToken? cancellationToken,
  }) async {
    final fileStorageLocation = this.fileStorageLocation;
    if (!supportsFileStoring || fileStorageLocation == null) {
      // 降级：内存收集（与 toBytesWithProgress 等效）
      final chunks = <Uint8List>[];
      var received = 0;
      await for (final chunk in stream) {
        cancellationToken?.throwIfCancelled();
        final bytes =
            chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        chunks.add(bytes);
        received += bytes.length;
        onProgress?.call(received);
      }
      if (chunks.isEmpty) return Uint8List(0);
      if (chunks.length == 1) return chunks.first;
      final result = Uint8List(received);
      var offset = 0;
      for (final c in chunks) {
        result.setRange(offset, offset + c.length, c);
        offset += c.length;
      }
      return result;
    }

    final tmpFile = File(
      join(
        Directory.fromUri(fileStorageLocation).path,
        '${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    final sink = tmpFile.openWrite();
    try {
      var received = 0;
      await for (final chunk in stream) {
        if (cancellationToken?.isCancelled == true) {
          await sink.close();
          await tmpFile.delete();
          throw const DownloadCancelledException();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
      }
      await sink.close();
      return await tmpFile.readAsBytes();
    } finally {
      await sink.close().catchError((_) {});
      if (await tmpFile.exists()) await tmpFile.delete();
    }
  }
  ```

  注意：`join` 已从 `package:path/path.dart` 导入（文件顶部已有 `import 'package:path/path.dart';`）。`DownloadCancelledException` 已在 `package:matrix/matrix.dart` 中导出，无需额外导入。

- [x] **Step 3：运行静态分析确认无报错**

  ```bash
  dart analyze lib/src/database/database_file_storage_io.dart
  ```

  期望输出：`No issues found!`

- [x] **Step 4：提交**

  ```bash
  git add lib/src/database/database_file_storage_io.dart
  git commit -m "feat: DatabaseFileStorage 新增 downloadToMemoryViaStream 流式下载方法"
  ```

---

## Task 2：改造 `downloadAndDecryptAttachment` 中的缓存 key 与下载路径

**Files:**
- Modify: `lib/src/event.dart:812-925`

- [x] **Step 1：理解现有代码结构**

  阅读 `lib/src/event.dart` 第 812–925 行，确认：
  - 第 851 行：`uint8list = await room.client.database.getFile(mxcUrl);`（读缓存用 `mxcUrl`）
  - 第 860–871 行：`downloadCallback` 赋值（内置默认回调，用 `toBytesWithProgress`）
  - 第 875–881 行：`storeFile(mxcUrl, uint8list, ...)`（写缓存用 `mxcUrl`）
  - 第 888–913 行：解密逻辑（解密后不写缓存）

- [x] **Step 2：替换 `downloadAndDecryptAttachment` 方法体**

  将 `lib/src/event.dart` 第 823–925 行替换为：

  ```dart
    if (![EventTypes.Message, EventTypes.Sticker].contains(type)) {
      throw ("This event has the type '$type' and so it can't contain an attachment.");
    }
    if (!status.isSent) {
      final localFile = await _getCachedFile(getThumbnail: getThumbnail);
      if (localFile != null) return localFile;
    }
    final database = room.client.database;
    final mxcUrl = attachmentOrThumbnailMxcUrl(getThumbnail: getThumbnail);
    if (mxcUrl == null) {
      throw "This event hasn't any attachment or thumbnail.";
    }
    getThumbnail = mxcUrl != attachmentMxcUrl;
    final isEncrypted =
        getThumbnail ? isThumbnailEncrypted : isAttachmentEncrypted;
    if (isEncrypted && !room.client.encryptionEnabled) {
      throw ('Encryption is not enabled in your Client.');
    }

    // 加密附件使用派生 key 缓存解密内容，避免将加密原文和解密内容混存
    final cacheKey = isEncrypted
        ? mxcUrl.replace(queryParameters: {'decrypted': '1'})
        : mxcUrl;

    // Is this file storeable?
    final thisInfoMap = getThumbnail ? thumbnailInfoMap : infoMap;
    final thisInfoMapSize = thisInfoMap.tryGet<int>('size');
    var storeable =
        thisInfoMapSize != null && thisInfoMapSize <= database.maxFileSize;

    Uint8List? uint8list;
    if (storeable) {
      uint8list = await database.getFile(cacheKey);
    }

    // 下载文件
    final canDownloadFileFromServer = uint8list == null && !fromLocalStoreOnly;
    if (canDownloadFileFromServer) {
      // 下载开始前检查取消标志，避免发起无效请求
      cancellationToken?.throwIfCancelled();
      final httpClient = room.client.httpClient;
      final downloadUri = await mxcUrl.getDownloadUri(room.client);

      if (downloadCallback != null) {
        // 调用方提供了自定义 downloadCallback，保持原有路径不变
        uint8list = await downloadCallback(downloadUri);
      } else if (database.supportsFileStoring) {
        // IO 平台已配置文件存储目录：流式写入临时文件，降低峰值内存
        final request = http.Request('GET', downloadUri);
        request.headers['authorization'] =
            'Bearer ${room.client.accessToken}';
        final response = await httpClient.send(request);
        uint8list =
            await (database as DatabaseFileStorage).downloadToMemoryViaStream(
          response.stream,
          onProgress: onDownloadProgress,
          cancellationToken: cancellationToken,
        );
      } else {
        // Web / 未配置存储目录：内存收集（原有路径）
        final request = http.Request('GET', downloadUri);
        request.headers['authorization'] =
            'Bearer ${room.client.accessToken}';
        final response = await httpClient.send(request);
        uint8list = await response.stream.toBytesWithProgress(
          onDownloadProgress,
          contentLength: response.contentLength,
          cancellationToken: cancellationToken,
        );
      }

      storeable = storeable && uint8list.lengthInBytes <= database.maxFileSize;
      // 仅非加密事件在下载后写缓存；加密事件等解密后再写
      if (storeable && !isEncrypted) {
        await database.storeFile(
          mxcUrl,
          uint8list,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
    } else if (uint8list == null) {
      throw ('Unable to download file from local store.');
    }

    // 解密文件前再次检查取消标志，避免对已取消的任务执行耗时的 AES 解密
    cancellationToken?.throwIfCancelled();
    if (isEncrypted) {
      final fileMap = getThumbnail
          ? infoMap.tryGetMap<String, Object?>('thumbnail_file')
          : content.tryGetMap<String, Object?>('file');
      if (fileMap == null) throw ('No encrypted file info found');
      if (fileMap
              .tryGetMap<String, Object?>('key')
              ?.tryGetList<String>('key_ops')
              ?.contains('decrypt') !=
          true) {
        throw ("Missing 'decrypt' in 'key_ops'.");
      }
      final encryptedFile = EncryptedFile(
        data: uint8list,
        iv: fileMap.tryGet<String>('iv')!,
        k: fileMap.tryGetMap<String, Object?>('key')!.tryGet<String>('k')!,
        sha256: fileMap
            .tryGetMap<String, Object?>('hashes')!
            .tryGet<String>('sha256')!,
      );
      uint8list =
          await room.client.nativeImplementations.decryptFile(encryptedFile);
      if (uint8list == null) {
        throw ('Unable to decrypt file');
      }
      // 将解密后的内容写入缓存，后续调用可跳过下载和解密
      if (storeable) {
        await database.storeFile(
          cacheKey,
          uint8list,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
    }

    final filename = content.tryGet<String>('filename') ?? body;
    final mimeType = attachmentMimetype;

    return MatrixFile(
      bytes: uint8list,
      name: getThumbnail
          ? '$filename.thumbnail.${extensionFromMime(mimeType)}'
          : filename,
      mimeType: attachmentMimetype,
    );
  }
  ```

  同时确认 `lib/src/event.dart` 顶部已有以下导入（若无则添加）：
  ```dart
  import 'package:matrix/src/database/database_file_storage_io.dart'
      if (dart.library.html) 'package:matrix/src/database/database_file_storage_stub.dart';
  ```

  > **注意**：`DatabaseFileStorage` mixin 在 IO 平台由 `database_file_storage_io.dart` 提供，`event.dart` 需要通过 conditional import 引用，或直接用 `as DatabaseFileStorage` 转型（因 `MatrixSdkDatabase` 已混入该 mixin，`database.supportsFileStoring == true` 时转型安全）。

- [x] **Step 3：运行静态分析**

  ```bash
  dart analyze lib/src/event.dart
  ```

  期望输出：`No issues found!`

- [x] **Step 4：提交**

  ```bash
  git add lib/src/event.dart
  git commit -m "feat: downloadAndDecryptAttachment 支持解密内容缓存与 IO 流式下载"
  ```

---

## Task 3：新增解密内容缓存测试

**Files:**
- Modify: `test/event_test.dart`

- [x] **Step 1：定位插入位置**

  在 `test/event_test.dart` 中找到 `test('downloadAndDecryptAttachment store', tags: 'olm'` 测试（约第 2525 行），在其**之后**新增以下测试。

- [x] **Step 2：新增加密附件解密缓存测试**

  在 `downloadAndDecryptAttachment store` 测试后插入：

  ```dart
  test('downloadAndDecryptAttachment caches decrypted content', tags: 'olm',
      () async {
    final FILE_BUFF_ENC = Uint8List.fromList([0x3B, 0x6B, 0xB2, 0x8C, 0xAF]);
    final FILE_BUFF_DEC = Uint8List.fromList([0x74, 0x65, 0x73, 0x74, 0x0A]);
    var serverHits = 0;
    Future<Uint8List> downloadCallback(Uri uri) async {
      serverHits++;
      return FILE_BUFF_ENC;
    }

    final room = Room(id: '!localpart:server.abc', client: await getClient());
    final event = Event.fromJson(
      {
        'type': EventTypes.Message,
        'content': {
          'body': 'file',
          'msgtype': 'm.file',
          'file': {
            'v': 'v2',
            'key': {
              'alg': 'A256CTR',
              'ext': true,
              'k': '7aPRNIDPeUAUqD6SPR3vVX5W9liyMG98NexVJ9udnCc',
              'key_ops': ['encrypt', 'decrypt'],
              'kty': 'oct',
            },
            'iv': 'Wdsf+tnOHIoAAAAAAAAAAA',
            'hashes': {
              'sha256': 'WgC7fw2alBC5t+xDx+PFlZxfFJXtIstQCg+j0WDaXxE',
            },
            'url': 'mxc://example.com/cachedenc',
            'mimetype': 'text/plain',
          },
          'info': {'size': 5},
        },
        'event_id': r'$cachetest',
        'sender': '@alice:example.org',
      },
      room,
    );

    // 第一次：从服务器下载并解密
    final buffer1 = await event.downloadAndDecryptAttachment(
      downloadCallback: downloadCallback,
    );
    expect(buffer1.bytes, FILE_BUFF_DEC);
    expect(serverHits, 1);

    // 第二次：若数据库支持文件存储，应命中解密缓存，不再请求服务器
    final buffer2 = await event.downloadAndDecryptAttachment(
      downloadCallback: downloadCallback,
    );
    expect(buffer2.bytes, FILE_BUFF_DEC);
    expect(
      serverHits,
      event.room.client.database.supportsFileStoring ? 1 : 2,
      reason: 'IO 平台应命中解密缓存，不再访问服务器',
    );

    await room.client.dispose(closeDatabase: true);
  });
  ```

- [x] **Step 3：运行新测试（需要 OLM 环境）**

  ```bash
  dart test test/event_test.dart -t olm -N "downloadAndDecryptAttachment caches decrypted content" --concurrency=1
  ```

  期望输出：`+1: All tests passed!`

  如无 OLM 环境，使用以下命令跳过并验证其他测试不受影响：

  ```bash
  dart test test/event_test.dart -x olm --concurrency=$(getconf _NPROCESSORS_ONLN)
  ```

  期望输出：所有非 OLM 测试通过，无新失败。

- [x] **Step 4：运行完整 event 测试套件**

  ```bash
  dart test test/event_test.dart -x olm --concurrency=$(getconf _NPROCESSORS_ONLN)
  ```

  期望输出：`All tests passed!`（OLM 测试跳过不计入）

- [x] **Step 5：提交**

  ```bash
  git add test/event_test.dart
  git commit -m "test: 新增加密附件解密内容缓存测试"
  ```

---

## Task 4：全量测试与静态分析验证

**Files:** 无新增文件

- [x] **Step 1：格式化代码**

  ```bash
  dart format lib/src/database/database_file_storage_io.dart lib/src/event.dart test/event_test.dart
  ```

- [x] **Step 2：全量静态分析**

  ```bash
  dart analyze
  ```

  期望输出：`No issues found!`

- [x] **Step 3：运行全量测试（跳过 OLM）**

  ```bash
  dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test -x olm
  ```

  期望输出：`All tests passed!`

- [x] **Step 4：（可选）运行 OLM 测试**

  如有 vodozemac 环境：

  ```bash
  dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test -t olm
  ```

  期望输出：`All tests passed!`

- [x] **Step 5：提交格式化（如有变更）**

  ```bash
  git add -u
  git diff --cached --quiet || git commit -m "style: dart format"
  ```
