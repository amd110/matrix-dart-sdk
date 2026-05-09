# Matrix Dart SDK 开发指南

本项目使用纯 Dart 编写，是一个 Matrix 协议完整客户端 SDK。在此项目中工作时，请遵循以下核心原则和工作流：

## 核心原则

*   **架构模式：** 
    *   **响应式流：** SDK 大量使用 `Stream` 和 `StreamController` (`onUpdate`, `onInsert`, `syncStream`) 进行响应式更新。
    *   **事件模型：** 核心事件类为 `Event`，并在此之上封装了本地缓存、UI状态及解密状态等。
    *   **数据库与缓存：** 默认使用 SQFlite/SQLite 进行持久化，内存使用 `CachedStreamController` 减少请求，Web 平台使用 IndexedDB。
*   **代码风格：** 严格遵循 `snake_case` 命名法（文件/目录），优先使用类而非函数，优先使用 Dart 扩展（Extensions）而不是包装类。禁止硬编码字符串，需支持本地化。
*   **E2EE（端到端加密）：** 使用 Rust 编写的 `vodozemac` 作为 E2EE 核心。为了防止 Flutter 应用在加密大型媒体文件时无响应 (ANR)，请使用后台 Isolate (`NativeImplementationsIsolate` 或 `NativeImplementationsPersistentIsolate`) 处理加密操作。
*   **并发：** 尽可能使用 `Future.wait()` 将网络请求并行化，以降低总体延迟。

## 开发工作流

### 环境与依赖
使用 `dart pub get` 安装依赖。
如需覆盖率报告，运行：`pub global activate coverage`

### 测试策略
项目具备强大的测试套件，使用 `FakeMatrixApi`、`FakeClient` 和 `FakeDatabase` 进行离线测试。

*   **运行全量测试 (跳过 OLM):** `dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test -x olm`
*   **运行 OLM 测试 (需要配置 vodozemac):** `dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test -t olm`
*   **生成覆盖率报告:** `./scripts/test.sh`

### 代码质量验证
*   **代码格式化：** 修改代码后，必须运行 `dart format lib test`。
*   **静态分析：** 提交前确保 `dart analyze` 无报错，并使用 `import_sorter --set-exit-if-changed .` 排序导入。

### 处理加密事件的约定
*   收到的加密事件将进入 `_EventPendingDecryption` 队列异步解密。
*   不要将加密的原文和解密后的内容混存；如果解密成功，将使用派生 Key (例如 `?decrypted=1`) 存储解密内容，避免重复解密。

---
**沟通要求：**
在本项目中，所有回复和说明请始终使用 **中文**。
