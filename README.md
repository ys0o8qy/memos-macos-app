# Memos for macOS

一个原生菜单栏 Memos 客户端。点击菜单栏写作图标随手记录，用独立窗口回看和编辑。

- macOS 14+，SwiftUI + AppKit，无第三方运行时依赖。
- 对接 **Memos v0.30.0**，服务地址 + Personal Access Token 连接。
- Markdown 源文编辑、基础 Markdown 预览、`#标签`。
- 图片粘贴、拖入和文件选择；提交前预览、移除，支持纯图片记录。单张图片上限 20 MB，仍受服务端上传限制。
- 新记录固定私有；修改已有记录保留原可见性。
- 文字和图片草稿自动保留；收起、关闭窗口或重启后恢复。离线后手动重试。
- 当前账号的记录列表、服务端搜索、分页、刷新、编辑与图片查看。
- 可自定义全局唤起快捷键（默认 `Control Option M`），保存 `Command Enter`，编辑保存 `Command S`，收起 `Esc`。
- GitHub PR 自动测试、生成 Universal DMG、上传下载产物。

## 使用

打开 `dist/Memos.app`，填写服务地址及 Token，点击“验证并保存”。Token 在你的 Memos 网页设置中创建。主窗口关闭后应用仍驻留菜单栏；左键点击图标打开/收起浮窗，右键（或 `Control` 点击）打开菜单，可查看所有记录、打开连接设置或退出 Memos。退出入口也保留在浮窗的“更多”菜单。正在提交时会提示等待保存完成，避免中断提交。

在连接设置中勾选“使用全局快捷键”，点击当前组合后直接按下新组合键即可保存。组合需要包含 `Command`、`Control` 或 `Option` 中至少一个；`Esc`、点击别处或切换窗口取消录入。“恢复默认”还原为 `Control Option M`。录入期间暂停旧快捷键，取消或注册冲突后恢复原设置；设置重启后保留。

浮窗打开后可直接输入，空编辑器会显示插入光标。复制截图或图片后在输入框按 `Command V`，图片作为附件显示在下方，不替换现有文字；支持 PNG、TIFF、JPEG 等系统图片剪贴板表示。

从 PR 下载：打开 PR 的 **Checks → Build macOS DMG → Summary → Artifacts**，下载 `Memos-DMG-…`，解压后打开 DMG，将应用拖入 Applications。

当前打包采用 **ad-hoc 签名，未做 Apple 公证**。下载的构建如果被系统拦截，按 [安装说明](docs/INSTALL.txt) 在“隐私与安全性”中对该应用选择“仍要打开”。

## 本地构建

统一入口与耗时优化见 [开发流程](docs/DEVELOPMENT.md)：日常运行 `python3 scripts/validate.py test`；需要完整安装包时运行 `python3 scripts/validate.py package`；推送后运行 `python3 scripts/ci_artifact.py --wait` 自动验收当前提交的远程产物。

安装 Xcode 或兼容的 Command Line Tools。脚本优先使用 `/Applications/Xcode.app`；可以通过 `DEVELOPER_DIR` 指定其他 Xcode。

```bash
# 测试
bash scripts/test.sh

# 默认构建 Apple Silicon + Intel 通用版
bash scripts/build-app.sh
open dist/Memos.app

# 完整构建、打包、校验 DMG，并生成 SHA-256
bash scripts/package-dmg.sh

# 只构建当前 Apple Silicon Mac 的调试版
ARCHS=arm64 CONFIGURATION=debug bash scripts/build-app.sh
```

输出：`dist/Memos.app`、`dist/Memos-0.1.0-universal.dmg` 和 `.dmg.sha256`。已构建时可以设置 `SKIP_BUILD=1` 只打包 DMG。`VERSION`、`BUILD_NUMBER` 可覆盖包版本。

不要用 `swift run` 代替最终 `.app` 安装包：菜单栏、钥匙串归属和应用标识应以完整 app bundle 验证。

## GitHub PR 自动打包

[工作流](.github/workflows/package-dmg.yml) 在 PR 新建/更新/重新打开、推送 `main` 或版本标签，以及手动触发时运行：

1. `python3 scripts/validate.py package` 统一入口：脚本检查及测试、Swift 接口/存储/应用状态/原生视图测试。
2. 分别编译 `arm64` / `x86_64`，合并为 Universal app。
3. 生成应用图标、ad-hoc 签名、验证签名和最低系统版本。
4. 创建 DMG，运行 `hdiutil verify` 并生成 SHA-256。
5. 上传 DMG、校验文件、`BUILD_INFO.json` 和 `BUILD_TIMINGS.json`，保留 14 天，任务摘要包含下载链接及各阶段耗时。

工作流只需 `contents: read`，无 Token/证书 Secrets，不使用 `pull_request_target`，支持 fork PR。不自动发布 Release、不自动评论 PR。需要该仓库启用 GitHub Actions；新贡献者的 fork PR 可能需要维护者批准运行。

## 数据与行为

- Token：macOS 钥匙串，服务名 `app.memos.popup.token`。
- 服务地址与用户标识：应用 UserDefaults。
- 本地草稿：`~/Library/Application Support/MemosPopup/Drafts/`；可从设置直接打开。
- 草稿按服务器和账号隔离，文字 JSON 与图片文件分开保存。草稿是本机普通文件，不做额外加密，目录权限 `0700`、文件权限 `0600`。
- 文本修改立即原子写盘；图片先写本地，点击保存才上传。网络或磁盘失败不会主动清空原稿。
- 新记录与图片使用稳定 ID。上一次请求成功但响应丢失时，重试对同一资源恢复，避免另建重复记录。
- 编辑前读取最新内容，发现其他客户端修改时保留本地草稿并要求对照。服务端 API 不支持条件写入，这不是原子的多客户端冲突解决。
- 只更新 `content,attachments`，不会改写可见性、置顶或其他字段。
- 对 API 重定向不自动跟随；外部附件 URL 不携带 Memos Token。
- 允许 HTTP 地址以支持局域网自建服务；跨公网建议配置 HTTPS。

第一版没有后台离线上传、自动更新、开机启动、多账号同时登录。预览支持标题、列表、任务项和行内 Markdown；复杂表格、代码块及正文内的远程图片尚未完整渲染，原始 Markdown 会原样保存。

后续常用浮窗功能的分析与建议优先级见 [Popup 功能规划](docs/POPUP_ROADMAP.md)，其中建议项尚未实现。

## 测试与手工验证

27 项自动测试覆盖：认证错误、URL/CEL 编码、账号过滤与分页、默认私有、编辑字段范围、图片 Base64 上传、重复请求恢复、附件认证边界、草稿恢复与隔离、坏文件保护、离线恢复、编辑冲突、原生编辑器 Command V 图片粘贴和持久化、PNG/TIFF/JPEG 剪贴板兼容、空编辑器聚焦尺寸、快捷键迁移与持久化、取消录入与冲突回退、Carbon 实际注册/释放，以及原生界面离屏渲染。

本地合成服务方便手工验证，不接触真实账号：

```bash
python3 scripts/mock-server.py
# 另一个终端；该模式只接受 localhost / 127.0.0.1 / ::1
open -n dist/Memos.app --args --ui-testing --test-server http://127.0.0.1:18741
```

测试数据分别位于 `/tmp/memos-popup-fixture/` 和 `/tmp/memos-popup-ui-test/`，测试模式不保存真实 Token 或连接设置。创建 `/tmp/memos-popup-fixture/fail-next` 文件可让下一次写请求失败，用于检查草稿保留。

自动渲染只是布局冒烟测试，不能替代真实菜单栏、焦点、输入法和图片粘贴测试。GitHub PR 自动测试与 DMG 打包已实际跑通，下载产物的 SHA-256 和镜像校验通过。尚未连接用户真实服务；完整验证结果与手工检查项目见 [验证记录](docs/VALIDATION.md)。

## 代码布局

| 路径 | 用途 |
|---|---|
| `Sources/MemosCore` | Memos v0.30 协议、数据模型、本地草稿存储 |
| `Sources/MemosPopup` | AppKit 菜单栏/窗口/编辑器、SwiftUI 界面、应用状态、钥匙串 |
| `Tests` | 协议和状态测试、原生界面冒烟测试 |
| `scripts` | 图标、构建、DMG 打包及本地测试服务 |
| `.github/workflows` | PR 自动打包 |

接口依据：[v0.30.0 官方发布](https://github.com/usememos/memos/releases/tag/v0.30.0)、[Memo 协议](https://github.com/usememos/memos/blob/v0.30.0/proto/api/v1/memo_service.proto)、[Attachment 协议](https://github.com/usememos/memos/blob/v0.30.0/proto/api/v1/attachment_service.proto)、[认证协议](https://github.com/usememos/memos/blob/v0.30.0/proto/api/v1/auth_service.proto)。
