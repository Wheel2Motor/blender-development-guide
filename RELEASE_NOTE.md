# Release Note

## 0.2.3

- 将非官方源码镜像的具体地址与操作流程从第 2 章正文移至附录 E；正文恢复为 Blender 官方仓库流程，仅提示网络不稳定时可改用镜像，并将 Gitee（码云）准确表述为国内代码托管平台上的同步镜像。
- 面向只掌握基本 Git 或主要使用 SVN 的读者补充 Git LFS 入门：解释指针、远端对象、本地缓存与工作区的关系，列出 Blender 固定基准中的 LFS 内容分布，并区分 Git 子模块与 Git LFS。
- 统一全书口语化的"跑"字表述，按实际语义改为运行、执行、构建、测试、渲染、求值或测量等准确动词，并同步修订图表文字与章节标题。

## 0.2.2

- 新增 `scons init-blender --mirror=github|gitee`（默认 `official`）：只切换 Blender 主仓库的克隆来源；镜像缺少基准分支或基准 commit 时先探测再失败，`--mirror-url` 可指向自建镜像。
- `init-blender` 现在在所有平台（含 Windows）非交互准备 `lib/` 预编译库与主仓库 LFS，`scons init-blender` 成功后源码、LFS、依赖库三者即为就绪；`build-blender` 只核验，缺任一项时在 configure 之前失败并指回 `scons init-blender`，不再依赖上游 `make.bat` 的交互询问。
- 克隆与子模块更新一律跳过 LFS smudge 后并发补齐（实测把 `projects.blender.org` 从 0.43 MiB/s 提到 1.6 MiB/s），并按 `git lfs ls-files` 全量核对，避免"半个 LFS"的树通过配置却产出缺图标/画笔/ICC 数据的 Blender。
- 所有联网步骤失败后自动重试：默认最多再试 10 次、每次间隔 10 秒，可用 `scons init-blender --retries=N --retry-delay=SECONDS` 调整；克隆重试前会清理没拉取完成的目录。
- 扩充第 2 章的源码获取与依赖说明：补充官方、GitHub、Gitee 镜像的探测与 LFS 回退流程，说明全量 LFS 验收、失败续传、残留 `index.lock` 处理和并发限速实测，并统一该章相关措辞。
- 修正 `init-blender --check-only` 的 LFS 成功日志，使其准确区分完整 tracked-file 清单检查与无 Git LFS 时的 fallback 抽样检查。

## 0.2.1

- 澄清 §1.2.2 中整份 `.blend` 文件的读取入口与 SDNA 数据解析函数的区别，并修复相关段落中由源码换行产生的异常空格。

## 0.2.0

- 新增实验性 HTML 输出：支持自定义样式、预渲染 Cetz 图表为 SVG，并按字体模式准备网页字体资源。

## 0.1.1

- 修复了前言中关于所涉及编程语言种类的描述，去掉并不存在的 Typst 语言。

# Pending
