# TODO

## 待办

- [ ] 部分截图时窗口太大，导致 Blender 内字体太小、不清晰；后续需要以 1080p 屏幕进行截图。

## 多镜像拉取与构建：核对结论

本轮用官方仓库、GitHub 镜像、Gitee 镜像各做了一次"从零拉取 + 生成工程"的实测，逐条对照
第 2 章关于构建的描述：

| 书稿说法 | 位置 | 实测结果 |
|---|---|---|
| 预编译库子模块在 `.gitmodules` 里被标记为不自动更新，`git submodule update` 不会碰它们；真正启用的是 `make update` 里的 `git config --local submodule.<路径>.update checkout` | 2.2.2 | 一致：直接 `git submodule update --init -- lib/<平台>_<架构>` 静默无操作，补上 `-c submodule.<路径>.update=checkout` 才真正检出 |
| Windows 上游会询问 `Would you like to download them? (y/n)`，回答后跳过 LFS 过滤拉子模块元数据，再在库目录执行 `git lfs pull` | 2.2.2 | 一致（`build_files/windows/check_libraries.cmd:31-36`） |
| 中断库下载会留下半损坏的 `lib/` | 2.2.2 | 一致：中断后 `lib/` 里残留指针文件，且其索引会陈旧 |
| 主仓库 LFS 未还原时，CMake 因 `startup.blend` 小于 1KB 直接报错 | 2.2.5 | 一致（`CMakeLists.txt:96`） |
| Visual Studio 生成器产物在 `bin/Release/`，Ninja 在 `bin/` | 2.1.2 / 2.3 | 一致：全量构建后确实落在 `bin/Release/blender.exe` |
| Windows 优先探测 `lib\windows_x64\python\313\bin\python.exe`，其次 `311` | 2.1.1 | 一致（`find_dependencies.cmd:5-23`） |

**结论**：未发现被镜像构建推翻的描述。本轮修正的"编译不需要主仓库 LFS 对象"一类错误出在
维护文档（`doc/README-BLENDER.md`、`AGENTS.md`），不在书稿。

## 多镜像拉取与构建：待补选题

- [x] **附录 E.1.1 增加"镜像获取"**：正文只保留官方流程与附录指引，附录给出面向读者的
  操作路径——给出 `projects.blender.org`（官方）、`github.com/blender/blender`（官方镜像）、
  `gitee.com/mirrors/blender`（Gitee/码云国内同步镜像）三个地址；写明镜像的两个坑：① 不托管主仓库 LFS
  对象，装了 git-lfs 时裸 `git clone` 会在 checkout 阶段失败；② Gitee 的发布分支顶端可能
  落后于官方。给出 `GIT_LFS_SKIP_SMUDGE=1` 克隆、`lfs-fallback` 远端、`git lfs pull` 的
  完整恢复流程，以及"先 `git ls-remote` 探测基准分支再决定是否下载"的省时做法。
- [x] **2.2.5 增加"如何确认 LFS 完整"**：用 `git lfs ls-files` 做全量核对，给出指针文件的
  判据（体积很小 + 首行 `version https://git-lfs`）；说明只查 `startup.blend` 不够——图标、
  画笔、ICC 配置缺失时 configure 仍会通过，产物却缺资源。
- [x] **2.2.3 / 2.6 增加"失败重试与断点续传"**：`git lfs pull` 可重复执行、只补缺口；给出
  可脚本化的重试策略（例如最多 10 次、每次间隔 10 秒，对应 `--retries` / `--retry-delay`
  一类参数）；说明中断后若 `git status` 把上千个 LFS 文件显示为已修改，应先检查
  `.git/index.lock`。
- [x] **2.2.3 增加"并发与服务器限速"的实测**：把 `lfs.concurrenttransfers` 从 32 提到 64
  只带来约 25% 提升（服务器端约 2 MiB/s 封顶），因此主仓库 LFS 与 `lib/` LFS 并行没有收益；
  可写成读者自测实验（写入书稿前需按目标版本重测并标注环境）。
- [x] **正文措辞统一**：已逐处检查书稿与图表源文件中的口语化表述，并按语境分别改为
  "运行"、"执行"、"构建"、"测试"、"渲染"、"遍历"、"求值"或"测量"；未采用机械替换，
  修改后重新完成全书排版检查。

## 写作时的注意事项

- 上述方法只在 Windows + MSVC + 单机上实测过一次；写进书稿前需按
  `book/blender-baseline.json` 的基准版本重新测量，并在正文标注平台与版本。
- 镜像状态会变（分支顶端、是否仍存在），附录应教读者"如何确认"，而不是写死某个 SHA。
