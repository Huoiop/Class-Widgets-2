# Class Widgets 2 —— 项目指引（给接手的 AI / 开发者）

> 这份文档的目的是：读完它就能直接开始改代码，不用再从头摸一遍。
> 内容基于对当前工作副本的实际阅读与运行验证，**已实测的结论会标注**，推测的会写"推测"。
> 最后更新：2026-09-27

---

## 0. 一句话背景

**Class Widgets 2（CW2）** 是一个 Windows 优先的**电子课程表小组件**：在桌面悬浮显示当前课程、倒计时、下节课、灵动通知等，配套课表编辑器、插件系统、插件广场、主题系统。

技术栈：**PySide6 6.10.3 + QML**，UI 组件库用第三方 **RinUI 0.4.4.1**（pip 依赖，不是本仓库代码），配置用 **Pydantic v2**，日志 loguru。

**当前工作副本是一个 fork**，不是原版：
- `src/__init__.py` 里 `__version__ = "2.0.0.huoiop.0927"`、`__version_type__ = "branch"`
- 已合入上游 main（含 51 个提交），并叠加了若干自定义改动（见 §7）
- **这个目录不是 git 仓库**，改动靠副本管理；远端 fork 是 `https://github.com/Huoiop/Class-Widgets-2`

---

## 1. 目录结构

```
Class-Widgets-2-main/
├── src/
│   ├── app.py                  入口（极薄）
│   ├── __init__.py             版本号、schema 版本、默认更新通道等常量
│   ├── core/                   全部 Python 逻辑
│   ├── qml/                    QML 界面（主窗口、设置、编辑器、广场、教程…）
│   ├── plugins/cw_widgets/     唯一的内置插件（注册 6 个小组件）
│   └── themes/                 内置主题（default 在 qml/ 里，另有 cw1/win10/material/vista）
├── assets/                     图片、音频、i18n 词条（locales/*.ts|qm）
├── configs/                    运行时数据（configs.json、schedules/）—— 已 gitignore
├── themes/                     用户安装的第三方主题
├── plugins/                    用户安装的第三方插件（源码运行时）
├── docs/                       多语言 README、课表格式模板
├── scripts/                    CI/打包脚本（Inno Setup、lupdate 等）
├── .github/workflows/          build&release.yml、i18n-update.yml
├── dist/                       构建产物（已 gitignore）
├── logs/                       运行时日志（已 gitignore）
├── RinUI/                      只是 RinUI 运行时写的配置目录，非代码
└── PROJECT_GUIDE.md            本文件
```

相关但不在仓库里的：
- Python 依赖装在 `.venv/`（**Python 3.12.10** —— 刻意与官方 release 对齐，见 §5.2）
- RinUI 真实代码在 `.venv/Lib/site-packages/RinUI/`
- 3.12 的解释器装在 `C:\Users\hutao\AppData\Local\Programs\Python\Python312\python.exe`
  （**不在 PATH 上**，避免抢占系统的 `python`；建 venv 时用这个全路径）

---

## 2. 启动流程与核心对象

### 2.1 入口

```
src/app.py
  ├─ wait_for_process_exit()      处理 --wait-for-pid（全仓库无人发送此参数，属遗留）
  ├─ QApplication + setQuitOnLastWindowClosed(False)
  └─ AppCentral().run() → app.exec()
```

### 2.2 AppCentral —— 上帝对象

`src/core/central.py` 的 `AppCentral` 是**单例**（重复构造抛异常），一次性构造所有子系统：

```
AppCentral.__init__
  _initialize_cores          ConfigManager / ThemeManager / WidgetListModel / AppWindowManager
  PlatformIntegration        单实例锁、窗口图标、AppUserModelID
  _initialize_notification   NotificationManager / NotificationService
  _initialize_utils          PluginAPI / AppTranslator / PluginManager / UtilsBackend
                             AutomationManager / UpdaterBridge
  _initialize_schedule_...   UnionUpdateTimer / ScheduleManager / ScheduleRuntime
                             ScheduleEditor / ClassSwapManager
  _initialize_ui_components  WidgetsWindow（主窗口）+ ThemeRecoveryController
```

`run()` → 载配置 → 载翻译 → `init()`，`init()` 内按序：
写日志 → 载课表 → 载换课记录 → 载 runtime+主题+插件 → 托盘 → 自动化任务 → 显示窗口。

**首次启动会被引导页拦截**：`app.tutorial_completed=false` 时只开 Tutorial 窗口并 return。

### 2.3 心跳

`UnionUpdateTimer`（`core/timer/union_update.py`）用 **50ms 定时器**轮询，在**秒数变化时**发一次 `tick`，即精确的 ~1Hz。它驱动：

- `AppCentral.update()` → `ScheduleRuntime.refresh()`
- `AutomationManager.update()` → 所有自动化任务

### 2.4 QML 上下文属性

`AppCentral.setup_qml_context(window)` 给每个窗口注入：

```
WidgetsModel, Configs, CWThemeManager, PluginManager, AppCentral,
WindowManager, PathManager, ClassSwapManager, UtilsBackend
```

QML 里就是靠这些名字访问 Python 对象的（`Configs.set(...)`、`AppCentral.scheduleRuntime` 等）。

---

## 3. 核心子系统

### 3.1 课程表（`src/core/schedule/`）

**数据模型**（`model.py`，Pydantic）：

```
ScheduleData { meta, subjects[], days[], overrides[] }
  MetaInfo    { id, version(=1), maxWeekCycle, startDate }
  Subject     { id, name, simplifiedName?, teacher?, icon?, color?, location?, isLocalClassroom }
  Timeline    { id, entries[], dayOfWeek[int]?, weeks("all"|int|[int])?, date? }   ← 一天
  Entry       { id, type(class|break|activity|free|preparation), startTime, endTime, subjectId?, title? }
  Timetable   { id, entryId, dayOfWeek?, weeks?, subjectId?, title?, startTime?, endTime? }  ← 覆盖
```

**匹配规则**：`date` 精确匹配优先 → 否则按 `dayOfWeek` + `weeks`（多周轮换）。`weeks` 为单个 int 时的语义是"从第 N 个循环周开始，每 maxWeekCycle 周一次"，不是"第 N 周"。

**角色分工**：

| 类 | 职责 |
|---|---|
| `ScheduleManager` | 课表文件的加载/保存/增删改查、只读模式 |
| `ScheduleServices` | 纯计算：解析当天的 Timeline、当前/下一条目、状态、进度 |
| `ScheduleRuntime` | 每秒刷新，把状态暴露成 QML 属性（见 §3.2） |
| `ScheduleEditor` | QML 编辑器的门面，**持有的是 manager 的同一个 ScheduleData 对象** |
| `ClassSwapManager` | 临时换课（见 §3.9） |
| `ScheduleParser` | 薄封装：JSON → 校验 version → ScheduleData |
| `convertor/` | CSES / CW1 / iCalendar(ICS) ↔ CW2 的互转 |

### 3.2 运行时状态机（`ScheduleRuntime`）

**状态只有 5 种**（`EntryType`）：`class` / `break` / `activity` / `free` / `preparation`

- `preparation` **优先级最高**：只要下一条 class/activity 在 `schedule.preparation_time`（默认 2 分钟）内开始，状态就是 preparation，哪怕当前还在课间
- 没有任何当前条目且没有临近的下一条 → `free`

**暴露给 QML 的属性**（都随 `updated` 信号刷新）：

```
currentTime / currentDayOfWeek / currentDate / currentWeek / currentWeekOfCycle / timeOffset
subjects / scheduleMeta / currentDayEntries / currentEntry / nextEntries
remainingTime{minute,second} / progress / currentStatus / currentSubject / currentTitle
```

⚠️ 两个坑：
- `progress` 在**没有当前条目时返回 1**，而 QML 侧属性又把 falsy 转成 0 → 空闲时进度条表现不一致
- `currentsChanged` 只在**条目发生变化**时发，不是状态变化
- 所有时间比较用的是 `now + schedule.time_offset`，但显示的 `currentTime` 是原始墙钟

### 3.3 插件系统（`src/core/plugin/`）

**插件包格式**：目录下有 `cwplugin.json`（**不是** plugin.json）+ 入口 `.py`，可选 `libs/`。

```jsonc
// cwplugin.json 必需字段
{ "id", "name", "version", "api_version", "entry", "author", "icon"? }
// api_version 是 PEP440 SpecifierSet，当前 SDK 版本 0.6.0
// entry 指向的 .py 里必须定义 class Plugin(CW2Plugin)
```

**生命周期**：扫描 → 只加载 `configs.plugins.enabled` 里的 → 实例化 → `on_load()`。

⚠️ **插件只在启动时加载**。启用/禁用、安装、卸载、更新**一律延迟到重启**（`markRestartRequired()`），没有运行时卸载路径。所以"启用后没反应"的第一个怀疑对象就是**没重启**。

**加载时会做**（`loader.py`）：
- 注入伪造模块 `sys.modules["ClassWidgets.SDK"]`
  - ✅ `from ClassWidgets.SDK import X` 可用
  - ❌ `import ClassWidgets.SDK` / `from ClassWidgets import SDK` **会失败**（没有伪造父包，实测确认）
- 把插件目录和 `libs/` 加进 `sys.path`（加载期间 `insert(0,...)`，之后 `append`）
- 外部插件的 `icon` 会被改写成 `QUrl.fromLocalFile(...)`

**插件 API 表面积**（`PluginAPI`）：`widgets / notification / schedule / schedulemanagement / globalconfig / application / diagnostics / theme / runtime / config / automation / actions / ui`。

**捆绑依赖的机制（重要，见 §6.3）**：插件的 `libs/` 里是打包时收集的**预编译二进制**，与打包者的 Python 版本绑定。

### 3.4 插件广场（`src/core/plaza/`）

- 默认地址 `https://plaza.cw.rinlit.cn`（`config.network.plaza_url`）
- Python 侧用 requests（只在 QThread 里跑），QML 侧大量直接 `XMLHttpRequest`
- 主要端点：`/api/plugins`（列表/分页/排序）、`/api/plugins/{id}`、`/resources/readme|icon|release`、`/api/banners`、`/api/plugins/search|tags|suggest|random|certified`
- 下载走 `PluginDownloader`：支持 HTTP Range 断点续传、100MB 上限、30s 停滞超时
- 没有应用内发评论的能力，"写评论"会打开网页

### 3.5 主题（`src/core/themes/`）

- 主题 = 目录下的 `cwtheme.json` + `ClassWidgets/theme/` 覆盖文件
- `ThemeUrlInterceptor` 把 QML 里的 `ClassWidgets/theme` 路径重写到当前主题；**基础 qmldir 不重写**（否则未覆盖的组件会丢）
- 内置 5 套：default（在 `src/qml`）、cw1、win10、material、vista
- ⚠️ 除 vista 外，**每个主题都整份重写 `Widget.qml`**，改组件接口要同步改所有主题

### 3.6 小组件（`src/core/widgets/`）

- 通过 `api.widgets.register(widget_id, name, qml_path, backend_obj, settings_qml, default_settings)` 注册
- 实例列表存在 `preferences.widgets_presets`，QML 侧由 `WidgetListModel` 暴露
- **启用插件 ≠ 显示组件**：组件还要单独"添加"到桌面（右键 → 编辑小组件界面 → 添加）
- 内置 6 个（来自 `src/plugins/cw_widgets`）：currentActivity、Time、eventCountdown、upcomingActivities、dynamicNotification、customText

### 3.7 窗口（`src/core/windows/`）

- **主窗口 `MainInterface.qml`**：无边框、置顶、尺寸≈整个屏幕；靠 `setMask(QRegion)` 做点击穿透（mask = 所有可见小组件的并集）
- 辅助窗口（Settings/Editor/PluginPlaza/Tutorial/WhatsNew/调试器/若干 Dialog）由 `AppWindowManager` **按名字懒加载并缓存**
- 辅助窗口各自持有独立 QML 引擎（非共享引擎）

### 3.8 配置（`src/core/config/`）

- 文件：`configs/configs.json`，Pydantic 模型在 `model.py`，8 个 section：
  `app / locale / schedule / preferences / interactions / plugins / network / notifications`
- **键锁**：`Configs.isKeyLocked("dotted.key")`，锁定的键写入会被静默拒绝
- ⚠️ 键锁对**字典项的写入无效**（`plugins.configs`、`reschedule_day` 等）

### 3.9 其它

| 子系统 | 位置 | 要点 |
|---|---|---|
| 通知 | `core/notification/` | 4 个等级；provider 制；可同时走系统托盘通知 + 应用内组件 + 音效 |
| 自动化 | `core/automations/` | 每秒 tick；`AutoHideTask`（Windows 专用 win32gui，上课/最大化/全屏自动隐藏）、`UpdateCheckTask`、`PlazaUpdateCheckTask` |
| 更新器 | `core/updater/` | 见 §3.10 |
| 换课 | `schedule/swapper.py` | 通过写 `overrides` 实现，记录存 `config.schedule.class_swap`，跨天在启动时清理 |
| 调休 | `config.schedule.reschedule_day` | `{日期: 星期}` 映射，覆盖当天按周几走 |

### 3.10 更新器

```
checkUpdate()  →  GET network.releases_url (https://classwidgets.rinlit.cn/2/releases.json)
                  按 configs.app.channel 取对应分组 → {version, url:{windows,...}}
                  比较方式：字符串不等即视为有更新
startDownload() →  %TEMP%/cw2_update/update.zip（仅 Windows；github.com 域名会走镜像前缀）
startInstall()  →  解压 → 生成 replace_and_restart.cmd → cmd /c 执行 → os._exit(0)
重启后带 --update-done → 删临时目录、打开「更新内容」窗口
```

⚠️ 已知问题（**实测确认**）：
- **覆盖目标是 `Path.cwd()`，不是 exe 所在目录**。从源码运行时 cwd 是项目根，点"安装"会用上游包覆盖整个源码树（真实发生过，被拦下）
- 不校验哈希/签名
- `os._exit(0)` 在回调前执行，`_on_install_finished` 里的 `restart()` 实际走不到
- 响应缺少 `content-length` 时 `downloaded/total` 会 ZeroDivisionError
- 比较是字符串不等，线上版本更旧也会提示"有更新"

---

## 4. 数据格式速查

### 4.1 课程表文件（`configs/schedules/*.json`）

```jsonc
{
  "meta": { "id": "...", "version": 1, "maxWeekCycle": 2, "startDate": "2026-09-01" },
  "subjects": [
    { "id": "math", "name": "数学", "simplifiedName": null, "teacher": "",
      "icon": "ic_fluent_ruler_24_regular", "color": "#0000FF",
      "location": "9101", "isLocalClassroom": true }
  ],
  "days": [
    { "id": "Monday-All", "dayOfWeek": [1], "weeks": "all", "date": null,
      "entries": [
        { "id": "e1", "type": "class", "subjectId": "math",
          "startTime": "10:00", "endTime": "12:00", "title": null }
      ] }
  ],
  "overrides": [
    { "id": "swap_xxx", "entryId": "e1", "dayOfWeek": [1], "weeks": "all",
      "subjectId": "physics", "title": null, "startTime": null, "endTime": null }
  ]
}
```

⚠️ 字段名注意：是 `isLocalClassroom`（小写 r）；写成 `isLocalClassRoom` 会被 Pydantic 静默忽略。

### 4.2 配置（`configs/configs.json`）

8 个 section，详见 `src/core/config/model.py`。几个常打交道的：

```
app.version / app.channel / app.tutorial_completed / app.debug_mode / app.no_logs
schedule.current_schedule / preparation_time / time_offset / default_duration
preferences.current_theme / scale_factor / opacity / widgets_anchor / widgets_presets / font
interactions.hide.{state,in_class,clicked,maximized,fullscreen,action,fully_hide,no_hide_subjects}
interactions.tapped_action / interactions.hover_fade
plugins.enabled / plugins.configs / plugins.pending_operations
network.releases_url / auto_check_updates / plaza_url / mirrors / current_mirror
notifications.enabled / volume / providers
```

### 4.3 路径规则

所有路径都相对**源码根目录**（源码运行）或**exe 所在目录**（打包后），**没有 AppData/XDG 概念**：

```
configs/  logs/  plugins/  themes/  assets/  src/qml/
```

`PathManager` 给 QML 提供 `root(name)` / `assets(name)` / `qml(name)` / `images(name)`，返回 `file://` URI。

---

## 5. 开发环境与运行

### 5.1 运行（源码）

```bash
cd "D:/Huoiop 项目/Class-Widgets-2-main"
PYTHONIOENCODING=utf-8 PYTHONUTF8=1 .venv/Scripts/python.exe src/app.py
```

⚠️ **必须带 UTF-8 环境变量**。RinUI 启动时会 `print("✨ RinUIWindow Initializing")`，中文 Windows 控制台默认 GBK，编码不出来直接崩：

```
UnicodeEncodeError: 'gbk' codec can't encode character '\u2728'
```

（双击打包版没这个问题，因为它没有控制台。）

### 5.2 构建打包

> **统一用 Python 3.12 构建。**
>
> 理由：PyInstaller 会把「运行它的那个解释器」打进包，而**插件的预编译依赖与应用的 Python
> 版本强绑定**（见 §6.3）。官方 release 是 3.12，本机也就统一到 3.12，这样自己打的包和官方包
> 对插件是通用的，不会出现"某插件在官方版能用、在自己打的包上加载失败"。
>
> 本机 `.venv` 就是 3.12，所以下面的命令直接用即可。
> 3.12 解释器**不在 PATH 上**（避免抢占系统的 `python`），需要时用全路径：
> `C:\Users\hutao\AppData\Local\Programs\Python\Python312\python.exe`

与 CI 完全一致的命令（`.venv/Scripts/pyinstaller.exe` 是 uv trampoline，用不了，走 `-m`）：

```bash
cd "D:/Huoiop 项目/Class-Widgets-2-main"
PYTHONIOENCODING=utf-8 .venv/Scripts/python.exe -m PyInstaller --noconfirm --noconsole \
  --icon "assets/images/logo.ico" \
  --add-data "src/qml:src/qml" --add-data "src/plugins:src/plugins" \
  --add-data "src/themes:src/themes" --add-data "assets:assets" --add-data "LICENSE:." \
  --paths=. --contents-directory . --name="Class Widgets 2" src/app.py
```

然后走 CI 的后续两步：

```bash
# 1) 清理多余 Qt 文件（清单在 scripts/qt_files_clean-Windows.json，38 项）
#    目标是 dist/Class Widgets 2/PySide6/<条目>，删完 455MB → 220MB
# 2) 打包 zip（CI 用 PowerShell）
powershell -NoProfile -Command "Compress-Archive -Path 'dist/Class Widgets 2/*' -DestinationPath 'dist/ClassWidgets-2-Windows.zip'"
```

产物：`dist/ClassWidgets-2-Windows.zip`（约 95–96MB，内容在 zip 根目录，解压即用）。

### 5.3 验证 QML 改动（推荐的实测方法）

**不要只靠肉眼看代码**。这套项目有两个坑（§6.1、§6.2）会让"看起来对"的 QML 实际不工作。推荐两种手段：

**A. 渲染截图**（最直观）——用 `QQmlComponent` 加载组件、`QTest.qWait()` 等动画跑完，然后 `window.grabWindow().save(png)`，直接看图确认。

**B. 实例化 + 断言**——用桩对象（`Configs` / `AppCentral`）建 `QQmlEngine`：

```python
engine.addImportPath("<项目>/src/qml")
engine.addImportPath("<项目>/.venv/Lib/site-packages")   # RinUI
ctx.setContextProperty("Configs", configs_stub)
ctx.setContextProperty("AppCentral", appcentral_stub)
# 读取 QML 的属性用 .toVariant()，QML 的 var 到 Python 是 QJSValue
```

⚠️ 两个环境陷阱（都踩过）：
- **`QT_QPA_PLATFORM=offscreen` 下字体度量是坏的**，文本宽度全为 0，测出来的尺寸不可信 → **量尺寸必须用真实平台**
- offscreen 下 `Popup`/`Dialog` **不会真正打开**，`onAboutToShow` 不触发 → 要么用真实平台，要么手动 `emit`

### 5.4 语法检查

```bash
# QML（注意：RinUI 的 qmldir 本身有坏条目，会刷一堆 unresolved-type 警告，
#      拿仓库里已有的文件做基线对比，只看有没有 Error/Critical）
.venv/Lib/site-packages/PySide6/qmllint.exe -I src/qml -I .venv/Lib/site-packages <文件>

# Python
.venv/Scripts/python.exe -m py_compile <文件>
.venv/Scripts/python.exe -m compileall -q src/
```

### 5.5 日志

- 源码运行：`logs/ClassWidgets-<时间>.log`（同一进程可能因重启写多个文件）
- 打包版：`dist/Class Widgets 2/logs/`
- 插件加载失败、QML 警告都在这里；**调试界面看不到的失败，第一站就是日志**

### 5.6 重建 venv（环境坏了 / 换机器时）

本机统一用 **Python 3.12**，但 3.12 **不在 PATH 上**（见 §5.2），建 venv 要用全路径：

```bash
PY312="C:/Users/hutao/AppData/Local/Programs/Python/Python312/python.exe"
"$PY312" -m venv .venv

# 依赖按 pyproject.toml 装
.venv/Scripts/python.exe -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple \
  PySide6~=6.10.3 "RinUI>=0.4.4.1" loguru packaging pydantic pyyaml requests \
  markdown-it-py "icalendar~=7.3.0" "recurring-ical-events~=3.8.2" "tzdata~=2026.4" pyinstaller
```

⚠️ 两个坑：

- **别用 `requirements.txt`** —— 它 pin 的版本和实际能装的**对不上**（`requests~=2.33.0` 而实际是
  2.34.2、`pydantic~=2.12.0` 实际 2.13.5、还不含 pyinstaller）。CI 其实走的是 `pyproject.toml` +
  `uv.lock`，那个文件基本是遗留物。
- **全局 pip 源（阿里云）下 PySide6 会截断**，报
  `ERROR: THESE PACKAGES DO NOT MATCH THE HASHES FROM THE REQUIREMENTS FILE`。
  用 `-i` 临时换清华源即可，**不要改全局配置**。

（`pywin32` 不用手动装 —— 它是 RinUI 的依赖，`sys_platform == 'win32'` 时自动带上。）

---

## 6. 踩坑清单（重要，都是实际踩到的）

### 6.1 Python 传来的 list 不是真正的 JS 数组

`Configs.data` 里的列表、`@Slot(result=list)` 返回的列表，在 QML 侧 `Array.isArray()` **为 false**，是个"类数组对象"。

**后果**：直接当 `Repeater` 的 model → **一个子项都渲染不出来**（静默，无报错）。

```qml
// ❌ 会渲染不出任何东西
Repeater { model: somePythonList; ... }
// ✅ 先转成真数组
function toArray(v) { var o=[]; if(v && typeof v.length==="number") for(var i=0;i<v.length;i++) o.push(v[i]); return o }
```

### 6.2 Repeater delegate 的勾选态只在创建时读一次

`Component.onCompleted: checked = ...` 是一次性赋值。如果**先**赋值 model（触发 delegate 重建）、**后**赋值选中列表，所有 delegate 都会显示未选中。

**正确顺序**：先把选中数据准备好，最后再赋值 model。

### 6.3 插件的预编译依赖与应用的 Python 版本强绑定

插件 `libs/` 里的 `.pyd` 带 ABI 标签（`cp312` / `cp313` / `cp314`），**必须与应用运行的 Python 版本精确一致**。

判断"会不会出事"的三条件（同时满足才炸）：
1. 库含编译扩展（`.pyd`/`.so`）
2. 应用**自己没用过**这个库（不在 `sys.modules` 里）
3. 插件捆的二进制与应用 Python 版本不一致

（因为 `sys.modules` 优先级 > `sys.path`，应用启动时已加载的模块会直接命中内存，插件捆的那份不会被读。）

⚠️ 顺带：**CW2 的应用包内嵌的 Python 版本，取决于构建时用的解释器**（PyInstaller 会把运行它的解释器打包）。
- 官方 release 2.0.1.0 = **Python 3.12**（实测 `python312.dll`，包内 `.pyd` 全 cp312）
- 本机 `.venv` 也是 **Python 3.12**（刻意对齐官方，详见 §5.2）
- `pyproject.toml` 是区间 `>=3.12,<3.14`，语法上 3.13 也合法 —— 但**插件二进制不能通用**，
  所以本机统一用 3.12，避免"自己打的包和官方包插件不通用"

### 6.4 lupdate 不能只对单个文件跑

`pyside6-lupdate <单个文件> -ts zh_CN.ts` 会把**其他所有文件**的词条标成 `type="vanished"`，`lrelease` 编译后中文界面会**整个丢翻译**。

正确做法：全量扫描（`scripts/update_ts.sh` 里的写法）。

```bash
.venv/Lib/site-packages/PySide6/lupdate.exe $(find src/ -name "*.py" -o -name "*.qml") -ts assets/locales/zh_CN.ts
.venv/Lib/site-packages/PySide6/lrelease.exe assets/locales/zh_CN.ts
```

### 6.5 其它零散坑

| 坑 | 说明 |
|---|---|
| 单实例锁 | `%TEMP%/ClassWidgets2.lock`。强杀进程后会残留，重启应用前可能要手动删 |
| 强制结束进程 | 会跳过 `cleanup()`（配置保存、锁释放）。优先用应用内退出 |
| `dist/` 是旧产物 | 改了源码后 `dist/` 不会自动更新，容易误以为是新版本 |
| `.spec` / `build/` / `dist/` / `configs/` | 都在 `.gitignore` 里，别提交 |

---

## 7. 本 fork 的现状

### 7.1 已合入上游

本地的 0927 分支已经**合并过上游 main 的 51 个提交**（合并点 `51bd20f`），合并时的冲突只有两处：
- `Time.qml` 的文案措辞（保留本分支的 `Advance Time`）
- `assets/locales/zh_CN.qm`（二进制，从合并后的 `.ts` 重新编译）

合并带来了新依赖：`icalendar` / `recurring-ical-events` / `tzdata`（ICS 导入功能需要，已装）。

### 7.2 本 fork 的自定义改动

| 功能 | 位置 |
|---|---|
| 版本号 `2.0.0.huoiop.0927`、默认更新通道 `__update_channel__ = "huoiop"` | `src/__init__.py` |
| 更新通道「Huoiop 特调」（走 `api.huoiop.cn/updates/check/cw2`） | `core/updater/workers.py`、`pages/settings/Update.qml` |
| 通道选择不再被启动时重置 | `core/config/manager.py` 的 `_ensure_defaults` |
| 「永不自动隐藏的课程」改为弹窗勾选、覆盖所有自动隐藏触发条件 | `builtin_tasks.py`、`config/model.py`、`schedule/manager.py`、`dialogs/NeverHideCoursesPopup.qml`、`pages/settings/General/Interactions.qml` |
| 预备铃时显示「即将开始」 | `widgets/currentActivity.qml`、`Theme/components/FloatingWidget.qml` |
| 主窗口高度比屏幕少 1px（避免被 Windows 判定为全屏窗口、遮住任务栏） | `MainInterface.qml` |
| `fully_hide`（完全隐藏）、`auto_check_updates` 默认关闭 | `config/model.py` |
| 灵动通知期间临时恢复被隐藏的小组件 | `widgets/dynamicNotification.qml` |
| 补了 103 条简体中文翻译（课程编辑器相关界面） | `assets/locales/zh_CN.ts` |

### 7.3 远端分支（`github.com/Huoiop/Class-Widgets-2`）

| 分支 | 用途 |
|---|---|
| `main` | 干净的上游 fork |
| `2.0.0.dev31546377(0906)` / `(0926)` / `(0927)` | 自定义构建线，0927 最新 |
| `pr-course-exempt` | 上游 PR #198（永不自动隐藏功能，**Open**，已按评审改过注释） |
| `pr-activity-starting-soon` | 预备铃文案，已提 PR，评审要求把 "Class starting soon" 改成 "Starting soon"（已改） |
| `pr-widget-window-height` | 主窗口高度 -1px，评审要求精简注释（已改） |
| `pr-editor-drag-fix` / `pr-fully-hide` / `pr-prep-time-ui` / `pr-reveal-on-notification` | 其它功能分支 |

⚠️ **提 PR 的限制**：当前用的是**细粒度 PAT**，对别人名下的公开仓库（上游）只有只读权限 → **无法用 API 创建/修改上游的 PR**，只能推分支到 fork，再由用户在网页上开 PR。推 fork 分支本身是通的。

---

## 8. 已知问题（已定位，尚未修）

按严重程度排：

1. **课程表解析失败会销毁原文件** —— `schedule/manager.py` 的 `load()` 异常分支里，备份路径拼成了 `xxx.json/backup/....json`（`schedule_path` 是文件不是目录），备份必然失败且被吞掉，紧接着用空课表覆盖**原文件**。任何 JSON/校验/版本错误 → 原课表永久丢失。**实测复现过。**
2. **更新器覆盖目标是 `Path.cwd()`** —— 见 §3.10
3. **插件加载失败在界面上完全不可见** —— 插件显示"已启用"，但组件列表里没有，只有日志有原因（用户已就此事向上游提建议）
4. `AddWidgetsDialog.qml` 连接了不存在的 `themeReloadStarted` 信号（QML 警告）
5. `ThemeAPI.current()` 读 `themeManager.current_theme`，实际属性是 `currentTheme` → 调用即抛异常
6. `UtilsBackend.getGlobalVolume/setGlobalVolume` 重复定义（后者生效）
7. `ConfigManager.save_timer` 建了但从未 `start()`
8. `UpdateCheckTask` 每次触发都重复 `connect` 一次 `updateAvailable`，只在成功路径 disconnect → 连接会累积
9. `src/app.py` 的 `--wait-for-pid` 全仓库无人发送，属遗留代码

---

## 9. 工作约定（用户偏好，务必遵守）

这些是用户在协作中明确提出过的：

1. **界面文案直接用简体中文**，不需要手工做翻译 —— `.ts` / `.qm` 由 GitHub / Weblate 的自动化流程处理，**不要手改翻译文件**
2. **提交给上游的 PR 用英文原文**（`qsTr("Starting soon")`），配合项目既有惯例；其他语言交给自动翻译
3. **注释要精简** —— 只保留必要的"为什么"，不要大段铺垫。这条被上游评审提过两次
4. **验证要实测**，不要只看代码 —— QML 改动尽量用实例化/截图验证；改完 Python 至少 `py_compile`
5. **改动范围要克制** —— 用户多次强调"只做要求的事"，不要顺手重构无关代码
6. **提 PR 到上游需要用户手动创建**（原因见 §7.3），GitHub 的 "Sync fork / 丢弃提交" 按钮**不要点**（会抹掉自定义提交）

---

## 10. 快速上手检查清单

接手新任务时建议先做：

- [ ] 确认要改的是**源码运行**（`.venv`，3.12）还是**打包版**（`dist/`）—— 两者的
      `configs/`、`plugins/`、`themes/`、`logs/` 是**两套独立目录**，别改错地方
- [ ] 读一遍本文件的 §3 对应子系统 + §6 踩坑清单
- [ ] 改 QML 前先想清楚 §6.1 / §6.2 两个坑
- [ ] 改完跑 `py_compile` / `qmllint`，再按 §5.3 做一次实测
- [ ] 启动验证时记得带 `PYTHONIOENCODING=utf-8 PYTHONUTF8=1`（或直接双击 `run_dev.cmd`）
- [ ] 打包时确认用的是 **Python 3.12**（§5.2）
- [ ] 涉及插件/主题/更新的改动，注意 `configs/`、`dist/`、远端分支的现状（§7）
