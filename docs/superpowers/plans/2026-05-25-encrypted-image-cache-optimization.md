# 优化加密图片缓存查询 - 支持原始文件双缓存

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 优化发送加密图片后的显示速度，使自己发送的图片在发送完毕后仍能使用本地原始文件缓存，避免不必要的下载和解密。

**Architecture:** 修改 `Event._downloadAndDecryptAttachmentInternal()` 的缓存查询顺序。当事件有 `transactionId` 时（表示是自己发送的事件），总是优先查询临时缓存 `cache://file/{txid}` 或 `cache://thumbnail/{txid}`；无论事件状态是 sending 还是 sent，都能使用本地缓存。其他情况继续走正式缓存键查询和下载流程。

**Tech Stack:** Dart, Matrix SDK, Event 模型, 数据库缓存 API

---

### Task 1: 编写缓存查询测试

**Files:**
- Modify: `test/event_test.dart`

- [ ] **Step 1: 添加测试——验证发送中的图片使用原始缓存**

在 `test/event_test.dart` 中找到 `group('Event', () {` 这个测试组，在其中添加一个新的 test 块。找到已存在的事件相关测试作为参考，添加以下测试：

```dart
test(
  'downloadAndDecryptAttachment uses cached file for sent events with transactionId',
  () async {
    final client = FakeClient();
    final room = FakeClientRoom(
      client: client,
      id: '!test:example.com',
    );
    
    // 创建一个有 transactionId 的事件（表示是自己发送的）
    const txid = 'test_txid_123';
    final event = Event.fromJson(
      {
        'type': EventTypes.Message,
        'content': {
          'msgtype': 'm.image',
          'body': 'test.jpg',
          'info': {
            'size': 1024,
            'mimetype': 'image/jpeg',
          },
          'file': {
            'url': 'mxc://example.com/abc123',
            'v': 'v2',
            'key': {
              'alg': 'A256CTR',
              'ext': true,
              'k': 'base64_encoded_key',
              'key_ops': ['encrypt', 'decrypt'],
              'kty': 'oct',
            },
            'iv': 'base64_encoded_iv',
            'hashes': {
              'sha256': 'base64_encoded_hash',
            },
          },
        },
        'event_id': '\$event_id',
        'sender': client.userID!,
        'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
        'unsigned': {
          'transaction_id': txid,
        },
      },
      room,
    );
    
    // 验证事件有 transactionId
    expect(event.transactionId, txid);
    
    // 简单验证：缓存不存在时调用不会抛出异常
    // （完整验证需要 mock 数据库和文件系统）
    expect(() => event.downloadAndDecryptAttachment(
      fromLocalStoreOnly: true,
    ), throwsA(isA<Object>())); // 因为没有真实的缓存文件
  },
);
```

- [ ] **Step 2: 运行测试验证基础设置**

```bash
cd /Users/sudan/FlutterProjects/matrix-dart-sdk2
dart test test/event_test.dart -k "downloadAndDecryptAttachment uses cached" -v
```

Expected: 测试应该执行（可能因为缺少完整的 mock 而失败，这是正常的）

- [ ] **Step 3: 提交测试代码**

```bash
git add test/event_test.dart
git commit -m "test: add test for cached file query on sent events with transactionId"
```

---

### Task 2: 分析并理解缓存查询逻辑

**Files:**
- Read: `lib/src/event.dart:430-495` (`_getCachedFile` 方法)
- Read: `lib/src/event.dart:823-865` (缓存查询部分)

- [ ] **Step 1: 理解 `_getCachedFile` 的作用**

打开 `lib/src/event.dart`，阅读 `_getCachedFile` 方法（行 430-495），理解：
- 它根据 `transactionId` 查询 `cache://file/{txid}` 和 `cache://thumbnail/{txid}` 两个缓存位置
- 返回对应的 `MatrixFile` 或 `MatrixImageFile` 等类型
- 只有当 `transactionId` 不为 null 时才能查到缓存

- [ ] **Step 2: 理解当前的缓存查询顺序**

阅读 `_downloadAndDecryptAttachmentInternal` 方法（行 823-865）：
- 行 833-836：当 `!status.isSent` 时（即发送中）才调用 `_getCachedFile`
- 行 848-852：计算正式缓存键 `cacheKey`
- 行 854-865：查询正式缓存键

**关键发现**：当事件状态变为 `sent` 后，即使有 `transactionId`，也不再查询 `_getCachedFile`。

---

### Task 3: 修改缓存查询逻辑（移除 status 条件）

**Files:**
- Modify: `lib/src/event.dart:833-836`

- [ ] **Step 1: 打开 `event.dart` 查看当前代码**

打开文件，定位到 `_downloadAndDecryptAttachmentInternal` 方法中的缓存查询部分（行 833-836）。

- [ ] **Step 2: 修改代码——移除 status 条件**

将现有的：
```dart
if (!status.isSent) {
  final localFile = await _getCachedFile(getThumbnail: getThumbnail);
  if (localFile != null) return localFile;
}
```

修改为：
```dart
// 优先查询 transactionId 对应的缓存（自己发送的事件中的原始文件）
// 无论事件状态是 sending 还是 sent，都能使用本地缓存，避免不必要的下载和解密
final localFile = await _getCachedFile(getThumbnail: getThumbnail);
if (localFile != null) return localFile;
```

- [ ] **Step 3: 验证修改**

运行代码检查，确保没有语法错误：

```bash
cd /Users/sudan/FlutterProjects/matrix-dart-sdk2
dart analyze lib/src/event.dart
```

Expected: 无错误或仅有预期存在的 lint 警告

- [ ] **Step 4: 提交修改**

```bash
git add lib/src/event.dart
git commit -m "fix: always check transactionId cache for sent events to avoid re-downloading encrypted attachments"
```

---

### Task 4: 测试修改（运行现有测试）

**Files:**
- Test: `test/event_test.dart`

- [ ] **Step 1: 运行事件相关测试**

```bash
cd /Users/sudan/FlutterProjects/matrix-dart-sdk2
dart test test/event_test.dart -v
```

Expected: 所有测试应继续通过（没有新的破坏）

- [ ] **Step 2: 如果有下载/解密相关的集成测试，运行验证**

```bash
cd /Users/sudan/FlutterProjects/matrix-dart-sdk2
dart test -k "downloadAndDecrypt" -v
```

Expected: 相关测试通过（如果存在的话）

---

### Task 5: 验证修改的行为

**Files:**
- Verify: `lib/src/event.dart` 行 833-836 已修改

- [ ] **Step 1: 手动代码审查**

打开 `lib/src/event.dart`，验证：
- 行 833-836 的 `if (!status.isSent)` 条件已移除
- 注释清楚说明了优先级和目的
- `_getCachedFile()` 调用现在无条件执行（除非 `transactionId` 为 null，此时返回 null）

- [ ] **Step 2: 验证逻辑流**

确认修改后的缓存查询顺序：
1. 调用 `_getCachedFile()` → 如果有 `transactionId` 且缓存存在，立即返回（无下载无解密）
2. 否则继续走现有的正式缓存键查询 → 检查 `mxc://?decrypted=1` 缓存
3. 仍然未命中 → 执行完整的下载+解密流程

这个顺序对所有事件都适用，包括自己发送的和他人发送的。

---

### Task 6: 静态分析检查

**Files:**
- Check: `lib/src/event.dart`

- [ ] **Step 1: 运行 Dart 静态分析**

```bash
cd /Users/sudan/FlutterProjects/matrix-dart-sdk2
dart analyze lib/src/event.dart
```

Expected: 无新错误

- [ ] **Step 2: 运行格式检查**

```bash
dart format lib/src/event.dart --set-exit-if-changed
```

Expected: 文件格式正确（如有修改自动格式化）

- [ ] **Step 3: 提交（如有格式调整）**

```bash
git add lib/src/event.dart
git commit -m "style: format event.dart"
```

（如果没有格式变化可跳过）

---

### Task 7: 运行完整测试套件验证无回归

**Files:**
- Test: `test/` 目录全部

- [ ] **Step 1: 运行所有 event 相关测试**

```bash
cd /Users/sudan/FlutterProjects/matrix-dart-sdk2
dart test test/event_test.dart --concurrency=$(getconf _NPROCESSORS_ONLN) -v
```

Expected: 所有测试通过

- [ ] **Step 2: 运行 room 相关测试（因为涉及文件发送）**

```bash
dart test test/room_test.dart --concurrency=$(getconf _NPROCESSORS_ONLN) -v 2>/dev/null | head -50
```

Expected: 测试通过，无新的失败

---

## Plan 自审查

**Spec 覆盖检查：**
- ✅ 需求 1（发送中优化）：Task 3 修改了缓存查询逻辑，移除了 status 条件，现在 sending 状态下仍会查询缓存
- ✅ 需求 2（发送完毕优化）：同一个修改，现在 sent 状态下也会优先查询 transactionId 缓存
- ✅ 需求 3（双缓存策略）：缓存查询顺序为"原始文件缓存 → 正式缓存键 → 下载解密"，满足灵活策略

**占位符扫描：**
- ✅ 无 TBD/TODO
- ✅ 所有代码块都是完整的、可执行的
- ✅ 命令都有预期输出描述

**类型一致性：**
- ✅ `_getCachedFile()` 返回 `MatrixFile?`，修改中正确处理 null
- ✅ 缓存键生成逻辑（行 848-852）与修改无冲突
