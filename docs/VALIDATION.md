# 第一版验证记录

2026-09-18；本机 Apple Silicon，Xcode 26.6 / Swift 6.3.3，最低部署目标 macOS 14。

## 已验证

- Debug 与 Release 编译通过。
- arm64 与 x86_64 均成功编译；Universal 可执行文件含两个架构。
- 17 项 XCTest 全部通过，测试不使用真实服务或真实 Token。
- AppKit 原生视图离屏渲染通过；实际截图包含部分离屏合成限制，未作为完整视觉验收。
- 应用以完整 bundle 启动，向本地 HTTP 合成服务发出带当前账号过滤的列表请求。
- 应用包 plist 检查与 ad-hoc 签名校验通过。
- DMG 创建、镜像校验与 SHA-256 生成通过。
- [PR #1](https://github.com/ys0o8qy/memos-macos-app/pull/1) 实际触发 `pull_request` 构建；[首次远程运行](https://github.com/ys0o8qy/memos-macos-app/actions/runs/35307035669) 的测试、Universal 编译、DMG 校验和产物上传全部通过。
- 已下载该次远程产物 `Memos-DMG-1-1`，本机再次验证 SHA-256 和 `hdiutil verify` 均通过；`BUILD_INFO.json` 中的 PR head 为 `3d300688f5a8c4654b47926bedf5b4130c6ae984`，与构建时的 PR 提交一致。

## 尚未完成的真实环境验证

- 本轮 Computer Use 工具对本应用和 Finder 均返回 `cgWindowNotFound`，未能完成实际点击、键盘和系统剪贴板端到端验证。
- 点击菜单栏唤出、输入框自动聚焦、Esc/点击外部收起、保存后回到之前应用。
- 中文输入法组合状态下 `Command Enter` 不误提交。
- Preview/截图工具复制的图片、Finder 复制的图片文件、拖入图片和多张图片上传。
- 与用户实际部署的 Memos v0.30.0、实际 Token 和图片存储配置联调。
- 钥匙串的首次授权、重启后的读取、Token 过期及账号切换。
- macOS 14 最低版本及真实 Intel Mac 上的运行。
- 从浏览器下载后的 Gatekeeper 提示。

## 自定义快捷键与输入交互改进

- 本机 27 项测试通过。新增测试覆盖快捷键迁移/保存/恢复、取消录入、冲突保留原设置、禁用后修改，以及 Carbon 真实注册冲突和释放旧组合。
- 通过 `ImageTextView.performKeyEquivalent` 实际执行 Command V 图片粘贴，验证附件写入和原有文本保留；另验证 TIFF/JPEG 原生粘贴路径，测试均使用独立剪贴板。
- 空编辑器的文档高度不小于可视区域；测试确认可成为第一响应者、插入位置为 0，插入光标颜色已设置。浮窗显示和应用激活后再次确认焦点。
- 独立测试应用 `app.memos.popup.qa` 的 Computer Use 检查仍返回 `cgWindowNotFound`，因此光标闪烁、跨应用快捷键唤起和录入控件的完整实际操作仍需要真机交互确认。

## 建议手工验收顺序

1. 配置服务地址和 Token，验证身份成功；输入错误 Token 时看到明确错误。
2. 在其他应用输入期间，点击菜单栏打开 Popup，输入中文、Markdown 和标签。
3. 粘贴图片、Esc 收起、重新打开，再退出重启，确认文字和图片恢复。
4. 断网点击保存，确认内容保留；联网后手动重试，服务器只出现一条私有记录。
5. 在列表搜索、分页、编辑文字/附件，确认网页端可见性和其他字段未变化。
6. 在网页修改同一记录，再从 Mac 保存旧草稿，确认出现冲突提示。
7. 在 GitHub PR 的 Checks 中下载 Universal DMG，校验 SHA-256 后安装运行，确认 Gatekeeper 提示与首次启动行为。
8. 在设置录入新快捷键，从其他应用唤起空浮窗，确认光标可见；测试取消录入、恢复默认、重启记忆，以及截图复制后 Command V 添加图片。
