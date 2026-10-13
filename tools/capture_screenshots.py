# SPDX-License-Identifier: GPL-2.0-or-later
"""《Blender 开发指南》—— 实机截图采集脚本。

用法（GUI 模式，不要用 --background，因为区域截图需要真实窗口）：

    <构建目录>\\bin\\blender.exe --factory-startup --python capture_screenshots.py

它做四件事：
1. 把 example_addon 装进**当前这个 Blender 的用户脚本目录**（只影响本构建的配置，
   不会动你机器上其它版本 Blender 的设置）；
2. 建一个带网格对象的场景，并选中一个对象；
3. 打开 3D 视图侧栏（N 面板），使示例插件的「Guide」面板可见；
4. 逐区域截图，写到 <仓库根>/book/res/ 下（平铺，无子目录）。

所有路径都由本脚本自身位置推算，不写死盘符：脚本在 <仓库根>/tools/ 下，
于是插件的**源目录**是同级 `example_addon/`，截图**输出目录**是 `../book/res/`，
运行时的临时用户脚本目录是 `tools/_user_scripts/`。
截图文件名保持 `NN-描述.png` 原名（**不加 `raw-` 前缀**），与 book/res/ 里
书中插图所用的 `fig-` 前缀天然不冲突。

截图优先使用 `bpy.ops.screen.screenshot_area`（按当前区域裁剪，天然满足
「优先只截局部区域」的要求），只有整窗图用 `bpy.ops.screen.screenshot`。
`SCREEN_OT_screenshot_area` 在 5.2 的实现见 source/blender/editors/screen/screendump.cc。
"""

import faulthandler
import os
import shutil
import sys
import traceback

import bpy
import addon_utils

# 崩溃时把 Python 栈打到 stderr —— 段错误（0xC0000005）也能拿到位置
faulthandler.enable()

# Windows 控制台默认是 GBK：Blender 里打印非 ASCII（路径里也可能有）会抛
# UnicodeEncodeError。统一切到 UTF-8 并放宽错误处理；面向用户的输出一律用英文
# （见 AGENTS.md §五）。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

HERE = os.path.dirname(os.path.abspath(__file__))          # <仓库根>/tools
REPO_ROOT = os.path.dirname(HERE)                           # <仓库根>
ADDON_SRC = os.path.join(HERE, "example_addon")             # 工具自带的示例插件
ADDON_MODULE = "example_addon"
BOOK_RES = os.path.join(REPO_ROOT, "book", "res")           # 截图落到这里（平铺）
USER_SCRIPTS = os.path.join(HERE, "_user_scripts")          # 运行时临时装插件用
OUT_DIR = BOOK_RES
LOG = []


def log(msg):
    print("[capture] %s" % msg)
    sys.stdout.flush()
    sys.stderr.flush()
    LOG.append(msg)


def ensure_dirs():
    """确保输出目录与临时用户脚本目录存在（它们都可能被清空过）。"""
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(USER_SCRIPTS, exist_ok=True)


# ---------------------------------------------------------------------------
# 1) 安装并启用示例插件
# ---------------------------------------------------------------------------
def install_example_addon():
    """把示例插件装进本工程自己的用户脚本目录。

    默认装到 `tools/_user_scripts/`（已 gitignore），这样截图**不会动**你机器上
    其它 Blender 版本的配置，也不会在书稿资源目录 `book/res/` 里留下 `.py` 文件。

    仍然优先尊重 `BLENDER_USER_SCRIPTS` 环境变量——这正是本书第 4 章讲的官方机制。
    不指定时**不能**依赖 `bpy.utils.user_resource("SCRIPTS")`：那会落到
    `%APPDATA%\\Blender Foundation\\Blender\\5.2\\scripts`，而在本机上那个目录
    对当前进程不可写（Windows 返回 PermissionError [Errno 13]），
    会导致插件装不上、截不到我们自己的面板。
    """
    override = os.environ.get("BLENDER_USER_SCRIPTS")
    if override:
        addons_dir = os.path.join(override, "addons")
    else:
        addons_dir = os.path.join(USER_SCRIPTS, "addons")

    dst = os.path.join(addons_dir, ADDON_MODULE)
    os.makedirs(addons_dir, exist_ok=True)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(ADDON_SRC, dst)
    log("copied the example addon to %s" % dst)

    # 让 Blender 重新扫描 addons 目录，否则新复制的插件不会被发现
    addon_utils.modules_refresh()
    bpy.ops.preferences.addon_enable(module=ADDON_MODULE)
    log("enabled addon %s" % ADDON_MODULE)


# ---------------------------------------------------------------------------
# 2) 场景准备
# ---------------------------------------------------------------------------
def prepare_scene():
    # 【不要】在这里调用 bpy.ops.wm.read_factory_settings()。
    # 它会在启动脚本里重置整个 Blender 状态，实测直接导致访问冲突
    # （exit code 0xC0000005）。命令行已经传了 --factory-startup，足够干净。
    scene = bpy.context.scene

    # 关掉资源库索引。默认场景会为内置 essentials 资源库建索引，
    # 在无缓存的机器上实测要跑 2 分半并刷出一屏 ERROR，与截图无关。
    try:
        prefs = bpy.context.preferences
        prefs.filepaths.use_asset_indexing = False
        log("asset-library indexing disabled")
    except Exception as exc:  # noqa: BLE001
        log("could not disable asset-library indexing (continuing): %s" % exc)

    # 选中一个网格对象，让插件面板有内容可显示
    for obj in scene.objects:
        if obj.type == "MESH":
            obj.select_set(True)
            bpy.context.view_layer.objects.active = obj
            log("selected mesh object %s (%d vertices)" % (obj.name, len(obj.data.vertices)))
            break

    # 打开 3D 视图侧栏，让指南面板可见
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type == "VIEW_3D":
                area.spaces.active.show_region_ui = True
                area.spaces.active.show_region_toolbar = True
    log("opened the 3D viewport sidebar (N panel)")


# ---------------------------------------------------------------------------
# 3) 截图原语
# ---------------------------------------------------------------------------
def screenshot_area(area, path, region_type=None):
    """按区域裁剪截图。region_type 为空时用该区域的第一个 region。"""
    region = None
    if region_type:
        region = next((r for r in area.regions if r.type == region_type), None)
    if region is None:
        region = next((r for r in area.regions if r.type == "WINDOW"), area.regions[0])

    log("capturing (area %s) -> %s" % (area.type, os.path.basename(path)))
    with bpy.context.temp_override(
        window=bpy.context.window_manager.windows[0],
        screen=area.id_data,
        area=area,
        region=region,
    ):
        bpy.ops.screen.screenshot_area("EXEC_DEFAULT", filepath=path)
    return os.path.exists(path)


def screenshot_window(path, window):
    log("capturing (whole window) -> %s" % os.path.basename(path))
    with bpy.context.temp_override(window=window, screen=window.screen):
        bpy.ops.screen.screenshot("EXEC_DEFAULT", filepath=path)
    return os.path.exists(path)


def find_area(area_type, workspace_name=None):
    for window in bpy.context.window_manager.windows:
        for screen in (window.screen,):
            if workspace_name and screen.workspace and screen.workspace.name != workspace_name:
                continue
            for area in screen.areas:
                if area.type == area_type:
                    return window, area
    return None, None


def force_redraw():
    """强制界面重绘一次。

    没有这一步，切换工作区之后 `window.screen.areas` 还是旧工作区的布局，
    于是 CONSOLE / TEXT_EDITOR / INFO 这些区域会"找不到"（实测如此）。
    """
    try:
        bpy.ops.wm.redraw_timer(type="DRAW_WIN_SWAP", iterations=2)
    except Exception as exc:  # noqa: BLE001
        log("forced redraw failed (continuing): %s" % exc)


def activate_workspace(name):
    for window in bpy.context.window_manager.windows:
        for ws in bpy.data.workspaces:
            if ws.name == name:
                try:
                    window.workspace = ws
                    force_redraw()
                    log("switched to workspace %s" % name)
                    return True
                except Exception as exc:  # noqa: BLE001
                    log("could not switch to workspace %s: %s" % (name, exc))
    return False


# ---------------------------------------------------------------------------
# 4) 逐张采集
# ---------------------------------------------------------------------------
def set_area_type(area, new_type):
    """把某个区域改成另一种编辑器。

    为什么不用 `window.workspace = ws` 切工作区：实测在 5.2 里**不生效**——
    赋值后 `window.screen` 仍然停在 'Layout'（诊断输出证实），
    于是 CONSOLE / TEXT_EDITOR / INFO 全都找不到。
    直接改 `area.type` 是可靠的：ScrArea.type 在 RNA 里可写。
    """
    try:
        area.type = new_type
        force_redraw()
        log("area type changed to %s" % new_type)
        return True
    except Exception as exc:  # noqa: BLE001
        log("could not change area type to %s: %s" % (new_type, exc))
        return False


def capture_all():
    wm = bpy.context.window_manager
    window = wm.windows[0]
    shots = []

    def current_areas():
        return list(window.screen.areas)

    def area_of(t):
        for a in current_areas():
            if a.type == t:
                return a
        return None

    # 进度文件放在临时目录而不是资源目录：book/res/ 只放图片
    progress = os.path.join(USER_SCRIPTS, "_capture_progress.txt")

    def note(msg):
        """把进度同步落盘：万一 Blender 硬崩，也知道走到哪一步了。"""
        log(msg)
        try:
            with open(progress, "a", encoding="utf-8") as f:
                f.write(msg + "\n")
        except Exception:  # noqa: BLE001
            pass

    if os.path.exists(progress):
        os.remove(progress)

    # === 第一阶段：用默认的 Layout 布局，截 3D 视图与 Outliner ===
    note("stage 1: Layout workspace, starting areas = %s" % [a.type for a in current_areas()])

    view3d = area_of("VIEW_3D")
    if view3d:
        view3d.spaces.active.show_region_ui = True
        force_redraw()
        p = os.path.join(OUT_DIR, "05-viewport-sidebar-guide-panel.png")
        if screenshot_area(view3d, p, "WINDOW"):
            shots.append(("3D 视图 + Guide 侧栏面板", p))

    outliner = area_of("OUTLINER")
    if outliner:
        try:
            outliner.spaces.active.display_mode = "LIBRARIES"
            force_redraw()
        except Exception as exc:  # noqa: BLE001
            note("could not switch the Outliner mode: %s" % exc)
        p = os.path.join(OUT_DIR, "06-outliner-datablocks.png")
        if screenshot_area(outliner, p, "WINDOW"):
            shots.append(("Outliner（Blender File 数据块视图）", p))

    # === 第二阶段：把几个区域改造成脚本类编辑器 ===
    note("stage 2: converting area types")

    # Properties -> Info（操作符的 report 会显示在这里）
    props = area_of("PROPERTIES")
    if props:
        if set_area_type(props, "INFO"):
            p = os.path.join(OUT_DIR, "04-info-editor.png")
            if screenshot_area(props, p, "WINDOW"):
                shots.append(("Info 编辑器（操作符 report）", p))

    # Outliner -> Text Editor
    outliner = area_of("OUTLINER")
    if outliner:
        if set_area_type(outliner, "TEXT_EDITOR"):
            p = os.path.join(OUT_DIR, "03-text-editor.png")
            if screenshot_area(outliner, p, "WINDOW"):
                shots.append(("文本编辑器", p))

    # Dopesheet -> Python 控制台
    dope = area_of("DOPESHEET_EDITOR")
    if dope:
        if set_area_type(dope, "CONSOLE"):
            p = os.path.join(OUT_DIR, "02-python-console.png")
            if screenshot_area(dope, p, "WINDOW"):
                shots.append(("Python 控制台", p))

    # 最后来一张整窗图：此时窗口里同时有 Info + 文本编辑器 + Python 控制台
    force_redraw()
    p = os.path.join(OUT_DIR, "01-script-editors-overview.png")
    if screenshot_window(p, window):
        shots.append(("脚本类编辑器总览（整窗）", p))

    # 说明：偏好设置窗口**故意不做**（模态窗口会让 Blender 无法正常退出，
    # 实测在桌面上留下一个卡死的 Preferences 窗口，只能结束进程清掉）。
    note("preferences window skipped by design")

    return shots


def main():
    log("Blender %s starting" % bpy.app.version_string)
    log("screenshot output dir: %s" % OUT_DIR)
    log("temporary user-scripts dir: %s" % USER_SCRIPTS)
    ensure_dirs()
    try:
        install_example_addon()
    except Exception:  # noqa: BLE001
        log("failed to install the example addon:\n%s" % traceback.format_exc())
    try:
        prepare_scene()
    except Exception:  # noqa: BLE001
        log("scene preparation failed:\n%s" % traceback.format_exc())

    shots = []
    try:
        shots = capture_all()
    except Exception:  # noqa: BLE001
        log("capture error:\n%s" % traceback.format_exc())

    print("\n===== capture results =====")
    for name, path in shots:
        size = os.path.getsize(path) if os.path.exists(path) else 0
        print("OK   %-36s %8d B  %s" % (name, size, os.path.basename(path)))
    if not shots:
        print("(no screenshot was captured)")
    print("===========================\n")

    # 截图完成后退出，避免留一个窗口占着用户桌面
    bpy.ops.wm.quit_blender()


if __name__ == "__main__":
    main()
