# 开发与交付流程

目标是把重复验收步骤写进仓库，用同一套入口在本机和 CI 执行。测试、构建和上传失败时及时停止，不把旧提交的产物当作当前版本。

## 分级执行

| 场景 | 命令 | 范围 |
|---|---|---|
| 文档、脚本、工作流修改 | `python3 scripts/validate.py quick` | 空白检查、Shell/Python/YAML/plist 语法、7 项脚本测试 |
| Swift 逻辑或界面修改 | `python3 scripts/validate.py test` | 上述检查 + 27 项 Swift 测试 |
| 需要本地可安装交付物 | `python3 scripts/validate.py package` | 检查、测试、Universal app、DMG、校验和；应用只构建一次 |
| 快速本机 UI 迭代 | `ARCHS="$(uname -m)" CONFIGURATION=debug bash scripts/build-app.sh` | 只编译本机架构的 Debug 应用 |
| 推送 PR 后获取已验证安装包 | `python3 scripts/ci_artifact.py --wait` | 等待当前 HEAD 的 PR 构建、下载、核对来源、验证 DMG |
| 检查已有 Universal DMG | `python3 scripts/verify_dmg.py path/to/Memos.dmg` | 校验和、镜像完整性、挂载、签名、双架构、最低系统版本、安装链接 |

`validate.py` 每个阶段输出耗时，失败时退出。报告在 `.build/validation/latest.json`，包含对应提交和工作区是否有未提交改动。完整打包还会生成 `dist/BUILD_TIMINGS.json`；GitHub workflow 也调用这个入口，摘要显示阶段耗时，并上传报告。

一般无需同时完整执行本地 `package` 和远程打包：改 Swift 时本地 `test`，推送后直接验收 CI 产物；只有需要先在本机安装/运行，或修改打包逻辑时再执行完整本地打包。

## PR 产物验收

```bash
# 默认以 origin 仓库和本地 HEAD 为准，不采用 gh 的潜在上游默认仓库
python3 scripts/ci_artifact.py --wait

# 指定运行；仍会拒绝与当前 HEAD 不同的产物
python3 scripts/ci_artifact.py --run 35308290565 --wait

# 有意检查历史构建时明确给出提交
python3 scripts/ci_artifact.py --run RUN_ID --commit COMMIT_SHA
```

工具仅查阅 GitHub、下载产物和只读挂载，不提交/推送/合并，不启动镜像中的应用。它会：

1. 每 15 秒查询一次，只在构建阶段改变时打印状态，默认超时 20 分钟。
2. 检查运行属于预期提交；失败、取消、产物过期等情况返回非零退出码。
3. 将文件缓存到 `.build/ci-artifacts/RUN_ID/`，已有完整下载不重复下载。
4. 对照 `BUILD_INFO.json` 中的 PR head 和 run ID；PR 合并测试提交与实际 PR head 分开处理。
5. 核对 SHA-256，验证 DMG，只读挂载检查应用签名、arm64/x86_64、macOS 14 最低版本及 Applications 链接，最后卸载。
6. 输出下载链接、DMG 本地路径和机器可读的 `verification.json`。

中断造成的未完成下载目录会被保留，并提示将其移开后重试，避免静默使用半份产物。核验旧产物时必须明确指定对应提交。源码有未提交改动时，远程产物只能证明已提交的 HEAD。

## 耗时与优化取舍

已观测的第二次初版 GitHub 构建（运行 `35307257084`）：测试阶段约 24 秒、双架构构建约 29 秒、DMG 生成/校验约 8 秒，整个 job 约 70 秒。这是该次环境的观测值，不是固定性能保证。

统一脚本在本机已有增量缓存的一次实测：快速检查 0.13 秒、27 项 Swift 测试及增量编译 1.45 秒、Universal 构建 9.10 秒、DMG 阶段 19.36 秒。与冷启动的远程 runner 环境不同，不将两者作为优化前后对比。

- Swift 编译是主要计算耗时。本地保留 `.build` 增量缓存；UI 迭代只构建本机架构，交付时才编译 Universal。
- DMG 创建需要系统磁盘服务，不适合每次文字或界面微调都执行。完整流水线显式复用刚构建的 app（`SKIP_BUILD=1`）。
- CI 等待、下载及挂载核对之前需要多次人工操作，现已合为一条命令；重复核验复用下载缓存。
- 新增快速检查本机曾测得约 0.18 秒；以本次 `latest.json` 为准。
- 暂不添加远程 `.build` 大缓存。当前编译仅几十秒，先记录耗时，再衡量缓存上传/恢复是否真的更快，避免仅增加维护与传输成本。
- 单架构调试 app 若单独打包，DMG 文件名会使用实际架构，避免误标为 Universal。

## 仍需真实交互的部分

脚本不能替代菜单栏位置、可见光标、输入法、跨应用全局快捷键、真实图片剪贴板、首次钥匙串授权或用户实际 Memos 服务联调。检查工具失败时应记录“未验证”，不能用构建或静态渲染代替这些结果。清单见 `VALIDATION.md`。
