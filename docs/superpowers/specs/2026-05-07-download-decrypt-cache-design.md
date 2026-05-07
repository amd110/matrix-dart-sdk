# 设计方案：流式下载与解密文件缓存

**日期：** 2026-05-07  
**涉及文件：** `lib/src/event.dart`、`lib/src/database/database_file_storage_io.dart`

## 目标

1. 将加密附件的**解密内容**缓存到数据库，后续调用可直接命中缓存，跳过下载和解密步骤。
2. 下载时在 IO 平台（已配置文件存储目录）将响应字节**流式写入临时文件**，而非将所有分块积累在内存中，降低大文件（如视频）的峰值内存占用。

## 非目标

- 流式解密（AES-CTR 解密仍需全量字节在内存中）。
- 修改公开的 `downloadCallback` 参数签名。
- Web 平台及未配置存储目录的场景（保持现有内存路径不变）。
- 修改 `DatabaseApi` 抽象类或 Stub 实现。

---

## 详细设计

### 1. 解密内容缓存键

对加密附件，使用派生缓存键来存储和读取解密内容：

```dart
final cacheKey = isEncrypted
    ? mxcUrl.replace(queryParameters: {'decrypted': '1'})
    : mxcUrl;
```

| 事件类型 | 读缓存键    | 写缓存键    | 存储内容     |
|---------|------------|------------|-------------|
| 非加密   | `mxcUrl`   | `mxcUrl`   | 原始字节     |
| 加密     | `cacheKey` | `cacheKey` | 解密后字节   |

**缓存命中：** 若 `getFile(cacheKey)` 返回非 null，则直接跳过下载和解密，直接构造 `MatrixFile` 返回。

**旧缓存兼容：** 旧版会调用 `storeFile(mxcUrl, encryptedBytes)` 写入加密原文。新方案中加密事件不再写加密原文缓存，已存在的旧条目不会被新 key 命中，将由 `deleteOldFiles` 自然清理，无需迁移逻辑。

---

### 2. IO mixin 新增方法：`downloadToMemoryViaStream`

仅在 `database_file_storage_io.dart` mixin 中新增，不修改 `DatabaseApi` 抽象类。

```dart
// database_file_storage_io.dart
Future<Uint8List> downloadToMemoryViaStream(
  Stream<List<int>> stream, {
  void Function(int)? onProgress,
  CancellationToken? cancellationToken,
});
```

**实现步骤：**

1. 在 `fileStorageLocation` 目录下创建临时文件：`<fileStorageLocation>/<uuid>.tmp`。
2. 通过 `file.openWrite()` 获取 `IOSink`。
3. 逐块处理流数据：
   - 每个分块到达时：检查 `cancellationToken`，将分块写入 sink，调用 `onProgress`。
   - 若已取消：关闭 sink，删除临时文件，抛出 `DownloadCancelledException`。
4. 关闭 sink。
5. 调用 `readAsBytes()` 将文件读回内存（供后续解密使用）。
6. 在 `finally` 块中删除临时文件，确保无论成功还是异常都会清理。

---

### 3. `downloadAndDecryptAttachment` 完整控制流

```
1. 非已发送事件 → 尝试本地发送缓存（_getCachedFile），找到则直接返回。

2. 解析 mxcUrl；确定 isEncrypted。

3. 构造 cacheKey：
     加密事件   → mxcUrl.replace(queryParameters: {'decrypted': '1'})
     非加密事件 → mxcUrl

4. 若 storeable：uint8list = await database.getFile(cacheKey)
   缓存命中 → 跳到步骤 8。

5. 下载前检查 cancellationToken。

6. 下载：
   - downloadCallback != null（调用方传入）：
       uint8list = await downloadCallback(downloadUri)        // 保持现有路径不变
   - downloadCallback == null 且 database.supportsFileStoring（IO 平台已配置存储目录）：
       发起 HTTP GET，获取 StreamedResponse
       uint8list = await (database as DatabaseFileStorage).downloadToMemoryViaStream(
         response.stream,
         onProgress: onDownloadProgress,
         cancellationToken: cancellationToken,
       )
   - downloadCallback == null 且 !database.supportsFileStoring（Web / 未配置）：
       发起 HTTP GET，获取 StreamedResponse
       uint8list = await response.stream.toBytesWithProgress(
         onDownloadProgress,
         contentLength: response.contentLength,
         cancellationToken: cancellationToken,
       )                                                       // 保持现有内存路径不变

7. 写缓存：
   - 非加密事件：storeFile(mxcUrl, uint8list)（不变）
   - 加密事件：不写加密原文

8. 解密前检查 cancellationToken。

9. 解密（仅加密事件）：
   - decryptedBytes = await nativeImplementations.decryptFile(encryptedFile)
   - storeFile(cacheKey, decryptedBytes)   ← 新增：写入解密内容缓存
   - uint8list = decryptedBytes

10. 构造并返回 MatrixFile(bytes: uint8list, ...)。
```

---

## 涉及文件变更

| 文件 | 变更内容 |
|------|---------|
| `lib/src/database/database_file_storage_io.dart` | 新增 `downloadToMemoryViaStream` 方法 |
| `lib/src/event.dart` | 按上述控制流更新 `downloadAndDecryptAttachment` |
| `lib/src/database/database_api.dart` | **不改动** |
| `lib/src/database/database_file_storage_stub.dart` | **不改动** |

---

## 错误处理

- `cancellationToken` 在下载前和解密前检查（与现在一致）；IO 流式路径中每个分块到达时额外检查一次。
- 临时文件在 `finally` 块中删除，无论成功还是异常均保证清理。
- 若 `decryptFile` 返回 null，与现有逻辑一致抛出 `'Unable to decrypt file'`。

## 测试要点

- 现有 `downloadAndDecryptAttachment` 测试应继续通过（传入 `downloadCallback` 时走非流式路径）。
- 新增单元测试：验证解密内容以正确的 `cacheKey` 写入，且下次调用直接命中缓存跳过解密。
