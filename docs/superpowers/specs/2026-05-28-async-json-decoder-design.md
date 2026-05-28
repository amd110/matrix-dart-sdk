# 设计文档：异步 JSON 解码器注入

**日期**：2026-05-28  
**状态**：已批准  
**目标**：将 sync 响应的 `jsonDecode` 调用卸载到后台 Isolate，消除 Flutter 应用中因大型 JSON 解析阻塞主线程导致的 UI 卡顿

---

## 背景

Matrix sync 响应可达 MB 级别，`jsonDecode` 在主 Isolate 上同步执行，阻塞 Flutter UI 线程（最长数百毫秒），造成掉帧。

SDK 已有完整的 `NativeImplementations` Isolate 基础设施，但未覆盖 JSON 解析。

---

## 方案

在 `MatrixApi` 上添加一个可注入的异步 JSON 解码器属性。SDK 默认行为不变，Flutter 用户按需注入基于 `Isolate.run`、`compute` 或持久 Isolate 的异步实现。

---

## 接口设计

### `MatrixApi` 新增属性

```dart
// lib/matrix_api_lite/matrix_api_lite.dart

/// 可选的异步 JSON 解码器。
/// 为 null 时直接调用 [jsonDecode]（默认行为，与现有行为完全一致）。
/// Flutter 用户可注入基于 [Isolate.run] 的实现以避免主线程阻塞。
///
/// 示例：
/// ```dart
/// client.asyncJsonDecoder = (raw) => Isolate.run(() => jsonDecode(raw));
/// ```
Future<dynamic> Function(String)? asyncJsonDecoder;
```

### `generated/api.dart` sync 端点改动

```dart
// 改动前（约第 5165 行）：
final responseString = utf8.decode(responseBody);
final json = jsonDecode(responseString);
return SyncUpdate.fromJson(json as Map<String, Object?>);

// 改动后：
final responseString = utf8.decode(responseBody);
final dynamic json = asyncJsonDecoder != null
    ? await asyncJsonDecoder!(responseString)
    : jsonDecode(responseString);
return SyncUpdate.fromJson(json as Map<String, Object?>);
```

---

## 修改范围

| 文件 | 类型 | 改动说明 |
|---|---|---|
| `lib/matrix_api_lite/matrix_api_lite.dart` | 现有文件 | 添加 `asyncJsonDecoder` 属性声明 |
| `lib/matrix_api_lite/generated/api.dart` | 现有文件（生成） | sync 端点：1 处 `jsonDecode` 改为条件异步调用 |

**不涉及**：`client.dart`、`NativeImplementations`、数据库层、所有模型类。

---

## 应用层使用示例

```dart
import 'dart:isolate';
import 'dart:convert';

final client = Client('MyApp', ...);

// login 前注入，一次配置永久生效
// 可以是 Isolate.run（每次新建）、compute（Flutter）或持久 Isolate
client.asyncJsonDecoder = (raw) => Isolate.run(() => jsonDecode(raw));
```

应用层可自行选择 Isolate 管理策略，SDK 不强制任何实现。

---

## 不在本次范围内

- 其他 API 端点的异步化（sync 是唯一 MB 级热路径）
- SDK 内置持久 Isolate 工具类
- `NativeImplementations` 的扩展
- `fromJson` 模型构建的 Isolate 化

---

## 测试策略

- 注入一个同步包装的 `asyncJsonDecoder`，验证 sync 流程与原有行为一致
- `asyncJsonDecoder = null` 时，验证回退到 `jsonDecode`（向后兼容）
- 不新增测试文件，在现有 `client_test.dart` 中添加覆盖
