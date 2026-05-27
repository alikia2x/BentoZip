# Draft: BentoZip - macOS 压缩工具

## 项目现状
- **模板**: macOS SwiftUI + SwiftData + Swift Testing
- **部署目标**: macOS 14.6 (Sonoma)
- **Bundle ID**: com.alikia.bentozip
- **无 entitlements 文件** - 尚未配置沙箱
- **SwiftData**: 模板自带 Item model，压缩工具可能不需要持久化
- **Swift Testing**: 使用新的 `import Testing` 框架

## 用户需求（已确认）
1. 工具栏在窗口顶部，无左侧边栏
2. 右侧边栏（Inspector）默认隐藏，用于属性/参数调整
3. 空状态：中央提示文本
4. 拖入文件/目录 → Finder 列表模式表格展示
5. 目录项点击进入子目录视图
6. 拖入后工具栏按钮可用 + 右侧边栏弹出（压缩参数面板）
7. 压缩保存位置逻辑：同父目录 → 自动设定；不同 → 弹出选择
8. 压缩进度窗口（类似 Finder 拷贝进度条）
9. 拖入压缩包 → 展示内容列表，解压按钮可用
10. 列表项可拖出窗口 → 解压到目标位置
11. 通用工具：删除列表项、添加文件/目录

## 技术研究发现

### 压缩库选择
| 库 | 格式支持 | 进度追踪 | 流式处理 | SPM | 成熟度 |
|---|---------|---------|---------|-----|--------|
| **ZIP Foundation** | ZIP (deflate/none) | ✅ NSProgress | ✅ 逐条目 | ✅ | ⭐⭐⭐⭐⭐ (95分) |
| **SWCompression** | ZIP, TAR, GZip, BZip2, XZ, 7z | ❌ 无内建 | ❌ 全内存 | ✅ | ⭐⭐⭐ (Medium) |
| **Process() 调用系统工具** | 取决于工具 | 部分 | 部分 | N/A | 不稳定 |

**推荐**: ZIP Foundation - API 简洁，NSProgress 集成，生产级可靠

### SwiftUI API 可用性 (macOS 14.6+)
- ✅ `.inspector()` - 右侧边栏完美方案
- ✅ `.dropDestination()` - 文件拖入
- ✅ `Transferable` + `.draggable()` - 拖出
- ✅ `WindowGroup(id:)` + `openWindow` - 进度窗口
- ✅ `NavigationStack` - 目录层级导航

### 拖出到 Finder 的技术挑战
- SwiftUI 不支持真正的 NSFilePromiseProvider
- 需要先解压到临时目录，再通过 FileRepresentation 提供 URL
- 对于大文件可能效率不高，但这是 SwiftUI 的限制
- 替代方案：混用 AppKit 的 NSFilePromiseProvider（复杂度高）

### 进度窗口方案
- 使用 `WindowGroup(id: "progress")` 定义
- 通过 `@Environment(\.openWindow)` 触发
- 进度条绑定到 NSProgress 或自定义 ObservableObject

## 用户决策（已确认）
- **压缩格式**: ZIP + 7z + tar.gz（首批支持）
- **压缩库策略**:
  - ZIP → ZIP Foundation（NSProgress 集成完善）
  - 7z + tar.gz → libarchive（通过 matteo-pacini/libarchive-for-swift XCFramework）
  - 修改不支持直接操作的格式 → 解压旧包 + 创建新包
- **SwiftData**: 保留，用于偏好设置（默认压缩级别、排除模式、历史保存路径等）
- **沙箱**: 关闭（完全文件系统访问）
- **压缩参数**: 基础 + 高级
  - 基础：压缩级别、压缩包名称、密码保护（可选）
  - 高级：分卷大小、保留目录结构开关、排除文件模式
- **测试**: 无单元测试，仅 Agent QA 场景
- **部署目标**: macOS 26.1（可使用全部最新 SwiftUI API）

## libarchive 研究发现
- **matteo-pacini/libarchive-for-swift**: XCFramework 分发，macOS >= 13.0，SPM 安装
  - 包含 bzip2, lz4, xz, zlib, zstd 依赖
  - 直接暴露 C API（`import libarchive`）
  - 支持读写：tar (all variants), cpio, zip, 7zip, iso9660, raw, xar, mtree
  - 支持过滤器：gzip, bzip2, compress, lzma, lz4, xz, zstd, lzip, lzop
- **Swift-C 互操作**: 需要自定义回调函数实现进度追踪
- **archive_write_set_bytes_in_last_block(archive, 1)**: 需要调用以避免 10240 字节填充

## 架构方案
```
BentoZip/
├── App/                    # App 入口 + Scene 配置
├── Models/                 # FileEntry, CompressionSettings, AppPreferences
├── Services/               # CompressionEngine, ArchiveReader, ProgressTracker
├── ViewModels/             # AppState (@Observable)
├── Views/
│   ├── Main/               # ContentView, EmptyStateView
│   ├── FileList/           # FileListView, FileRowView
│   ├── Inspector/          # CompressionSettingsView
│   ├── Progress/           # ProgressWindowView
│   └── Toolbar/            # ToolbarCommands
└── Utilities/              # PathUtils, FileUtils
```

## 待确认问题
- [x] 压缩格式支持范围 → ZIP + 7z + tar.gz
- [x] SwiftData 用途 → 偏好设置
- [x] 沙箱策略 → 关闭
- [x] 测试策略 → 无单元测试
- [x] 压缩参数 → 基础 + 高级
