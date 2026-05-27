# BentoZip - macOS 多格式压缩工具

## TL;DR

> **Quick Summary**: 构建一个 macOS 原生压缩/解压工具，支持 ZIP、7z、tar.gz 格式，具备 Finder 风格文件列表、拖放操作、右侧参数面板和进度窗口。
>
> **Deliverables**:
> - 完整 SwiftUI macOS 应用（toolbar + 主内容区 + inspector 面板）
> - ZIP 压缩/解压引擎（ZIP Foundation）
> - 7z + tar.gz 读写引擎（libarchive XCFramework）
> - 拖入文件/目录 → 压缩工作流
> - 拖入压缩包 → 浏览/解压工作流
> - 拖出列表项 → 解压到 Finder 目标位置
> - 进度窗口（二级 Window）
> - SwiftData 偏好设置持久化
>
> **Estimated Effort**: Large
> **Parallel Execution**: YES - 5 waves
> **Critical Path**: Task 1 → Task 2 → Task 4 → Task 6 → Task 9 → Task 12 → Task 16 → F1-F4

---

## Context

### Original Request
构建一个 macOS 压缩软件：顶部工具栏、可选右侧边栏（参数面板）、空状态提示、拖入文件显示 Finder 列表模式表格、目录可进入子目录、压缩参数调整、进度窗口、支持压缩和解压两种模式、列表项可拖出到 Finder。

### Interview Summary
**Key Discussions**:
- 压缩格式：ZIP + 7z + tar.gz（首批支持）
- 库选择：ZIP 用 ZIP Foundation（NSProgress 集成），7z/tar.gz 用 libarchive（C API via XCFramework）
- 修改策略：ZIP 直接操作；其他格式解压后重建
- SwiftData 用于偏好设置（默认压缩级别、排除模式等）
- 关闭 App Sandbox（完全文件系统访问）
- 压缩参数：基础（级别、名称、密码）+ 高级（分卷、目录结构、排除模式）
- 无单元测试，仅 Agent QA 场景

**Research Findings**:
- ZIP Foundation: NSProgress 原生支持，SPM 安装，生产级质量
- libarchive-for-swift (matteo-pacini): XCFramework 分发，macOS ≥ 13，含全部依赖
- SwiftUI .inspector(): macOS 14+ 原生右侧面板
- Transferable + FileRepresentation: 拖出到 Finder 需要先提取到临时目录
- WindowGroup(id:) + openWindow: 标准二级窗口方案

---

## Work Objectives

### Core Objective
构建一个功能完整的 macOS 压缩/解压工具，支持 ZIP、7z、tar.gz 三种格式，提供直观的拖放交互和 Finder 风格文件浏览。

### Concrete Deliverables
- `BentoZipApp.swift` - 重构的 App 入口（多 Scene、toolbar commands）
- `Models/` - FileEntry, CompressionSettings, AppPreferences, ArchiveMode
- `Services/` - ZIPEngine, LibArchiveEngine, ProgressTracker, FormatDetector
- `ViewModels/` - AppState (@Observable 中央状态管理)
- `Views/` - ContentView, FileListView, InspectorView, ProgressWindowView, ToolbarCommands
- `Utilities/` - PathUtils, FileUtils

### Definition of Done
- [ ] 拖入文件/目录 → 显示 Finder 风格列表，可导航子目录
- [ ] 调整压缩参数 → 点击压缩 → 进度窗口 → 生成压缩包
- [ ] 拖入压缩包 → 显示内容列表 → 点击解压 → 进度窗口 → 解压完成
- [ ] 列表项拖出窗口 → 解压到 Finder 目标位置
- [ ] 工具栏按钮根据模式（压缩/解压/空）正确启用/禁用
- [ ] 偏好设置通过 SwiftData 持久化

### Must Have
- 三种格式（ZIP、7z、tar.gz）的压缩和解压
- Finder 风格表格视图（名称、大小、类型、修改日期列）
- 目录导航（点击进入子目录，面包屑路径）
- 右侧 Inspector 参数面板
- 进度窗口（类似 Finder 拷贝进度）
- 拖入/拖出交互
- 智能保存位置（同父目录自动设定，否则弹窗）
- 工具栏上下文感知按钮

### Must NOT Have (Guardrails)
- 不实现 RAR 格式（后续扩展）
- 不实现分卷压缩（首批不包含，参数面板预留位置）
- 不使用 App Sandbox
- 不编写单元测试（仅 Agent QA 场景）
- 不实现密码保护（首批不包含，参数面板预留位置）
- 不使用 NSFilePromiseProvider（使用 Transferable 方案）
- 不修改 Xcode 项目文件中的 Bundle ID

---

## Verification Strategy

### Test Decision
- **Infrastructure exists**: YES (Swift Testing)
- **Automated tests**: None (per user decision)
- **Framework**: N/A

### QA Policy
每个任务必须包含 Agent 执行的 QA 场景。证据保存到 `.omo/evidence/task-{N}-{scenario-slug}.{ext}`。

- **UI 交互**: 使用 Playwright 或手动构建运行验证
- **压缩/解压操作**: 使用 Bash 创建测试文件、执行操作、验证输出
- **文件完整性**: 使用 `diff`、`md5` 验证压缩/解压后文件一致性

---

## Execution Strategy

### Execution Strategy

> **⚠️ 集成检查点（MANDATORY）**：在启动 Wave 4 之前，必须先运行 `xcodebuild build -scheme BentoZip` 确认 Waves 2+3 的所有代码编译通过。如果编译失败，先修复再启动 Wave 4。这是防止 Task 12（11 任务集成点）爆炸的关键闸门。

### Parallel Execution Waves

```
Wave 1a (Foundation - Start Immediately, MAX PARALLEL):
├── Task 1: 项目清理 + SPM 依赖 + 目录结构 [quick]
├── Task 2: 核心数据模型 + ArchiveEngine 协议 [quick]
└── Task 3: 工具函数 [quick]

Wave 1b (After Wave 1a - Sequential):
└── Task 4: AppState 中央状态管理 [quick]

Wave 2 (After Wave 1 - Core Engines, MAX PARALLEL):
├── Task 5: ZIP 压缩/解压引擎 [unspecified-high]
├── Task 6: libarchive 读取引擎 [deep]
└── Task 7: libarchive 写入引擎 [deep]

Wave 3 (After Wave 1 - UI Shell, MAX PARALLEL):
├── Task 8: 主窗口 + 空状态 + 拖放区域 [visual-engineering]
├── Task 9: 文件列表表格 + 目录导航 [visual-engineering]
├── Task 10: Inspector 参数面板 [visual-engineering]
└── Task 11: 工具栏命令 [quick]

Wave 4 (After Wave 2 & 3 - Integration):
├── Task 12: 拖入路由 + 保存位置逻辑 [unspecified-high]
├── Task 13: 拖出到 Finder [unspecified-high]
└── Task 14: 进度窗口 [visual-engineering]

Wave 5 (After Wave 4 - Tools & Polish):
├── Task 15: 通用工具（删除、添加） [unspecified-high]
└── Task 16: SwiftData 偏好设置 + 错误处理 [unspecified-high]

Wave FINAL (After ALL tasks - 4 parallel reviews):
├── Task F1: Plan compliance audit (general)
├── Task F2: Code quality review (general)
├── Task F3: Real manual QA (general)
└── Task F4: Scope fidelity check (general)
```

### Dependency Matrix

| Task | Blocked By | Blocks |
|------|-----------|--------|
| 1 | - | 2, 3 |
| 2 | 1 | 4, 5, 6, 7, 9, 10 |
| 3 | 1 | 4, 5, 6, 7, 12 |
| 4 | 1, 2, 3 | 8, 9, 10, 11, 12, 13, 14, 15 |
| 5 | 1, 2, 3 | 12, 13, 14 |
| 6 | 1, 2, 3 | 12, 13, 14 |
| 7 | 1, 2, 3 | 12, 14 |
| 8 | 1, 4 | 12 |
| 9 | 1, 2, 4 | 12, 13 |
| 10 | 1, 2, 4 | 12 |
| 11 | 1, 4 | 12, 15 |
| 12 | 5, 6, 7, 8, 9, 10, 11 | 15, 16 |
| 13 | 5, 6, 9 | 15, 16 |
| 14 | 5, 6, 7 | 15, 16 |
| 15 | 12, 13, 14 | 16 |
| 16 | 12, 13, 14, 15 | F1-F4 |

> **执行顺序**：
> - Wave 1a: Tasks 1, 2, 3 并行（Task 1 完成后 2, 3 可并行）
> - Wave 1b: Task 4（等待 1, 2, 3 全部完成）
> - Wave 2: Tasks 5, 6, 7 并行（等待 1, 2, 3 完成）
> - Wave 3: Tasks 8, 9, 10, 11 并行（等待 1, 4 完成）
> - **集成检查点**：`xcodebuild build`（等待 Waves 2+3 全部完成）
> - Wave 4: Tasks 12, 13, 14 并行（等待检查点通过）
> - Wave 5: Tasks 15, 16 顺序（15 完成后 16）

### Agent Dispatch Summary

- **Wave 1a**: Tasks 1-3 → `quick` (parallel)
- **Wave 1b**: Task 4 → `quick` (sequential after Wave 1a)
- **Wave 2**: Task 5 → `unspecified-high`, Tasks 6-7 → `deep`
- **Wave 3**: Tasks 8-10 → `visual-engineering`, Task 11 → `quick`
- **Wave 4**: Tasks 12-13 → `unspecified-high`, Task 14 → `visual-engineering`
- **Wave 5**: Tasks 15-16 → `unspecified-high`
- **FINAL**: Tasks F1-F4 → `general`

---

## TODOs

> Implementation + Test = ONE Task. Never separate.
> EVERY task MUST have: Recommended Agent Profile + Parallelization info + QA Scenarios.
> **FORMAT**: Task labels use bare numbers: `1.`, `2.`, `3.`

- [ ] 1. 项目清理 + SPM 依赖 + 目录结构

  **What to do**:
  - 删除模板文件 `Item.swift`（SwiftData 示例模型）
  - 重写 `BentoZipApp.swift`：移除 ModelContainer 初始化（后续任务添加 SwiftData）
  - 重写 `ContentView.swift`：简化为空 `VStack { Text("BentoZip") }`（后续任务构建完整 UI）
  - 通过 Xcode 添加 SPM 依赖：
    - `https://github.com/weichsel/ZIPFoundation` (ZIP Foundation)
    - `https://github.com/matteo-pacini/libarchive-for-swift` (libarchive XCFramework)
  - 创建目录结构：
    ```
    BentoZip/
    ├── Models/
    ├── Services/
    ├── ViewModels/
    ├── Views/
    │   ├── Main/
    │   ├── FileList/
    │   ├── Inspector/
    │   ├── Progress/
    │   └── Toolbar/
    └── Utilities/
    ```
  - 在项目设置中关闭 App Sandbox：
    - 检查 `BentoZip/BentoZip.entitlements` 文件是否存在
    - 如果存在：删除文件或清空内容
    - 如果不存在：检查 `BentoZip.xcodeproj/project.pbxproj` 中的 `CODE_SIGN_ENTITLEMENTS` 键，如有则移除
    - 确认 Xcode 项目设置中 "Signing & Capabilities" 标签页无 "App Sandbox" 项
  - **确认最低部署目标**：在 project.pbxproj 中设置 `MACOSX_DEPLOYMENT_TARGET = 14.0`（`.inspector()` 和 `@Observable` 的硬性要求）

  **Must NOT do**:
  - 不修改 Bundle ID
  - 不添加 RAR 或其他未确认格式的依赖
  - 不保留空的 entitlements 文件（如果存在则删除）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: 无特殊技能需求

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1a (with Tasks 2, 3)
  - **Blocks**: Tasks 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
  - **Blocked By**: None

  **References**:
  - `BentoZip/BentoZipApp.swift` - 当前 App 入口，需要移除 ModelContainer
  - `BentoZip/ContentView.swift` - 当前模板视图，需要简化
  - `BentoZip/Item.swift` - 模板 SwiftData 模型，需要删除
  - `BentoZip.xcodeproj/project.pbxproj` - Xcode 项目文件，SPM 依赖将自动修改此文件

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 项目构建成功
    Tool: Bash (xcodebuild)
    Steps:
      1. 运行 `xcodebuild build -scheme BentoZip -destination 'platform=macOS'`
      2. 检查输出包含 "BUILD SUCCEEDED"
    Expected Result: 构建成功，无编译错误
    Evidence: .omo/evidence/task-1-build-success.txt

  Scenario: SPM 依赖已解析
    Tool: Bash
    Steps:
      1. 检查 `BentoZip.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 存在
      2. 验证文件包含 "ZIPFoundation" 和 "libarchive" 条目
    Expected Result: Package.resolved 包含两个依赖的解析记录
    Evidence: .omo/evidence/task-1-spm-resolved.txt

  Scenario: 目录结构已创建
    Tool: Bash
    Steps:
      1. 运行 `ls -d BentoZip/Models BentoZip/Services BentoZip/ViewModels BentoZip/Views/Main BentoZip/Views/FileList BentoZip/Views/Inspector BentoZip/Views/Progress BentoZip/Views/Toolbar BentoZip/Utilities`
      2. 所有目录存在
    Expected Result: 所有目录存在，无错误
    Evidence: .omo/evidence/task-1-directory-structure.txt
  ```

  **Commit**: YES
  - Message: `chore: project setup, add SPM dependencies, create directory structure`
  - Files: `BentoZip.xcodeproj/`, `BentoZip/BentoZipApp.swift`, `BentoZip/ContentView.swift`, 删除 `BentoZip/Item.swift`, 新增目录

---

- [ ] 2. 核心数据模型

  **What to do**:
  - 创建 `BentoZip/Models/FileEntry.swift`:
    ```swift
    struct FileEntry: Identifiable, Hashable {
        let id = UUID()
        let url: URL           // 原始文件 URL（压缩模式）或归档内路径（解压模式）
        let name: String
        let isDirectory: Bool
        let size: Int64        // 字节，目录为 0
        let modificationDate: Date?
        let isFromArchive: Bool // true = 来自压缩包，false = 来自文件系统
        var children: [FileEntry]? // 目录的子项（仅解压模式下填充）
    }
    ```
  - 创建 `BentoZip/Models/CompressionSettings.swift`:
    ```swift
    struct CompressionSettings {
        var format: ArchiveFormat = .zip
        var compressionLevel: CompressionLevel = .normal
        var archiveName: String = ""
        var preserveDirectoryStructure: Bool = true
        var exclusionPatterns: [String] = [".DS_Store", "__MACOSX"]
        // 预留（首批不实现）
        // var password: String? = nil
        // var splitVolumeSize: Int64? = nil
    }

    enum ArchiveFormat: String, CaseIterable, Identifiable {
        case zip = "ZIP"
        case sevenZip = "7z"
        case tarGz = "tar.gz"
        var id: String { rawValue }
        var fileExtension: String { ... }
    }

    enum CompressionLevel: String, CaseIterable, Identifiable {
        case none = "无压缩"
        case fast = "快速"
        case normal = "标准"
        case best = "最佳"
        var id: String { rawValue }
    }
    ```
  - 创建 `BentoZip/Models/ArchiveMode.swift`:
    ```swift
    enum ArchiveMode {
        case empty           // 无文件
        case compress        // 准备压缩
        case browseArchive   // 浏览/解压压缩包
    }
    ```
  - 创建 `BentoZip/Models/AppPreferences.swift`（SwiftData @Model）:
    ```swift
    @Model
    final class AppPreferences {
        var defaultFormat: String           // ArchiveFormat.rawValue
        var defaultCompressionLevel: String // CompressionLevel.rawValue
        var exclusionPatterns: [String]
        var lastSaveDirectory: String?
        var recentArchives: [String]        // 最近操作的归档路径
    }
    ```
  - 创建 `BentoZip/Models/ArchiveEngine.swift`（协议定义，供 Tasks 5/6/7 实现）：
    ```swift
    protocol ArchiveEngine {
        func listEntries(in archiveURL: URL) async throws -> [FileEntry]
        func extract(archiveURL: URL, entries: [FileEntry]?, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws
        func create(from sourceURLs: [URL], to archiveURL: URL, settings: CompressionSettings, progress: @escaping (Double) -> Void) async throws
        func removeEntries(from archiveURL: URL, entries: [FileEntry]) async throws
        func addEntries(to archiveURL: URL, from sourceURLs: [URL], progress: @escaping (Double) -> Void) async throws
    }
    ```
  - 定义压缩级别映射常量（供所有引擎使用）：
    ```swift
    // CompressionLevel → ZIP Foundation 映射
    extension CompressionLevel {
        var zipCompressionMethod: ZIPFoundation.CompressionMethod {
            switch self {
            case .none: return .none
            case .fast, .normal, .best: return .deflate
            }
        }
    }
    // CompressionLevel → libarchive 映射
    // .none → 不设置压缩 filter（tar 仅归档）
    // .fast → ZSTD level 1 或 gzip level 1
    // .normal → ZSTD level 6 或 gzip level 6
    // .best → ZSTD level 19 或 gzip level 9
    ```

  **Must NOT do**:
  - 不实现密码字段（预留注释即可）
  - 不实现分卷字段
  - 不添加 RAR 格式到 ArchiveFormat
  - 不实现 ArchiveEngine 协议的具体方法（仅定义接口）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1a (with Tasks 1, 3)
  - **Blocks**: Tasks 4, 5, 6, 7, 9, 10
  - **Blocked By**: Task 1 (目录结构)

  **References**:
  - `BentoZip/Models/` - 目标目录（Task 1 创建）
  - ZIP Foundation `Entry` 类型 - FileEntry 需要兼容 ZIP Foundation 的条目信息
  - libarchive `archive_entry` 结构 - FileEntry 需要能表示 libarchive 读取的条目

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 模型编译通过
    Tool: Bash (xcodebuild)
    Steps:
      1. 运行 `xcodebuild build -scheme BentoZip -destination 'platform=macOS'`
      2. 检查无编译错误
    Expected Result: BUILD SUCCEEDED
    Evidence: .omo/evidence/task-2-models-build.txt

  Scenario: ArchiveFormat 枚举完整
    Tool: Bash (grep)
    Steps:
      1. 检查 `BentoZip/Models/CompressionSettings.swift` 包含 zip, sevenZip, tarGz 三个 case
      2. 检查 fileExtension 计算属性返回正确扩展名
    Expected Result: 三种格式均有定义
    Evidence: .omo/evidence/task-2-formats-complete.txt
  ```

  **Commit**: YES
  - Message: `feat: add core models and ArchiveEngine protocol`

---

- [ ] 3. 工具函数

  **What to do**:
  - 创建 `BentoZip/Utilities/PathUtils.swift`:
    - `commonParentDirectory(of urls: [URL]) -> URL?` - 计算 URL 数组的公共父目录
    - `allShareParentDirectory(_ urls: [URL]) -> Bool` - 判断所有 URL 是否共享同一直接父目录（即公共父目录 == 每个 URL 的 deletingLastPathComponent）
    - `uniqueFileURL(for proposedURL: URL) -> URL` - 如果文件已存在，自动添加序号（如 archive.zip → archive 2.zip）
    - `fileExtension(for format: ArchiveFormat) -> String`
  - 创建 `BentoZip/Utilities/FileUtils.swift`:
    - `fileSize(at url: URL) -> Int64` - 获取文件/目录大小
    - `fileModificationDate(at url: URL) -> Date?`
    - `isDirectory(at url: URL) -> Bool`
    - `displayName(for url: URL) -> String` - 获取显示名称
    - `enumerateDirectory(at url: URL) -> [URL]` - 列出目录内容
    - `directorySize(at url: URL) -> Int64` - 递归计算目录大小

  **Must NOT do**:
  - 不实现文件拷贝/移动（由 Services 层处理）
  - 不添加网络相关工具

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1a (with Tasks 1, 2)
  - **Blocks**: Tasks 4, 5, 6, 7, 12
  - **Blocked By**: Task 1

  **References**:
  - `BentoZip/Utilities/` - 目标目录
  - `Foundation.FileManager` - 所有文件操作基于 FileManager.default
  - `BentoZip/Models/CompressionSettings.swift:ArchiveFormat` - fileExtension 函数需要引用此枚举

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 公共父目录计算正确
    Tool: Bash (swift REPL or test script)
    Steps:
      1. 创建测试目录结构: /tmp/bentozip-test/a/file1.txt, /tmp/bentozip-test/a/file2.txt
      2. 调用 allShareParentDirectory([url1, url2]) → true
      3. 创建 /tmp/bentozip-test/b/file3.txt
      4. 调用 allShareParentDirectory([url1, url3]) → false
    Expected Result: 同目录返回 true，不同目录返回 false
    Evidence: .omo/evidence/task-3-parent-dir.txt

  Scenario: 唯一文件名生成
    Tool: Bash
    Steps:
      1. 创建 /tmp/bentozip-test/archive.zip
      2. 调用 uniqueFileURL(for: URL("archive.zip"))
      3. 返回 URL 路径包含 "archive 2.zip" 或类似序号
    Expected Result: 已存在文件名时自动添加序号
    Evidence: .omo/evidence/task-3-unique-name.txt
  ```

  **Commit**: YES
  - Message: `feat: add utility functions (PathUtils, FileUtils)`

---

- [ ] 4. AppState 中央状态管理

  **What to do**:
  - 创建 `BentoZip/ViewModels/AppState.swift`:
    ```swift
    @Observable
    class AppState {
        // ⚠️ 不要用 final —— @Observable 宏转换 + final 在某些 Swift 版本下有边缘情况
        // AppState 不需要子类化，但 final 可能与宏冲突
        // 当前模式
        var mode: ArchiveMode = .empty

        // 文件列表
        var fileEntries: [FileEntry] = []

        // 目录导航路径（压缩模式下的子目录导航）
        var navigationPath: [FileEntry] = []

        // 当前显示的条目（考虑导航路径）
        var displayedEntries: [FileEntry] {
            // 如果有导航路径，返回最深层目录的子项
            // 否则返回顶层条目
        }

        // 压缩设置
        var compressionSettings = CompressionSettings()

        // Inspector 可见性
        var showInspector: Bool = false

        // 进度状态
        var isOperationInProgress: Bool = false
        var operationProgress: Double = 0.0
        var operationDescription: String = ""

        // 源归档 URL（解压模式）
        var sourceArchiveURL: URL?

        // 操作结果
        var lastError: String?

        // 方法
        func loadFiles(from urls: [URL]) { ... }
        func loadArchive(from url: URL) { ... }
        func navigateInto(_ entry: FileEntry) { ... }
        func navigateBack(to level: Int) { ... }
        func removeEntries(at offsets: IndexSet) { ... }
        func addEntries(from urls: [URL]) { ... }
        func reset() { ... }
    }
    ```
  - `loadFiles` 方法：将 URL 数组转换为 FileEntry 数组，设置 mode = .compress
  - `loadArchive` 方法：预留接口，使用依赖注入模式：
    ```swift
    // 引擎引用（由外部注入，Task 5/6 实现后赋值）
    var archiveEngine: ArchiveEngine?

    func loadArchive(from url: URL) {
        // 设置 mode，实际读取由引擎执行
        mode = .browseArchive
        sourceArchiveURL = url
        // 注意：实际的 listEntries 调用由 Task 12 的集成逻辑触发
        // 此处仅设置状态，不执行异步操作
    }
    ```
  - `navigateInto`：将目录 entry 推入 navigationPath
  - `navigateBack`：弹出 navigationPath 到指定层级
  - `displayedEntries`：计算属性，根据 navigationPath 返回当前层级的条目

  **Must NOT do**:
  - 不在此任务中实现实际的压缩/解压逻辑（仅状态管理）
  - 不实现 SwiftData 持久化（Task 16）
  - loadArchive 方法体可以留空或仅设置 mode

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: NO (sequential after Wave 1a)
  - **Parallel Group**: Wave 1b (after Tasks 1, 2, 3 complete)
  - **Blocks**: Tasks 8, 9, 10, 11, 12, 13, 14, 15
  - **Blocked By**: Tasks 1, 2, 3

  **References**:
  - `BentoZip/ViewModels/` - 目标目录
  - `BentoZip/Models/FileEntry.swift` - FileEntry 类型定义
  - `BentoZip/Models/CompressionSettings.swift` - CompressionSettings 类型
  - `BentoZip/Models/ArchiveMode.swift` - ArchiveMode 枚举
  - `BentoZip/Utilities/FileUtils.swift` - 文件元数据获取函数

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: AppState 状态切换
    Tool: Bash (xcodebuild)
    Steps:
      1. 构建项目确认编译通过
      2. 验证 AppState 初始 mode 为 .empty
      3. 调用 loadFiles 后 mode 变为 .compress
    Expected Result: 编译通过，状态切换逻辑正确
    Evidence: .omo/evidence/task-4-appstate-build.txt

  Scenario: 目录导航路径
    Tool: Bash
    Steps:
      1. 创建包含嵌套目录的 FileEntry 数组
      2. 调用 navigateInto 推入目录
      3. 验证 displayedEntries 返回子目录内容
      4. 调用 navigateBack 返回上级
    Expected Result: 导航路径正确维护，displayedEntries 响应变化
    Evidence: .omo/evidence/task-4-navigation.txt
  ```

  **Commit**: YES
  - Message: `feat: add AppState central state management`
  - Files: `BentoZip/ViewModels/`

---

- [ ] 5. ZIP 压缩/解压引擎

  **What to do**:
  - 创建 `BentoZip/Services/ZIPEngine.swift`:
    - 实现 `ArchiveEngine` 协议（定义见 `BentoZip/Models/ArchiveEngine.swift`，Task 2 创建）：
      - `ZIPEngine: ArchiveEngine` 实现：
      - `listEntries`: 使用 `Archive(url:accessMode: .read)` 遍历 entries，构建 FileEntry 数组，识别目录结构
      - `extract`: 使用 `archive.extract(entry, to:)` 逐个提取，通过 Progress 回调报告进度
      - `create`: 使用 `FileManager.zipItem(at:to:compressionMethod:)` 或逐条目添加以获取进度
      - `removeEntries`: 创建新 Archive，跳过要删除的条目，写入新文件
      - `addEntries`: 使用 `Archive(url:accessMode: .update)` 添加新条目
    - 压缩级别映射：使用 Task 2 定义的 `CompressionLevel.zipCompressionMethod` 扩展
    - 进度追踪：使用 ZIP Foundation 的 Progress 对象，通过 KVO 观察 fractionCompleted

  **Must NOT do**:
  - 不实现密码保护
  - 不实现分卷
  - 不处理 ZIP64 特殊逻辑（ZIP Foundation 自动处理）

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 6, 7)
  - **Blocks**: Tasks 12, 13, 14
  - **Blocked By**: Tasks 1, 2, 3

  **References**:
  - ZIP Foundation README: `zipItem`, `unzipItem`, `Archive`, `archive.extract()` API
  - ZIP Foundation Progress: 通过 `Progress` 参数追踪，KVO 观察 `fractionCompleted`
  - `BentoZip/Models/FileEntry.swift` - FileEntry 结构
  - `BentoZip/Models/CompressionSettings.swift` - CompressionLevel 映射
  - `BentoZip/Services/` - 目标目录

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: ZIP 创建和提取往返测试
    Tool: Bash
    Steps:
      1. 创建测试目录 /tmp/bentozip-zip-test/ 包含 3 个文件（1KB, 10KB, 100KB）
      2. 调用 ZIPEngine.create() 创建 archive.zip
      3. 验证 archive.zip 存在且大小 > 0
      4. 调用 ZIPEngine.listEntries() 验证包含 3 个条目
      5. 调用 ZIPEngine.extract() 到 /tmp/bentozip-zip-extract/
      6. 使用 diff -r 比较原始目录和提取目录
    Expected Result: 文件内容完全一致
    Evidence: .omo/evidence/task-5-zip-roundtrip.txt

  Scenario: ZIP 条目删除
    Tool: Bash
    Steps:
      1. 创建包含 3 个文件的 ZIP
      2. 调用 removeEntries 删除其中一个
      3. 调用 listEntries 验证只剩 2 个
    Expected Result: 删除后条目数正确
    Evidence: .omo/evidence/task-5-zip-remove.txt

  Scenario: 进度回调触发
    Tool: Bash
    Steps:
      1. 创建包含多个文件的测试目录
      2. 调用 create() 并记录 progress 回调值
      3. 验证回调被多次触发且值递增（0 < ... < 1.0）
    Expected Result: 进度值单调递增，最终接近 1.0
    Evidence: .omo/evidence/task-5-zip-progress.txt

  Scenario: 非 ASCII 文件名往返
    Tool: Bash
    Steps:
      1. 创建包含中文/日文文件名的测试目录（如 "文档.txt", "ファイル.pdf"）
      2. 调用 ZIPEngine.create() 创建 archive.zip
      3. 调用 ZIPEngine.extract() 提取
      4. 验证文件名完整保留，内容一致
    Expected Result: 非 ASCII 文件名正确编码和解码
    Evidence: .omo/evidence/task-5-zip-unicode.txt
  ```

  **Commit**: YES (groups with Tasks 6, 7)
  - Message: `feat: add compression engines (ZIP + libarchive)`

---

- [ ] 6. libarchive 读取引擎

  **What to do**:
  - 创建 `BentoZip/Services/LibArchiveReader.swift`:
    - 实现 `ArchiveEngine` 协议（定义见 Task 2）：
    - `import libarchive`（C API）
    - 实现 `listEntries(in archiveURL: URL) async throws -> [FileEntry]`：
      - 使用 `archive_read_new()` 创建归档指针
      - 调用 `archive_read_support_format_all()` 和 `archive_read_support_filter_all()` 启用所有格式
      - 使用 `archive_read_open_filename()` 打开归档
      - 循环 `archive_read_next_header()` 遍历条目
      - 从 `archive_entry` 提取：pathname, size, filetype, mtime
      - 构建 FileEntry 数组，识别目录结构（通过路径分隔符 `/` 构建树）
      - 调用 `archive_read_free()` 清理
    - 实现 `extractEntry(from archiveURL: URL, entryPath: String, to destinationURL: URL) async throws`：
      - 打开归档，定位到目标条目
      - 使用 `archive_read_data_into_fd()` 或 `archive_read_data()` 提取数据
      - 写入目标文件
    - 实现 `extractAll(from archiveURL: URL, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws`：
      - 使用 `listEntries` 预计算的总大小（不需要二次遍历）
      - 提取时累计已处理字节数，计算进度比例
    - 辅助函数：
      - `detectFormat(of url: URL) -> ArchiveFormat?` - 通过 magic bytes 或扩展名检测格式
      - 错误处理：将 libarchive 的 `archive_error_string()` 转换为 Swift Error
      - `extractEntry(from archiveURL: URL, entryPath: String, to destinationURL: URL) async throws` - 提取单个条目（供 Task 13 拖出预缓存使用）
    - **性能优化**：`listEntries` 遍历时预计算每个条目的大小和路径信息，缓存到 FileEntry 中。`extractAll` 不需要二次遍历——直接使用 `listEntries` 的缓存结果计算总大小。

  **Must NOT do**:
  - 不实现写入功能（Task 7 负责）
  - 不处理加密/密码保护的归档（首批不支持）
  - 不修改 libarchive 源码

  > **⚠️ C 内存管理规则（CRITICAL）**：
  > 1. `archive_read_next_header()` 返回的 `archive_entry*` **仅在下一次调用前有效**。必须在下次调用前拷贝所有需要的数据（pathname, size, mtime 等）。
  > 2. `archive_entry_pathname()` 返回 C 字符串——必须立即转为 Swift String：`String(cString: archive_entry_pathname(entry))`
  > 3. `archive_read_free()` 必须在所有路径（包括错误路径）中调用——使用 `defer` 块：
  >    ```swift
  >    let archive = archive_read_new()!
  >    defer { archive_read_free(archive) }
  >    ```
  > 4. 不要手动 `free()` `archive_entry` 指针——它由 libarchive 内部管理
  > 5. 所有 libarchive 函数调用返回值必须检查（`ARCHIVE_OK`, `ARCHIVE_WARN`, `ARCHIVE_FAILED`, `ARCHIVE_FATAL`）

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: libarchive C API 互操作需要深入理解内存管理和指针操作
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 7)
  - **Blocks**: Tasks 12, 13, 14
  - **Blocked By**: Tasks 1, 2, 3

  **References**:
  - libarchive Wiki Examples: https://github.com/libarchive/libarchive/wiki/Examples
  - `archive_read_new`, `archive_read_support_format_all`, `archive_read_open_filename`, `archive_read_next_header`, `archive_entry_pathname`, `archive_entry_size`, `archive_read_free`
  - `BentoZip/Models/FileEntry.swift` - FileEntry 结构
  - `BentoZip/Services/` - 目标目录
  - libarchive-for-swift SPM package: `import libarchive`

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 读取 tar.gz 归档
    Tool: Bash
    Steps:
      1. 使用系统 tar 创建测试归档: `tar czf /tmp/test.tar.gz -C /tmp/bentozip-test .`
      2. 调用 LibArchiveReader.listEntries() 读取
      3. 验证返回的 FileEntry 数组包含正确的文件名和大小
    Expected Result: 条目列表与原始目录结构匹配
    Evidence: .omo/evidence/task-6-targz-read.txt

  Scenario: 读取 7z 归档
    Tool: Bash
    Steps:
      1. 使用 7z 命令创建测试归档（如系统有 7z）或使用预置测试文件
      2. 调用 LibArchiveReader.listEntries() 读取
      3. 验证条目列表正确
    Expected Result: 7z 归档内容正确读取
    Evidence: .omo/evidence/task-6-7z-read.txt

  Scenario: 提取 tar.gz 到目录
    Tool: Bash
    Steps:
      1. 创建包含嵌套目录和多种文件的 tar.gz
      2. 调用 extractAll() 到目标目录
      3. 使用 diff -r 比较原始内容和提取内容
    Expected Result: 文件内容完全一致
    Evidence: .omo/evidence/task-6-targz-extract.txt

  Scenario: 格式检测
    Tool: Bash
    Steps:
      1. 准备 .zip, .tar.gz, .7z 各一个测试文件
      2. 调用 detectFormat() 分别检测
      3. 验证返回正确的 ArchiveFormat
    Expected Result: 三种格式均正确识别
    Evidence: .omo/evidence/task-6-format-detect.txt
  ```

  **Commit**: YES (groups with Tasks 5, 7)

---

- [ ] 7. libarchive 写入引擎

  **What to do**:
  - 创建 `BentoZip/Services/LibArchiveWriter.swift`:
    - 实现 `ArchiveEngine` 协议（定义见 Task 2）：
    - `import libarchive`
    - 实现 `createArchive(from sourceURLs: [URL], to archiveURL: URL, format: ArchiveFormat, settings: CompressionSettings, progress: @escaping (Double) -> Void) async throws`：
      - 根据 format 选择：
        - `.tarGz`: `archive_write_set_format_ustar()` + `archive_write_add_filter_gzip()`
        - `.sevenZip`: `archive_write_set_format_7zip()`
      - 调用 `archive_write_open_filename()` 打开输出文件
      - 调用 `archive_write_set_bytes_in_last_block(archive, 1)` 避免 10240 字节填充
      - 递归遍历 sourceURLs，对每个文件：
        - 创建 `archive_entry_new()`
        - 设置 pathname, size, filetype, permissions, mtime
        - 调用 `archive_write_header()`
        - 读取文件数据，调用 `archive_write_data()` 写入
        - 更新进度回调
      - 调用 `archive_write_free()` 清理
    - 实现 `createTarGz(...)` 和 `create7z(...)` 作为内部辅助方法
    - 排除模式处理：在遍历文件时，检查 exclusionPatterns，跳过匹配的文件
    - 目录结构处理：根据 `preserveDirectoryStructure` 设置决定路径前缀

  **Must NOT do**:
  - 不实现分卷写入
  - 不实现加密写入
  - 不处理符号链接特殊逻辑（首批按普通文件处理）

  > **⚠️ C 内存管理规则（CRITICAL）**：
  > 1. `archive_write_new()` 必须配对 `archive_write_free()`——使用 `defer`
  > 2. `archive_entry_new()` 创建的条目必须配对 `archive_entry_free()`——使用 `defer`
  > 3. `archive_write_header()` 返回写入的字节数或错误码——必须检查 `< 0` 表示错误
  > 4. `archive_write_data()` 返回实际写入的字节数——必须与预期大小比较，不一致时报告错误
  > 5. `archive_write_set_format_7zip()` 的 7z 写入在 libarchive 中是实验性的——QA 必须用 `7z t` 验证输出
  > 6. `archive_write_set_bytes_in_last_block(archive, 1)` 用于避免 10240 字节填充问题——但不同 libarchive 版本行为可能不同，需验证实际输出

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: libarchive C API 写入操作需要精确的内存管理和错误处理
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6)
  - **Blocks**: Tasks 12, 14
  - **Blocked By**: Tasks 1, 2, 3

  **References**:
  - libarchive Wiki Examples (Writing): https://github.com/libarchive/libarchive/wiki/Examples
  - `archive_write_new`, `archive_write_set_format_*`, `archive_write_add_filter_*`, `archive_write_open_filename`, `archive_write_header`, `archive_write_data`, `archive_write_free`
  - `archive_write_set_bytes_in_last_block(archive, 1)` - 避免填充问题
  - `BentoZip/Models/CompressionSettings.swift` - exclusionPatterns, preserveDirectoryStructure
  - `BentoZip/Utilities/FileUtils.swift` - enumerateDirectory, fileSize

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 创建 tar.gz 归档
    Tool: Bash
    Steps:
      1. 创建测试目录包含多个文件和子目录
      2. 调用 LibArchiveWriter.createArchive() 创建 .tar.gz
      3. 使用系统 `tar tzf` 验证归档内容
      4. 使用系统 `tar xzf` 提取并 diff 比较
    Expected Result: 归档可被系统 tar 正确解压，内容一致
    Evidence: .omo/evidence/task-7-targz-create.txt

  Scenario: 创建 7z 归档
    Tool: Bash
    Steps:
      1. 创建测试目录
      2. 调用 createArchive() 创建 .7z
      3. 使用 LibArchiveReader.listEntries() 验证内容
      4. 提取并比较
      5. **如果系统有 7z 命令**：运行 `7z t archive.7z` 验证归档完整性
    Expected Result: 7z 归档内容正确，可被 libarchive 读取，通过 7z 完整性测试
    Evidence: .omo/evidence/task-7-7z-create.txt

  Scenario: 排除模式生效
    Tool: Bash
    Steps:
      1. 创建包含 .DS_Store 文件的测试目录
      2. 设置 exclusionPatterns = [".DS_Store"]
      3. 创建归档
      4. 验证归档中不包含 .DS_Store
    Expected Result: 排除的文件不出现在归档中
    Evidence: .omo/evidence/task-7-exclusion.txt
  ```

  **Commit**: YES (groups with Tasks 5, 6)
  - Message: `feat: add compression engines (ZIP + libarchive)`
  - Files: `BentoZip/Services/`

---

- [ ] 8. 主窗口 + 空状态 + 拖放区域

  **What to do**:
  - 重写 `BentoZip/ContentView.swift`:
    - 使用 `@Environment(AppState.self)` 获取状态
    - 根据 `appState.mode` 切换显示：
      - `.empty` → `EmptyStateView`
      - `.compress` / `.browseArchive` → `FileListView`（Task 9 实现）
    - 整体布局：`VStack` 或 `ZStack`，为后续 inspector 和 toolbar 预留位置
  - 创建 `BentoZip/Views/Main/EmptyStateView.swift`:
    - 居中显示大图标（如 `Image(systemName: "doc.zipper")`）和提示文本
    - 提示文本："拖放文件或文件夹到此处进行压缩，或拖放压缩包进行解压"
    - 添加 `.dropDestination(for: URL.self)` 修饰符：
      - 接收拖入的 URL 数组
      - 判断拖入的是普通文件/目录还是压缩包（通过扩展名）
      - 压缩包 → 调用 `appState.loadArchive(from: url)`
      - 普通文件/目录 → 调用 `appState.loadFiles(from: urls)`
    - 拖放悬停时视觉反馈（边框高亮或背景色变化）
  - 重写 `BentoZipApp.swift`:
    - 添加 `@State private var appState = AppState()`
    - ContentView 添加 `.environment(appState)`
    - 添加 `WindowGroup(id: "progress")` Scene（Task 14 实现内容）
    - 添加 `.commands { InspectorCommands() }` 支持 inspector 快捷键

  **Must NOT do**:
  - 不实现 FileListView（Task 9）
  - 不实现 Inspector 内容（Task 10）
  - 不实现 Toolbar 按钮（Task 11）
  - 不实现进度窗口内容（Task 14）

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: UI 布局和视觉效果
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 9, 10, 11)
  - **Blocks**: Task 12
  - **Blocked By**: Tasks 1, 4

  **References**:
  - `BentoZip/ContentView.swift` - 当前文件，需要重写
  - `BentoZip/BentoZipApp.swift` - App 入口，需要添加 environment 和 WindowGroup
  - `BentoZip/ViewModels/AppState.swift` - AppState 类型
  - SwiftUI `.dropDestination(for: URL.self)` - 文件拖入 API
  - SwiftUI `.inspector()` - 右侧面板修饰符
  - SwiftUI `WindowGroup(id:)` - 二级窗口定义

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 空状态显示
    Tool: Bash (xcodebuild + 手动验证)
    Steps:
      1. 构建并运行应用
      2. 验证主窗口显示居中的图标和提示文本
      3. 验证无左侧边栏
    Expected Result: 空状态视图正确显示
    Evidence: .omo/evidence/task-8-empty-state.txt

  Scenario: 拖入文件触发状态切换
    Tool: Bash
    Steps:
      1. 构建运行应用
      2. 从 Finder 拖入一个文件到窗口
      3. 验证 appState.mode 从 .empty 变为 .compress
    Expected Result: 拖入后状态正确切换
    Evidence: .omo/evidence/task-8-drop-file.txt

  Scenario: 拖入压缩包触发解压模式
    Tool: Bash
    Steps:
      1. 构建运行应用
      2. 拖入一个 .zip 文件
      3. 验证 appState.mode 变为 .browseArchive
    Expected Result: 压缩包拖入触发解压浏览模式
    Evidence: .omo/evidence/task-8-drop-archive.txt
  ```

  **Commit**: YES (groups with Tasks 9, 10, 11)
  - Message: `feat: add UI shell (main window, file list, inspector, toolbar)`

---

- [ ] 9. 文件列表表格 + 目录导航

  **What to do**:
  - 创建 `BentoZip/Views/FileList/FileListView.swift`:
    - 使用 SwiftUI `Table` 组件（macOS 原生表格）
    - 列定义：
      - 名称（带图标：文件/文件夹图标，`Label` 组件）
      - 大小（格式化字节数：KB, MB, GB）
      - 类型（文件扩展名或"文件夹"）
      - 修改日期（格式化日期）
    - 数据源：`appState.displayedEntries`
    - 双击/点击目录条目 → 调用 `appState.navigateInto(entry)`
    - 支持多选（`Table(selection:)`）
  - 创建 `BentoZip/Views/FileList/BreadcrumbView.swift`:
    - 显示当前导航路径的面包屑
    - 格式：`根目录 > 子目录1 > 子目录2`
    - 每个层级可点击，调用 `appState.navigateBack(to: level)`
    - 仅在 `navigationPath` 非空时显示
  - 文件图标逻辑：
    - 目录：`Image(systemName: "folder.fill")`
    - 文件：根据扩展名选择图标（通用 `doc` 图标即可）
  - 排序：默认按名称排序，目录在前

  **Must NOT do**:
  - 不实现右键菜单（后续增强）
  - 不实现拖拽排序
  - 不实现列宽持久化

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: Table 组件布局和视觉效果
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 8, 10, 11)
  - **Blocks**: Tasks 12, 13
  - **Blocked By**: Tasks 1, 2, 4

  **References**:
  - `BentoZip/Views/FileList/` - 目标目录
  - `BentoZip/ViewModels/AppState.swift:displayedEntries` - 数据源
  - `BentoZip/ViewModels/AppState.swift:navigateInto()` - 目录导航
  - `BentoZip/Models/FileEntry.swift` - 条目数据结构
  - SwiftUI `Table` 文档 - macOS 原生表格组件
  - Finder 列表模式 - 视觉参考

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 文件列表正确显示
    Tool: Bash (xcodebuild + 手动验证)
    Steps:
      1. 准备包含多个文件和子目录的测试数据
      2. 通过 AppState.loadFiles() 加载
      3. 验证 Table 显示所有条目，列内容正确
    Expected Result: 名称、大小、类型、日期列均正确显示
    Evidence: .omo/evidence/task-9-file-list.txt

  Scenario: 目录导航进入和返回
    Tool: Bash
    Steps:
      1. 加载包含嵌套目录的文件列表
      2. 点击目录条目 → 验证进入子目录视图
      3. 点击面包屑上级 → 验证返回上级目录
    Expected Result: 导航路径正确维护，面包屑更新
    Evidence: .omo/evidence/task-9-navigation.txt
  ```

  **Commit**: YES (groups with Tasks 8, 10, 11)

---

- [ ] 10. Inspector 参数面板

  **What to do**:
  - 创建 `BentoZip/Views/Inspector/CompressionSettingsView.swift`:
    - 使用 `Form` 布局
    - **基础参数区域**：
      - 格式选择：`Picker` 绑定 `settings.format`（ZIP / 7z / tar.gz）
      - 压缩级别：`Picker` 绑定 `settings.compressionLevel`（无/快/标准/最佳）
      - 压缩包名称：`TextField` 绑定 `settings.archiveName`
    - **高级参数区域**（使用 `DisclosureGroup` 折叠）：
      - 保留目录结构：`Toggle` 绑定 `settings.preserveDirectoryStructure`
      - 排除模式：`List` + `TextField` 管理 `settings.exclusionPatterns`
        - 添加/删除排除模式的按钮
        - 默认值：[".DS_Store", "__MACOSX"]
    - **预留区域**（灰色/禁用状态）：
      - 密码保护：`TextField` + `SecureField`（禁用，标注"即将推出"）
      - 分卷大小：`TextField`（禁用，标注"即将推出"）
  - 在 ContentView 中添加 `.inspector(isPresented: $appState.showInspector)` 修饰符
  - Inspector 内容使用 `CompressionSettingsView`
  - Inspector 宽度：`.inspectorColumnWidth(min: 250, ideal: 300, max: 400)`

  **Must NOT do**:
  - 不实现密码保护功能（仅 UI 占位）
  - 不实现分卷功能（仅 UI 占位）
  - 不实现参数验证逻辑（后续任务）

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: Form 布局和参数面板视觉设计
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 8, 9, 11)
  - **Blocks**: Task 12
  - **Blocked By**: Tasks 1, 2, 4

  **References**:
  - `BentoZip/Views/Inspector/` - 目标目录
  - `BentoZip/Models/CompressionSettings.swift` - 绑定的数据模型
  - SwiftUI `.inspector()` 文档 - 右侧面板 API
  - SwiftUI `Form` + `Picker` + `Toggle` - 表单组件
  - `.inspectorColumnWidth(min:ideal:max:)` - 宽度控制

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Inspector 面板显示和隐藏
    Tool: Bash (xcodebuild + 手动验证)
    Steps:
      1. 构建运行应用
      2. 触发 inspector 显示（通过 toolbar 按钮或快捷键）
      3. 验证右侧面板滑出，包含所有参数控件
      4. 再次触发隐藏
    Expected Result: Inspector 正确显示/隐藏，宽度在 250-400 范围内
    Evidence: .omo/evidence/task-10-inspector-toggle.txt

  Scenario: 参数绑定正确
    Tool: Bash
    Steps:
      1. 在 Inspector 中修改各参数
      2. 验证 AppState.compressionSettings 同步更新
      3. 切换格式选择，验证 UI 响应
    Expected Result: 所有控件与数据模型双向绑定正确
    Evidence: .omo/evidence/task-10-bindings.txt
  ```

  **Commit**: YES (groups with Tasks 8, 9, 11)

---

- [ ] 11. 工具栏命令

  **What to do**:
  - 创建 `BentoZip/Views/Toolbar/ToolbarCommands.swift`:
    - 定义 `.toolbar { }` 内容，根据 `appState.mode` 动态显示/隐藏按钮
    - **通用按钮**（所有模式可用，空状态禁用）：
      - 添加文件：`Button` + `Image(systemName: "plus")` → 触发 NSOpenPanel 选择文件
      - 删除选中项：`Button` + `Image(systemName: "trash")` → 调用 `appState.removeEntries()`
    - **压缩模式按钮**（仅 `.compress` 模式可用）：
      - 压缩：`Button` + `Image(systemName: "doc.zipper")` → 触发压缩操作（Task 12 实现）
      - 格式快速选择：`Picker` 绑定 `settings.format`
    - **解压模式按钮**（仅 `.browseArchive` 模式可用）：
      - 解压全部：`Button` + `Image(systemName: "square.and.arrow.down")` → 触发解压操作
      - 解压选中：`Button` → 仅解压选中的条目
    - **视图按钮**（所有模式可用）：
      - Inspector 切换：`Button` + `Image(systemName: "sidebar.trailing")` → toggle `appState.showInspector`
    - 按钮放置：
      - `.navigation` 区域：面包屑相关
      - `.primaryAction` 区域：操作按钮（压缩、解压、添加、删除）
      - `.secondaryAction` 区域：视图切换（Inspector）
  - 在 ContentView 中添加 `.toolbar { }` 修饰符
  - 按钮禁用逻辑：使用 `.disabled()` 根据 mode 和选中状态控制

  **Must NOT do**:
  - 不实现实际的压缩/解压操作逻辑（仅触发入口，Task 12 实现）
  - 不实现自定义键盘快捷键（系统默认即可）
  - 不实现菜单命令（仅工具栏）

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Toolbar 布局相对简单
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 8, 9, 10)
  - **Blocks**: Tasks 12, 15
  - **Blocked By**: Tasks 1, 4

  **References**:
  - `BentoZip/Views/Toolbar/` - 目标目录
  - `BentoZip/ViewModels/AppState.swift:mode` - 按钮启用/禁用依据
  - SwiftUI `.toolbar` + `ToolbarItem` + `ToolbarItemGroup` - 工具栏 API
  - `NSOpenPanel` - 文件选择对话框（添加文件按钮）
  - macOS HIG Toolbar - 视觉参考

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 工具栏按钮状态正确
    Tool: Bash (xcodebuild + 手动验证)
    Steps:
      1. 空状态：验证压缩/解压按钮禁用，添加按钮可用
      2. 拖入文件（压缩模式）：验证压缩按钮启用
      3. 拖入压缩包（解压模式）：验证解压按钮启用
    Expected Result: 按钮根据模式正确启用/禁用
    Evidence: .omo/evidence/task-11-toolbar-states.txt

  Scenario: Inspector 切换按钮
    Tool: Bash
    Steps:
      1. 点击 Inspector 切换按钮
      2. 验证右侧面板显示
      3. 再次点击
      4. 验证面板隐藏
    Expected Result: Inspector 正确切换
    Evidence: .omo/evidence/task-11-inspector-toggle.txt
  ```

  **Commit**: YES (groups with Tasks 8, 9, 10)
  - Message: `feat: add UI shell (main window, file list, inspector, toolbar)`
  - Files: `BentoZip/Views/`, `BentoZip/ContentView.swift`, `BentoZip/BentoZipApp.swift`

---

- [ ] 12. 拖入路由 + 保存位置逻辑 + 压缩/解压操作

  **What to do**:
  - 创建 `BentoZip/Services/FormatDetector.swift`:
    - `detectFormat(of url: URL) -> ArchiveFormat?` - 通过扩展名和 magic bytes 检测归档格式
    - 支持的扩展名：.zip, .7z, .tar.gz, .tgz, .tar.bz2, .tar.xz
    - Magic bytes 检测：ZIP (PK\x03\x04), 7z (7z\xBC\xAF\x27\x1C), gzip (\x1F\x8B)
  - 创建 `BentoZip/Services/CompressionCoordinator.swift`:
    - `compress(entries: [FileEntry], settings: CompressionSettings, appState: AppState) async throws`：
      1. 确定保存位置（调用 `determineSaveLocation()`）
      2. 根据 `settings.format` 选择引擎：
         - `.zip` → `ZIPEngine`
         - `.sevenZip` / `.tarGz` → `LibArchiveWriter`
      3. 设置 `appState.isOperationInProgress = true`
      4. 打开进度窗口（通过 `openWindow(id: "progress")`）
      5. 执行压缩，传入进度回调
      6. 完成后处理：
         - **成功**：`appState.isOperationInProgress = false`，关闭进度窗口
           - 如果压缩模式：切换到 `.browseArchive` 模式，加载新创建的归档内容
           - 记录归档路径到 `AppPreferences.recentArchives`
         - **失败**：`appState.isOperationInProgress = false`，关闭进度窗口
           - 设置 `appState.lastError = error.localizedDescription`
           - 删除部分生成的归档文件（如果存在）
           - 保持在当前模式，不切换
      7. 关闭进度窗口
    - `extract(archiveURL: URL, entries: [FileEntry]?, destinationURL: URL?, appState: AppState) async throws`：
      1. 确定解压目标位置
      2. 根据归档格式选择引擎
      3. 执行解压，报告进度
      4. 完成后处理：
         - **成功**：`appState.isOperationInProgress = false`，关闭进度窗口
           - 保持在 `.browseArchive` 模式（用户可能继续浏览）
           - 在 Finder 中打开解压目标目录（`NSWorkspace.shared.open(destinationURL)`）
         - **失败**：`appState.isOperationInProgress = false`，关闭进度窗口
           - 设置 `appState.lastError = error.localizedDescription`
           - 保持在当前模式
    - `determineSaveLocation(for sourceURLs: [URL], format: ArchiveFormat) -> URL`：
      - 调用 `PathUtils.allShareParentDirectory(sourceURLs)`
      - true → 返回公共父目录 + 默认文件名
      - false → 弹出 `NSSavePanel` 让用户选择
  - 连接 ContentView 的 drop handler 到路由逻辑：
    - 拖入普通文件 → `appState.loadFiles()` + 显示 Inspector
    - 拖入压缩包 → `appState.loadArchive()` (调用 FormatDetector + 对应 Reader)
  - 连接 Toolbar 压缩按钮到 `CompressionCoordinator.compress()`
  - 连接 Toolbar 解压按钮到 `CompressionCoordinator.extract()`

  **Must NOT do**:
  - 不实现拖出逻辑（Task 13）
  - 不实现进度窗口 UI（Task 14）
  - 不实现密码保护

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 需要整合多个服务和 UI 组件，逻辑复杂
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with Tasks 13, 14)
  - **Blocks**: Tasks 15, 16
  - **Blocked By**: Tasks 5, 6, 7, 8, 9, 10, 11

  **References**:
  - `BentoZip/Services/ZIPEngine.swift` - ZIP 引擎
  - `BentoZip/Services/LibArchiveReader.swift` - libarchive 读取
  - `BentoZip/Services/LibArchiveWriter.swift` - libarchive 写入
  - `BentoZip/Utilities/PathUtils.swift:allShareParentDirectory()` - 保存位置判断
  - `NSSavePanel` - 保存位置选择对话框
  - `BentoZip/ViewModels/AppState.swift` - 状态管理
  - `@Environment(\.openWindow)` - 打开进度窗口

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 压缩文件到同目录
    Tool: Bash (xcodebuild + 手动验证)
    Steps:
      1. 准备 /tmp/bentozip-compress-test/ 目录包含 3 个文件
      2. 拖入所有文件到应用
      3. 选择 ZIP 格式，点击压缩
      4. 验证 archive.zip 生成在 /tmp/bentozip-compress-test/ 目录
    Expected Result: 压缩包自动保存到源文件的公共父目录
    Evidence: .omo/evidence/task-12-compress-same-dir.txt

  Scenario: 不同目录文件弹出保存面板
    Tool: Bash
    Steps:
      1. 从不同目录拖入文件
      2. 验证 NSSavePanel 弹出
    Expected Result: 保存面板正确弹出
    Evidence: .omo/evidence/task-12-save-panel.txt

  Scenario: 解压压缩包
    Tool: Bash
    Steps:
      1. 拖入一个 .zip 文件
      2. 点击"解压全部"
      3. 验证文件解压到正确位置
      4. 使用 diff 验证内容一致
    Expected Result: 解压文件完整正确
    Evidence: .omo/evidence/task-12-extract.txt

  Scenario: 格式检测正确
    Tool: Bash
    Steps:
      1. 准备 .zip, .tar.gz, .7z 测试文件
      2. 分别拖入应用
      3. 验证每种格式被正确识别并显示内容
    Expected Result: 三种格式均正确检测和处理
    Evidence: .omo/evidence/task-12-format-detect.txt
  ```

  **Commit**: YES
  - Message: `feat: add drag-drop routing, save location logic, and compression/extraction operations`
  - Files: `BentoZip/Services/FormatDetector.swift`, `BentoZip/Services/CompressionCoordinator.swift`, `BentoZip/Views/`, `BentoZip/ContentView.swift`

---

- [ ] 13. 拖出到 Finder

  **What to do**:
  - **架构决策**：`FileRepresentation` 的闭包是同步的（不支持 `try await`），因此不能在传输表示内部执行异步提取。改为**拖拽发起时预提取**策略：
    1. 用户开始拖拽时（`.draggable()` 的 `preview` 阶段），异步提取归档内文件到临时目录
    2. 拖拽 payload 使用已存在的临时文件 URL（同步返回）
  - 在 `FileListView` 中为每个行添加 `.draggable()` 修饰符：
    ```swift
    .draggable(entry) {
        // preview 内容（缩略图标）
    } isDisabled: {
        appState.isOperationInProgress
    }
    ```
  - 创建 `BentoZip/Utilities/DragDropManager.swift`（单例，管理拖拽临时文件生命周期）：
    ```swift
    @MainActor
    final class DragDropManager {
        static let shared = DragDropManager()
        private let sessionTempDir: URL
        private var extractedFiles: [String: URL] = [:] // entry.id → tempURL

        init() {
            // 创建会话专用临时目录（UUID 命名）
            sessionTempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("BentoZip-drag-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: sessionTempDir, withIntermediateDirectories: true)
        }

        func prepareForDrag(_ entry: FileEntry, sourceArchiveURL: URL?) async -> URL {
            if !entry.isFromArchive {
                return entry.url // 压缩模式：直接返回原始 URL
            }
            // 解压模式：提取到临时目录
            let tempURL = sessionTempDir.appendingPathComponent(entry.name)
            // 调用对应引擎的 extractEntry 方法
            // ...
            extractedFiles[entry.id.uuidString] = tempURL
            return tempURL
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: sessionTempDir)
        }
    }
    ```
  - 在 FileListView 的 `.draggable()` 中使用：
    - 对于压缩模式的文件（`isFromArchive == false`）：直接 `.draggable(entry.url)`
    - 对于解压模式的文件（`isFromArchive == true`）：需要预提取。由于 `.draggable()` 的 item 必须是同步可获得的，使用**预缓存策略**：
      - 当用户浏览归档内容时（Task 6 的 `listEntries`），异步预提取小文件（< 10MB）到临时目录
      - `.draggable()` 直接返回预缓存的临时文件 URL
      - 大文件（≥ 10MB）：拖拽时显示提示"该文件较大，请先点击解压"
  - 临时文件管理：
    - 所有临时文件放在 `DragDropManager.sessionTempDir` 下
    - 应用退出或新会话开始时清理旧临时目录
    - 已知限制：SwiftUI 拖拽完成后临时文件不会被自动删除（系统会拷贝到目标位置）

  **Must NOT do**:
  - 不使用 NSFilePromiseProvider（SwiftUI 不支持）
  - 不在 `FileRepresentation` 闭包中使用 `try await`（编译错误）
  - 不实现拖出整个目录（仅支持单个文件拖出，目录拖出标记为后续增强）
  - 不实现拖出进度 UI（小文件直接提取，大文件提示用户先解压）

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Transferable + FileRepresentation 与 Finder 交互有已知陷阱
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with Tasks 12, 14)
  - **Blocks**: Tasks 15, 16
  - **Blocked By**: Tasks 5, 6, 9

  **References**:
  - SwiftUI `.draggable()` - 拖拽 API（注意：payload 必须同步可获得）
  - `BentoZip/Utilities/DragDropManager.swift` - 拖拽临时文件管理器（本任务创建）
  - `BentoZip/Views/FileList/FileListView.swift` - 添加 .draggable() 修饰符
  - `BentoZip/Models/FileEntry.swift:isFromArchive` - 判断文件来源
  - `BentoZip/Services/LibArchiveReader.swift:extractEntry()` - 提取单个条目
  - `BentoZip/Services/ZIPEngine.swift:extract()` - ZIP 单条目提取

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 压缩模式拖出文件
    Tool: Bash (xcodebuild + 手动验证)
    Steps:
      1. 拖入文件到应用（压缩模式）
      2. 从列表拖出文件到 Finder（桌面）
      3. 验证文件出现在桌面
    Expected Result: 文件成功复制到目标位置
    Evidence: .omo/evidence/task-13-drag-out-compress.txt

  Scenario: 解压模式拖出文件
    Tool: Bash
    Steps:
      1. 拖入压缩包到应用（解压模式）
      2. 从列表拖出文件到 Finder
      3. 验证文件被提取并复制到目标位置
      4. 验证文件内容正确
    Expected Result: 归档内文件成功提取并复制
    Evidence: .omo/evidence/task-13-drag-out-extract.txt
  ```

  **Commit**: YES (groups with Tasks 12, 14)

---

- [ ] 14. 进度窗口

  **What to do**:
  - 创建 `BentoZip/Views/Progress/ProgressWindowView.swift`:
    - 使用 `@Environment(AppState.self)` 获取进度状态
    - 布局（类似 Finder 拷贝进度窗口）：
      - 标题：`appState.operationDescription`（如"正在压缩..."、"正在解压..."）
      - 进度条：`ProgressView(value: appState.operationProgress)`
      - 百分比文本：`Text("\(Int(appState.operationProgress * 100))%")`
      - 取消按钮（可选，首批可不实现取消功能）
    - 窗口大小：固定小尺寸（约 400x150）
    - 窗口行为：操作进行中不可关闭（防止用户误操作），操作完成后自动关闭
      - 操作进行中：主窗口应禁用交互（`.disabled(appState.isOperationInProgress)`）
      - 出错时：进度窗口自动关闭，错误通过 ContentView 的 alert 显示
  - 在 `BentoZipApp.swift` 的 `WindowGroup(id: "progress")` 中放置 `ProgressWindowView`
  - 添加窗口配置：
    - `.defaultSize(width: 400, height: 150)`
    - `.windowResizability(.contentSize)`
    - `.windowStyle(.hiddenTitleBar)` 或自定义标题栏
  - 连接 CompressionCoordinator：
    - 操作开始前：`openWindow(id: "progress")`
    - 操作过程中：更新 `appState.operationProgress` 和 `appState.operationDescription`
    - 操作完成后：使用 `@Environment(\.dismissWindow)` 关闭进度窗口
      ```swift
      // ⚠️ 不要用 @Environment(\.dismiss)——那是用于 sheet 的
      // macOS 14+ 正确做法：
      @Environment(\.dismissWindow) private var dismissWindow
      // 完成后调用：
      dismissWindow(id: "progress")
      ```

  **Must NOT do**:
  - 不实现取消操作（首批不支持）
  - 不实现多任务并行进度（仅单任务进度）
  - 不实现进度窗口的位置记忆

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: 进度窗口视觉效果和动画
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with Tasks 12, 13)
  - **Blocks**: Tasks 15, 16
  - **Blocked By**: Tasks 5, 6, 7

  **References**:
  - `BentoZip/Views/Progress/` - 目标目录
  - `BentoZip/BentoZipApp.swift` - WindowGroup(id: "progress") 定义
  - `BentoZip/ViewModels/AppState.swift:operationProgress` - 进度值
  - `BentoZip/ViewModels/AppState.swift:operationDescription` - 操作描述
  - SwiftUI `ProgressView` - 进度条组件
  - `@Environment(\.openWindow)` / `@Environment(\.dismiss)` - 窗口管理
  - Finder 拷贝进度窗口 - 视觉参考

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 压缩时显示进度窗口
    Tool: Bash (xcodebuild + 手动验证)
    Steps:
      1. 拖入多个大文件到应用
      2. 点击压缩按钮
      3. 验证进度窗口弹出
      4. 验证进度条从 0% 递增到 100%
      5. 验证操作完成后窗口关闭
    Expected Result: 进度窗口正确显示、更新、关闭
    Evidence: .omo/evidence/task-14-progress-window.txt

  Scenario: 解压时显示进度窗口
    Tool: Bash
    Steps:
      1. 拖入压缩包
      2. 点击解压
      3. 验证进度窗口显示解压进度
    Expected Result: 解压进度正确显示
    Evidence: .omo/evidence/task-14-extract-progress.txt
  ```

  **Commit**: YES (groups with Tasks 12, 13)
  - Message: `feat: add drag-out to Finder and progress window`
  - Files: `BentoZip/Views/Progress/`, `BentoZip/Views/FileList/`, `BentoZip/Models/ArchiveItemTransferable.swift`, `BentoZip/BentoZipApp.swift`

---

- [ ] 15. 通用工具（删除、添加）

  **What to do**:
  - **删除功能**：
    - 在 `FileListView` 中支持选中条目后按 Delete 键删除
    - 在 Toolbar 的删除按钮中连接 `appState.removeEntries(at:)`
    - 压缩模式：直接从 `fileEntries` 数组中移除（不影响原始文件）
    - 解压模式：从归档中删除条目
      - ZIP：使用 `ZIPEngine.removeEntries()`
      - 7z/tar.gz：使用**原子提取-重建策略**：
        1. 创建临时目录（UUID 命名）
        2. 用 LibArchiveReader 提取除要删除条目外的所有条目到临时目录
        3. 用 LibArchiveWriter 从临时目录创建新归档到临时文件（.tmp 后缀）
        4. 验证新归档可读（调用 listEntries 确认条目数正确）
        5. 用 `FileManager.replaceItemAt(originalURL, withItemAt: tempArchiveURL)` 原子替换
        6. 清理临时目录
        7. 如果任何步骤失败，删除临时文件，保留原归档不变
    - 确认对话框：解压模式删除时弹出确认（"确定要从归档中删除选中的文件吗？"）
    - **已知限制**：7z/tar.gz 的提取-重建策略需要完整重写归档。对于大文件（> 1GB），删除操作可能需要数分钟。这是格式限制，非 bug。
  - **添加功能**：
    - Toolbar 添加按钮 → 弹出 `NSOpenPanel`（支持多选文件和目录）
    - 选择后调用 `appState.addEntries(from: urls)`
    - 压缩模式：将新文件添加到 `fileEntries` 数组
    - 解压模式：将文件添加到归档
      - ZIP：使用 `ZIPEngine.addEntries()`
      - 7z/tar.gz：提取-重建策略
    - 也支持从 Finder 拖入更多文件（已在 Task 8 的 drop handler 中处理）
  - 在 `AppState` 中完善 `removeEntries` 和 `addEntries` 方法

  **Must NOT do**:
  - 不实现拖拽排序列表项
  - 不实现批量重命名
  - 不实现文件预览

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 需要处理两种模式下的不同行为逻辑
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 5 (with Task 16)
  - **Blocks**: Task 16
  - **Blocked By**: Tasks 12, 13, 14

  **References**:
  - `BentoZip/ViewModels/AppState.swift:removeEntries()` - 删除方法
  - `BentoZip/ViewModels/AppState.swift:addEntries()` - 添加方法
  - `BentoZip/Services/ZIPEngine.swift:removeEntries()` - ZIP 条目删除
  - `BentoZip/Services/ZIPEngine.swift:addEntries()` - ZIP 条目添加
  - `BentoZip/Services/LibArchiveReader.swift` - 提取用于重建
  - `BentoZip/Services/LibArchiveWriter.swift` - 重建归档
  - `NSOpenPanel` - 文件选择对话框
  - SwiftUI `.alert()` - 确认对话框

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 压缩模式删除列表项
    Tool: Bash (xcodebuild + 手动验证)
    Steps:
      1. 拖入 3 个文件
      2. 选中一个，点击删除
      3. 验证列表只剩 2 个
      4. 验证原始文件未被删除
    Expected Result: 仅从列表移除，不影响原始文件
    Evidence: .omo/evidence/task-15-delete-compress.txt

  Scenario: 解压模式删除归档条目
    Tool: Bash
    Steps:
      1. 拖入 ZIP 压缩包
      2. 选中一个条目，点击删除
      3. 确认对话框
      4. 验证归档中不再包含该条目
    Expected Result: 归档被修改，条目被删除
    Evidence: .omo/evidence/task-15-delete-archive.txt

  Scenario: 添加文件到列表
    Tool: Bash
    Steps:
      1. 拖入初始文件
      2. 点击添加按钮，选择更多文件
      3. 验证新文件出现在列表中
    Expected Result: 新文件正确添加到列表
    Evidence: .omo/evidence/task-15-add-files.txt
  ```

  **Commit**: YES (groups with Task 16)
  - Message: `feat: add common tools (delete, add) and preferences`

---

- [ ] 16. SwiftData 偏好设置 + 错误处理

  **What to do**:
  - **SwiftData 偏好设置**：
    - 在 `BentoZipApp.swift` 中配置 ModelContainer：
      ```swift
      let schema = Schema([AppPreferences.self])
      let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
      do {
          let container = try ModelContainer(for: schema, configurations: [config])
          // 注入到 environment
      } catch {
          // ⚠️ 不要用 fatalError —— 应用应在没有偏好设置的情况下仍可工作
          // 使用 in-memory container 作为降级方案
          let container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
      }
      ```
    - 创建 `BentoZip/Services/PreferencesManager.swift`:
      - `loadPreferences() -> AppPreferences` - 加载或创建默认偏好
      - `savePreferences(_ prefs: AppPreferences)` - 保存偏好
      - `applyDefaults(to settings: inout CompressionSettings)` - 将偏好应用到新设置
    - 在 AppState 初始化时加载偏好设置
    - 在压缩设置变更时自动保存偏好
    - 偏好项：
      - 默认压缩格式
      - 默认压缩级别
      - 排除模式列表
      - 上次保存目录
      - 最近操作的归档路径（最多 10 个）
  - **错误处理**：
    - 在 AppState 中添加 `lastError: String?` 属性
    - 所有异步操作（压缩、解压、删除等）使用 `do-catch` 包装
    - 错误发生时设置 `lastError` 并显示 `.alert()`
    - 在 ContentView 中添加全局错误 alert：
      ```swift
      // ⚠️ 不能使用 .constant(appState.lastError != nil)，它不会随 lastError 变化而重新求值
      // 正确做法：使用 onChange 触发独立 @State
      @State private var showErrorAlert = false

      // 在 ContentView body 中：
      .onChange(of: appState.lastError) { _, newValue in
          showErrorAlert = newValue != nil
      }
      .alert("错误", isPresented: $showErrorAlert) {
          Button("确定") { appState.lastError = nil }
      } message: {
          Text(appState.lastError ?? "")
      }
      ```
    - 常见错误场景：
      - 文件不存在或无权限
      - 归档格式不支持或损坏
      - 磁盘空间不足
      - 目标路径不可写

  **Must NOT do**:
  - 不实现偏好设置 UI 面板（通过 Inspector 参数自动保存即可）
  - 不实现错误恢复建议（仅显示错误信息）
  - 不实现日志记录

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: SwiftData 集成 + 全局错误处理需要仔细设计
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 5 (with Task 15)
  - **Blocks**: F1-F4
  - **Blocked By**: Tasks 12, 13, 14, 15

  **References**:
  - `BentoZip/Models/AppPreferences.swift` - SwiftData 模型
  - `BentoZip/BentoZipApp.swift` - ModelContainer 配置
  - `BentoZip/ViewModels/AppState.swift:lastError` - 错误状态
  - SwiftUI `.alert()` - 错误对话框
  - `@Query` - SwiftData 查询
  - `BentoZip/Services/` - PreferencesManager 目标目录

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 偏好设置持久化
    Tool: Bash (xcodebuild + 手动验证)
    Steps:
      1. 运行应用，修改压缩格式为 7z
      2. 关闭应用
      3. 重新打开应用
      4. 验证格式选择仍为 7z
    Expected Result: 偏好设置在重启后保留
    Evidence: .omo/evidence/task-16-prefs-persist.txt

  Scenario: 错误提示显示
    Tool: Bash
    Steps:
      1. 尝试解压一个损坏的 ZIP 文件
      2. 验证错误 alert 弹出
      3. 点击"确定"关闭
    Expected Result: 错误信息正确显示，可关闭
    Evidence: .omo/evidence/task-16-error-alert.txt

  Scenario: 最近归档记录
    Tool: Bash
    Steps:
      1. 执行一次压缩操作
      2. 验证 AppPreferences.recentArchives 包含新归档路径
    Expected Result: 操作记录正确保存
    Evidence: .omo/evidence/task-16-recent-archives.txt
  ```

  **Commit**: YES (groups with Task 15)
  - Message: `feat: add common tools (delete, add) and preferences`
  - Files: `BentoZip/Services/PreferencesManager.swift`, `BentoZip/BentoZipApp.swift`, `BentoZip/ViewModels/AppState.swift`, `BentoZip/ContentView.swift`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.

- [ ] F1. **Plan Compliance Audit** — `general`
  Read the plan end-to-end. For each "Must Have": verify implementation exists. For each "Must NOT Have": search codebase for forbidden patterns. Check evidence files exist in .omo/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `general`
  Run `xcodebuild build`. Review all changed files for: force unwraps, empty catches, print statements in prod, commented-out code, unused imports. Check AI slop: excessive comments, over-abstraction, generic names.
  Output: `Build [PASS/FAIL] | Files [N clean/N issues] | VERDICT`

- [ ] F3. **Real Manual QA** — `general`
  Build and run the app. Execute EVERY QA scenario from EVERY task. Test cross-task integration. Test edge cases: empty state, invalid input, large files. Save to `.omo/evidence/final-qa/`.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `general`
  For each task: read "What to do", read actual diff. Verify 1:1 — everything in spec was built, nothing beyond spec was built. Check "Must NOT do" compliance.
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | VERDICT`

---

## Commit Strategy

- **Task 1**: `chore: project setup, add SPM dependencies, create directory structure` - project.pbxproj, Package.resolved
- **Task 2**: `feat: add core models and ArchiveEngine protocol` - Models/
- **Task 3**: `feat: add utility functions (PathUtils, FileUtils)` - Utilities/
- **Task 4**: `feat: add AppState central state management` - ViewModels/
- **Task 5-7**: `feat: add compression engines (ZIP + libarchive)` - Services/
- **Task 8-11**: `feat: add UI shell (main window, file list, inspector, toolbar)` - Views/
- **Task 12-14**: `feat: add drag-drop integration and progress window` - Views/, Services/
- **Task 15-16**: `feat: add common tools and preferences` - Views/, Services/

---

## Success Criteria

### Verification Commands
```bash
xcodebuild build -scheme BentoZip  # Expected: BUILD SUCCEEDED
# 手动验证：拖入文件 → 列表显示 → 压缩 → 进度窗口 → 生成文件
# 手动验证：拖入压缩包 → 列表显示 → 解压 → 文件完整
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] App builds without errors
- [ ] Drag-in files → list view works
- [ ] Compress → progress window → archive created
- [ ] Drag-in archive → list view → extract works
- [ ] Drag-out items → files appear in Finder
- [ ] Inspector panel shows/hides correctly
- [ ] Toolbar buttons enable/disable per mode
