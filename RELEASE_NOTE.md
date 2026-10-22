# Release Note

## 0.2.1

- 澄清 §1.2.2 中整份 `.blend` 文件的读取入口与 SDNA 数据解析函数的区别，并修复相关段落中由源码换行产生的异常空格。

## 0.2.0

- 新增实验性 HTML 输出：支持自定义样式、预渲染 Cetz 图表为 SVG，并按字体模式准备网页字体资源。

## 0.1.1

- 修复了前言中关于所涉及编程语言种类的描述，去掉并不存在的 Typst 语言。

# Pending

- 新增 `scons init-blender --mirror=github|gitee`（默认 `official`）：只切换 Blender 主仓库的克隆来源；镜像缺少基准分支或基准 commit 时先探测再失败，`--mirror-url` 可指向自建镜像。
- `init-blender` 现在在所有平台（含 Windows）非交互准备 `lib/` 预编译库与主仓库 LFS，`scons init-blender` 成功后源码、LFS、依赖库三者即为就绪；`build-blender` 只核验，缺任一项时在 configure 之前失败并指回 `scons init-blender`，不再依赖上游 `make.bat` 的交互询问。
- 克隆与子模块更新一律跳过 LFS smudge 后并发补齐（实测把 `projects.blender.org` 从 0.43 MiB/s 提到 1.6 MiB/s），并按 `git lfs ls-files` 全量核对，避免"半个 LFS"的树通过配置却产出缺图标/画笔/ICC 数据的 Blender。
