# 异步 JSON 解码器注入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `Api` 类上添加可注入的 `asyncJsonDecoder` 属性，使 sync 端点的 `jsonDecode` 调用可被应用层替换为后台 Isolate 版本，消除主线程 JSON 解析阻塞。

**Architecture:** 在 `generated/api.dart` 的 `Api` 类上新增 `Future<dynamic> Function(String)?` 类型属性 `asyncJsonDecoder`；sync 方法检查该属性，非 null 时 await 调用，null 时回退到同步 `jsonDecode`。所有其他方法和文件不受影响。

**Tech Stack:** Dart 3.x, dart:convert (jsonDecode), package:http

---

## 文件变更一览

| 文件 | 操作 | 说明 |
|---|---|---|
| `lib/matrix_api_lite/generated/api.dart` | 修改 | `Api` 类添加属性 + sync 方法改为条件异步 |
| `test/matrix_api_test.dart` | 新建 | 验证 asyncJsonDecoder 的两种行为 |

---

### Task 1：编写失败测试

**Files:**
- Create: `test/matrix_api_test.dart`

- [ ] **Step 1：创建测试文件**

```dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart';
import 'package:matrix/matrix_api_lite/generated/api.dart';
import 'package:test/test.dart';

/// 最小 HTTP mock，对 sync 请求返回固定 JSON 响应。
class _SyncHttpClient extends BaseClient {
  final String responseBody;
  _SyncHttpClient(this.responseBody);

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    final bytes = utf8.encode(responseBody);
    return StreamedResponse(
      Stream.value(bytes),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  const minimalSyncJson = '{"next_batch":"s1","rooms":{},"account_data":{}}';

  group('Api.asyncJsonDecoder', () {
    test('asyncJsonDecoder 为 null 时使用同步 jsonDecode（默认行为）', () async {
      final api = Api(
        httpClient: _SyncHttpClient(minimalSyncJson),
        baseUri: Uri.parse('https://example.com'),
        bearerToken: 'token',
      );

      final result = await api.sync();
      expect(result.nextBatch, equals('s1'));
    });

    test('asyncJsonDecoder 非 null 时被调用替代 jsonDecode', () async {
      var decoderCalled = false;

      final api = Api(
        httpClient: _SyncHttpClient(minimalSyncJson),
        baseUri: Uri.parse('https://example.com'),
        bearerToken: 'token',
      );
      api.asyncJsonDecoder = (raw) async {
        decoderCalled = true;
        return jsonDecode(raw);
      };

      final result = await api.sync();
      expect(decoderCalled, isTrue);
      expect(result.nextBatch, equals('s1'));
    });

    test('asyncJsonDecoder 返回值被正确传入 SyncUpdate.fromJson', () async {
      final api = Api(
        httpClient: _SyncHttpClient(minimalSyncJson),
        baseUri: Uri.parse('https://example.com'),
        bearerToken: 'token',
      );
      api.asyncJsonDecoder = (raw) async => jsonDecode(raw);

      final result = await api.sync();
      expect(result.nextBatch, equals('s1'));
    });
  });
}
```

- [ ] **Step 2：运行测试，确认全部失败**

```bash
cd /Users/sudan/FlutterProjects/matrix-dart-sdk2
dart test test/matrix_api_test.dart -v
```

期望输出：三个测试失败，错误类似 `The getter 'asyncJsonDecoder' isn't defined for the class 'Api'`。

---

### Task 2：添加 `asyncJsonDecoder` 属性到 `Api`

**Files:**
- Modify: `lib/matrix_api_lite/generated/api.dart:20-25`

- [ ] **Step 1：在 `Api` 类的属性区域添加 `asyncJsonDecoder`**

当前代码（第 20-25 行）：

```dart
class Api {
  Client httpClient;
  Uri? baseUri;
  String? bearerToken;

  Api({Client? httpClient, this.baseUri, this.bearerToken}) : httpClient = httpClient ?? Client();
```

修改后：

```dart
class Api {
  Client httpClient;
  Uri? baseUri;
  String? bearerToken;

  /// 可选的异步 JSON 解码器。
  /// 为 null 时直接调用 [jsonDecode]（默认行为）。
  /// Flutter 用户可注入基于 [Isolate.run] 的实现以避免主线程阻塞：
  /// ```dart
  /// client.asyncJsonDecoder = (raw) => Isolate.run(() => jsonDecode(raw));
  /// ```
  Future<dynamic> Function(String)? asyncJsonDecoder;

  Api({Client? httpClient, this.baseUri, this.bearerToken}) : httpClient = httpClient ?? Client();
```

- [ ] **Step 2：运行测试，确认第一个测试（默认行为）已通过，后两个仍失败**

```bash
dart test test/matrix_api_test.dart -v
```

期望：第一个 test 通过（`asyncJsonDecoder` 为 null，sync 继续使用 `jsonDecode`），后两个仍失败（属性存在但 sync 方法还未读它）。

---

### Task 3：修改 sync 方法使用 `asyncJsonDecoder`

**Files:**
- Modify: `lib/matrix_api_lite/generated/api.dart:5164-5166`

- [ ] **Step 1：将 sync 方法中的 `jsonDecode` 替换为条件异步调用**

当前代码（第 5164-5166 行）：

```dart
    final responseString = utf8.decode(responseBody);
    final json = jsonDecode(responseString);
    return SyncUpdate.fromJson(json as Map<String, Object?>);
```

修改后：

```dart
    final responseString = utf8.decode(responseBody);
    final dynamic json = asyncJsonDecoder != null
        ? await asyncJsonDecoder!(responseString)
        : jsonDecode(responseString);
    return SyncUpdate.fromJson(json as Map<String, Object?>);
```

- [ ] **Step 2：运行全部新测试，确认三个全部通过**

```bash
dart test test/matrix_api_test.dart -v
```

期望：三个测试全部 PASS。

- [ ] **Step 3：运行现有完整测试套件，确认无回归**

```bash
dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test -x olm
```

期望：所有测试通过，无新增失败。

- [ ] **Step 4：运行静态分析**

```bash
dart analyze
```

期望：no issues found（或与改动前相同的已知 warning 数量不变）。

- [ ] **Step 5：提交**

```bash
git add lib/matrix_api_lite/generated/api.dart test/matrix_api_test.dart
git commit -m "feat: 添加 asyncJsonDecoder 属性，支持将 sync JSON 解析卸载到 Isolate"
```

---

## 应用层接入示例（供参考，不在本计划实现范围内）

```dart
import 'dart:isolate';
import 'dart:convert';

// 在 Client 初始化后、login 前注入
client.asyncJsonDecoder = (raw) => Isolate.run(() => jsonDecode(raw));
```
