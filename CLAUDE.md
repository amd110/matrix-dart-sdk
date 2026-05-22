# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

本文件为 Claude Code（claude.ai/code）在此代码库中工作时提供指导。

## 仓库概述

**Matrix Dart SDK** 是一个用纯 Dart 编写的 Matrix 协议完整客户端 SDK，负责同步、房间管理、消息事件、VoIP、端对端加密（E2EE）及数据库持久化。SDK 支持 Web、原生（IO）和 Flutter 平台。

### 核心组件

- **Client**（`lib/src/client.dart`）：主入口——管理登录、同步、房间生命周期和服务器通信，继承自 `MatrixApi`
- **Room**（`lib/src/room.dart`）：表示一个 Matrix 房间，包含事件历史、成员和状态
- **Event**（`lib/src/event.dart`）：表示单个 Matrix 事件（消息、状态变更等）
- **Timeline**（`lib/src/timeline.dart`）：管理房间的分页消息历史
- **Encryption**（`lib/encryption.dart`）：通过 vodozemac（Rust 绑定）提供 E2EE 支持，包含 `cross_signing.dart`、`key_manager.dart`、`olm_manager.dart`、`ssss.dart`
- **Database**（`lib/src/database/`）：`DatabaseApi` 抽象接口 + `MatrixSdkDatabase` 实现，原生用 SQFlite，Web 用 IndexedDB；通过条件导入自动选择（`sqflite_box.dart` vs `indexeddb_box.dart`）
- **Matrix API Lite**（`lib/matrix_api_lite.dart`）：Matrix 客户端-服务器 API 的底层 HTTP 绑定，大部分由规范自动生成
- **VoIP**（`lib/src/voip/`）：支持 WebRTC 的通话会话管理（mesh 和 LiveKit 后端）
- **MSC 扩展**（`lib/msc_extensions/`）：Matrix 规范变更提案（投票、Widget、OIDC 等）
- **主导出**（`lib/matrix.dart`）：SDK 的公开 API 统一入口

## 开发命令

### 安装与依赖

```bash
dart pub get              # 安装依赖
pub global activate coverage  # 用于覆盖率报告（CI 会自动执行）
```

### 代码质量

```bash
dart format lib test      # 格式化代码（CI 必须通过）
dart analyze              # 运行静态分析（包含 famedly_dart_lints）
import_sorter --set-exit-if-changed .  # 排序导入（CI 强制执行）
```

### 测试

```bash
# 以并发方式运行所有测试（默认并发数为 CPU 核心数）
dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test

# 运行特定测试文件
dart test test/client_test.dart

# 跳过需要环境配置的 E2EE/OLM 测试
dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test -x olm

# 仅运行 OLM 相关测试（需提前配置 E2EE 环境）
dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test -t olm

# 生成覆盖率报告（同时清理生成的文件）
./scripts/test.sh

# Web 平台测试（需要 Chrome）
dart test test/box_test.dart --platform chrome

# E2EE 集成测试（需启动本地 homeserver：Synapse/Dendrite/Conduit）
# 详见 scripts/integration-*.sh
export HOMESERVER_IMPLEMENTATION=synapse  # 或 dendrite/conduit
scripts/integration-server-${HOMESERVER_IMPLEMENTATION}.sh 2>&1 > /dev/null &
source scripts/integration-create-environment-variables.sh
scripts/integration-prepare-homeserver.sh
dart pub get
scripts/prepare_vodozemac.sh
dart test test_driver/matrixsdk_test.dart -p vm
```

### CI 工作流

仓库使用 GitHub Actions（`.github/workflows/integrate.yml`）：
- **Dart 检查**：通过 `famedly/frontend-ci-templates` 共享工作流进行格式化、分析和 lint
- **E2EE 测试**：在 Synapse、Dendrite 和 Conduit homeserver 上运行（可选 fail-fast）
- **覆盖率**：分两次运行（含 OLM 和不含 OLM），合并后生成完整报告
- **Web 兼容性**：通过 `webdev` 确保 SDK 能编译为 JavaScript
- **数据库 Web 测试**：基于 Chrome 的 SQFlite Web 支持测试

打上 `v*.*.*.` 标签会自动发布到 pub.dev。

## 架构模式

### 响应式流

SDK 大量使用 Dart 的 `Stream` 和 `StreamController` 进行响应式更新：
- **`onUpdate`**：房间或事件数据变化时触发
- **`onInsert`**：新事件到达时触发
- **`onRemove`**：事件删除时触发
- **`syncStream`**：发出同步状态更新和连接状态

示例：时间线分页触发 `onUpdate` 回调；房间成员变更在 `updateNotifier` 上发出事件。

### 事件模型

**Event** 是基类；**MatrixEvent**（来自 API lite）提供原始协议数据。SDK Event 在协议数据之上封装了：
- 解密状态（已加密、已解密、失败）
- 本地缓存（文件下载）
- UI 状态（发送状态、已读回执）

事件通常存储在房间中；时间线提供分页访问。

### 数据库与缓存

- **SQFlite/SQLite**：跨会话持久化存储；自定义实现须实现 `DatabaseApi` 抽象接口
- **内存缓存**：`CachedStreamController` 用于房间/事件数据，避免重复拉取
- **加密**：SQFlite 通过 `sqflite_encryption_helper` 支持加密数据库
- **Web 支持**：BoxCollection 在 Web 平台使用 IndexedDB
- **Android 注意**：SQFlite 的 CursorWindow 对大数据量可能过小，建议改用 `sqflite_sqlcipher` 或 `sqflite_common_ffi`（见 [issue #1642](https://github.com/famedly/matrix-dart-sdk/issues/1642)）

### 客户端生命周期

1. **创建**：实例化 `Client`（可选传入数据库）
2. **检查 homeserver**：通过 `checkHomeserver(uri)` 验证服务器
3. **登录**：支持密码、OIDC、SSO 或设备 token 流程
4. **同步**：通过 `client.sync()` 或 `client.onSyncStream()` 启动持续同步
5. **访问房间**：遍历 `client.rooms` 或按 ID 查找
6. **监听事件**：订阅 `room.onUpdate` 或时间线流
7. **登出**：调用 `client.logout()` 进行清理

### E2EE 流程

启用 E2EE 后（通过 `Client(..., encryption: encryption)` 配合 vodozemac）：
1. Client 管理设备密钥并上传到服务器
2. 发出的消息在发送前进行加密
3. 收到的加密事件进入队列，异步解密
4. 密钥验证和设备信任由 encryption 模块管理

### 文件加密与 Isolate 卸载

大文件加密（AES-CTR）可通过后台 Isolate 卸载，防止 Flutter 应用在加密大型视频/媒体文件时出现 ANR（应用无响应）错误。有三种实现：
- **`NativeImplementationsDummy`**：内联执行，阻塞 UI（默认）
- **`NativeImplementationsIsolate`**：基于 Flutter `compute` 的临时 isolate
- **`NativeImplementationsPersistentIsolate`**：单一长期存活的 isolate，减少 isolate 启动开销

**在 Flutter 应用中配置：**
```dart
import 'package:flutter/foundation.dart' show compute;
import 'package:matrix/matrix.dart';

final client = Client(
  'MyApp',
  nativeImplementations: NativeImplementationsIsolate(compute),
  // ... 其他配置
);
```

SDK 在文件上传时自动使用所提供的实现。文件和缩略图上传通过 `Future.wait()` 并行执行，可将总上传时间缩短 30–50%。对于非 Flutter 或非 Isolate 环境，默认使用 `NativeImplementations.dummy`（内联加密，无卸载）。

**API 兼容性**：`MatrixFile.encrypt()` 方法接受可选的 `nativeImplementations` 参数，默认值为 `NativeImplementations.dummy`，确保与现有代码向后兼容。

## 代码风格与规范

遵循 CONTRIBUTING.md 和 famedly_dart_lints。分支命名规范：`username/name-your-changes`（如 `alice/fix-this-bug`），提交遵循 [Conventional Commits](https://www.conventionalcommits.org/)。

- **文件/目录名**：`snake_case`
- **导入**：通过 `import_sorter` 和 `dart format` 排序和格式化
- **Dartdoc**：所有公开类、方法和属性必须有文档注释
- **类优于函数**：类似 Widget 的代码使用类而非函数
- **避免混用范式**：不要将命令式状态变更（void 返回）与函数式编程混用
- **扩展优于包装类**：使用 Dart 扩展来扩展类功能，而非包装类
- **禁止硬编码字符串**：所有面向用户的文本需本地化
- **配置**：在 analysis_options.yaml 中配置 lint 规则；部分规则因历史代码原因已禁用（见 non_constant_identifier_names、sort_pub_dependencies）
- **平台条件导入**：Web 与原生差异通过 `if (dart.library.js_interop)` 条件导入实现（如 `sqflite_box.dart` vs `indexeddb_box.dart`、`database_file_storage_io.dart` vs `database_file_storage_stub.dart`）

## 常见工作流

### 新增 API 端点

1. 在 `lib/matrix_api_lite/...` 中定义请求/响应模型（从规范生成）
2. 在 `lib/matrix_api_lite/matrix_api_lite.dart` 的 `MatrixApi` 中添加 HTTP 方法
3. 若影响 Client 行为，在 `lib/src/client.dart` 中添加包装方法
4. 在 `test/` 中按对应结构编写测试
5. 添加 dartdoc 注释

### 处理加密事件

1. 收到的加密事件自动进入 `_EventPendingDecryption` 队列
2. 解密异步进行；事件解密完成后通过 `onUpdate` 发出更新
3. 解密失败的事件保留在时间线中，并设置 `bodyIsPlaintext` 标志
4. 使用 `event.content['body']` 作为明文回退

### 扩展 MSC 功能

MSC 扩展位于 `lib/msc_extensions/`，通常：
- 导出新的模型类（如 `PollEventContent`）
- 为 `Room` 或 `Client` 添加扩展方法（如 `room.createPoll()`）
- 添加工具类（如 `poll_room_extension.dart`）

使用方式：`import 'package:matrix/msc_extensions/msc_3381_polls/poll_event_extension.dart'`

## 主要依赖

- **vodozemac_plus**：基于 Rust 的 E2EE（需要原生二进制或 flutter_vodozemac）
- **SQFlite/SQLite**：支持外键和加密的数据库
- **http**：带超时配置的 HTTP 客户端
- **canonical_json**：符合规范的 JSON 编码（用于签名）
- **webrtc_interface**：原生 WebRTC 实现的抽象层
- **markdown**：事件内容解析（通过标志启用 LaTeX 支持）

## 测试模式

- **FakeMatrixApi**：模拟整个 HTTP 层，支持离线测试
- **FakeClient**：预配置的测试用客户端（见 `test/fake_client.dart`）
- **FakeDatabase**：内存数据库 mock
- **测试隔离**：每个测试应自行创建客户端/数据库，避免状态泄漏

## 调试技巧

- 设置环境变量 `HOMESERVER` 和用户凭据用于集成测试
- 在测试中使用 `--define=KEY=VALUE` 标志传入编译时常量
- 在断言前检查 `client.isLogged` 和 `client.rooms` 状态
- OLM 测试需要配置 vodozemac；如不可用，使用 `-x olm` 跳过
- 覆盖率报告在运行 `./scripts/test.sh` 后生成于 `coverage_dir/`

## 语言要求

请始终使用中文回答所有问题。
