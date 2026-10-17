# Class Widgets 2 —— 项目指引（给接手的 AI / 开发者）

> 这份文档的目的是：读完它就能直接开始改代码，不用再从头摸一遍。
> 内容基于对当前工作副本的实际阅读与运行验证，**已实测的结论会标注**，仅由代码推断的会写“代码路径”。
> 最后更新：2026-10-17（合并上游 `4b745ab` / tag `2.0.0.dev20261014` 之后）
> 在以后的开发过程中，你可以随时对本文档进行更新，以确保其符合项目的最新状况。

---

## 0. 一句话背景

**Class Widgets 2（CW2）** 是一个 Windows 优先的**电子课程表小组件**：在桌面悬浮显示当前课程、倒计时、下节课、灵动通知等，配套课表编辑器、插件系统、插件广场、主题系统。

技术栈：**PySide6 6.10.3 + QML**，UI 组件库用第三方 **RinUI 0.4.4.1**（pip 依赖，不是本仓库代码），配置用 **Pydantic v2**，日志 loguru，路径用 **platformdirs**。

**当前工作副本是一个 fork**，不是原版：

- `src/__init__.py` 里 `__version__ = "2.0.0.huoiop.0927"`、`__version_type__ = "branch"`、`__update_channel__ = "huoiop"`
- **这个目录现在是 git 仓库**（旧版本文档说“不是 git 仓库”，已过时）：
  - `origin` = `https://github.com/Huoiop/Class-Widgets-2`（fork）
  - `upstream` = `https://github.com/RinLit-233-shiroko/Class-Widgets-2`（上游）
- 当前 `main` = 上游 `main`（`4b745ab`，2026-10-17 合并 19 个提交）+ 自定义改动（见 §7）
- 工作区数据（配置/课表/插件/主题/日志）**已不在仓库目录里**，默认在 `%LOCALAPPDATA%\Class_Widgets_2\`（见 §4.3）

---

## 1. 目录结构

```
CW2/
├── src/
│   ├── app.py                  入口（极薄，外层兜住启动异常）
│   ├── __init__.py             版本号、schema 版本、默认更新通道等常量
│   ├── core/                   全部 Python 逻辑
│   │   ├── central.py           AppCentral（上帝对象）
│   │   ├── storage/             directories.py（路径常量）、migration.py（数据迁移）
│   │   ├── crash/               handler.py、report.py、diagnosis.py（崩溃处理）
│   │   ├── utils/               platform.py、safe_mode.py、instance_locker.py、backend.py…
│   │   ├── config/  schedule/  plugin/  plaza/  themes/  widgets/
│   │   ├── notification/  automations/  updater/  windows/  timer/
│   │   └── ...
│   ├── qml/                    主窗口 + 界面
│   │   ├── MainInterface.qml   主窗口（无边框、置顶、近似全屏）
│   │   ├── widgets/            6 个内置小组件的 QML
│   │   ├── ClassWidgets/       Components / Windows / pages / Theme / Plugins / Data
│   │   ├── Debugger/
│   │   └── RinUI/
│   ├── plugins/cw_widgets/     唯一的内置插件（注册 6 个小组件）
│   ├── themes/                 内置主题：cw1 / material / vista / win10
│   └── ...
├── assets/                     图片、音频、i18n 词条（locales/*.ts|qm）
├── examples/                   课表格式模板
├── docs/                       多语言 README
├── scripts/                    CI/打包脚本（Inno Setup、lupdate 等）
├── .github/workflows/          build&release.yml（fork 已删掉 i18n-update.yml）
├── ClassWidgets-2.spec         PyInstaller 规格文件（构建入口）
├── pyproject.toml              依赖与项目元数据
├── requirements.txt            遗留清单（见 §5.6，别照它装）
├── uv.lock
├── PROJECT_GUIDE.md            本文件
└── .venv/                      Python 依赖（已 gitignore）
```

**运行时数据目录**（不在仓库里，详见 §4.3）：

```
%LOCALAPPDATA%\Class_Widgets_2\     默认（platformdirs，roaming=False）
├── configs\  configs\schedules\
├── plugins\  themes\  audio\
├── cache\plugin-cache\  temp\
└── logs\
```

相关但不在仓库里的：

- Python 依赖装在 `.venv/`（**Python 3.12.10** —— 刻意与官方 release 对齐，见 §5.2）
- RinUI 真实代码在 `.venv/Lib/site-packages/RinUI/`
- 3.12 的解释器装在 `C:\Users\hutao\AppData\Local\Programs\Python\Python312\python.exe`
  （**不在 PATH 上**，避免抢占系统的 `python`；建 venv 时用这个全路径）

> 仓库根目录现在仍能看到 `configs/`、`logs/`、`themes/`，那是**旧布局的遗留数据**。
> 下次启动时 `configs/`、`plugins/`、`themes/` 会被迁移到新数据目录（`logs/` 不迁移）。

---

## 2. 启动流程与核心对象

### 2.1 入口

```
src/app.py
  ├─ multiprocessing.freeze_support()
  ├─ wait_for_process_exit()      处理 --wait-for-pid（全仓库仍无人发送此参数，属遗留）
  ├─ QApplication + setQuitOnLastWindowClosed(False)
  ├─ AppCentral()
  └─ try: instance.run() / except: crash_handler.report_exception(source="startup")
     app.exec()
```

⚠️ `AppCentral()` 的**构造**在 `try` 之外：构造期间（尤其是 `prepare_work_directory()`）抛出的异常不会被崩溃处理接管，进程直接退出。见 §6.5。

### 2.2 AppCentral —— 上帝对象

`src/core/central.py` 的 `AppCentral` 是**单例**（重复构造抛异常），一次性构造所有子系统：

```
AppCentral.__init__
  prepare_work_directory()     迁移旧数据、创建工作目录（最先执行）
  ConfigManager / ThemeManager / WidgetListModel / AppWindowManager
  CrashHandler                 安装 sys.excepthook + threading.excepthook
  PlatformIntegration          单实例锁、窗口图标、AppUserModelID
  NotificationManager / NotificationService
  Schedule: UnionUpdateTimer / ScheduleManager / ScheduleRuntime
            ScheduleEditor / ClassSwapManager
  Utils:    PluginAPI / AppTranslator / 内置快捷方式 / PluginManager
            UtilsBackend / AutomationManager / UpdaterBridge
  UI:       WidgetsWindow（主窗口）+ ThemeRecoveryController
  aboutToQuit → cleanup()
```

`run()` → 载配置 → 载翻译 → 多实例检查 → `init()`，`init()` 内按序（仅列主要步骤）：

```
教程未完成 → 只开 Tutorial 窗口并 return
_setup_logging → _load_schedule → _load_class_swap
→ _load_runtime（含 _load_theme_and_plugins：主题 + 插件）
→ _init_tray_icon → _run_utils（自动化任务 + 显示主窗口）
```

任何一步抛异常都会写入崩溃报告（`source="startup"`），不会静默退出。

**首次启动会被引导页拦截**：`app.tutorial_completed=false` 时只开 Tutorial 窗口并 return。

### 2.3 安全模式

启动参数 `--safe-mode`（定义在 `src/core/utils/safe_mode.py`）：

- 外部插件**只扫描元数据**（仍显示在插件列表里供配置），**代码一行都不导入**
- 外部主题完全不读取
- 待执行的插件安装/卸载（`plugins.pending_operations`）留到下次正常启动
- 不注册插件广场快捷方式
- 启动后发一条常驻通知；托盘面板/设置窗口显示 `SafeModeNotice` 提示条
- 设置「关于」页与崩溃报告窗口都提供“以安全模式重启”（`AppCentral.restartInSafeMode`）

安全模式**照常读写配置、课表和内置插件**。

### 2.4 心跳

`UnionUpdateTimer`（`core/timer/union_update.py`）用 **50ms 定时器**轮询，在**秒数变化时**发一次 `tick`，即精确的 ~1Hz。它驱动：

- `AppCentral.update()` → `ScheduleRuntime.refresh()`
- `AutomationManager.update()` → 所有自动化任务

### 2.5 QML 上下文属性

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

**匹配规则**：`date` 精确匹配优先 → 否则按 `dayOfWeek` + `weeks`（多周轮换）。`weeks` 为单个 int 时的语义是“从第 N 个循环周开始，每 maxWeekCycle 周一次”，不是“第 N 周”。

**角色分工**：

| 类                 | 职责                                                              |
| ------------------ | ----------------------------------------------------------------- |
| `ScheduleManager`  | 课表文件的加载/保存/增删改查、只读模式；课表目录 `configs/schedules` |
| `ScheduleServices` | 纯计算：解析当天的 Timeline、当前/下一条目、状态、进度            |
| `ScheduleRuntime`  | 每秒刷新，把状态暴露成 QML 属性（见 §3.2）                        |
| `ScheduleEditor`   | QML 编辑器的门面，**持有的是 manager 的同一个 ScheduleData 对象** |
| `ClassSwapManager` | 临时换课（见 §3.9）                                               |
| `ScheduleParser`   | 薄封装：JSON → 校验 version → ScheduleData                        |
| `convertor/`       | CSES / CW1 / iCalendar(ICS) ↔ CW2 的互转                          |

⚠️ `ScheduleManager.load()` 的异常分支仍有**备份路径拼错**的问题，见 §8.1。

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

⚠️ 三个坑：

- `get_progress_percent()` 在没有当前条目时**返回 1**，但 `progress` 属性把 falsy 值转成 **0.0** → QML 空闲时看到的是 0，不是 1
- `currentsChanged` 只在**当前条目发生变化**时发，不是状态变化
- 所有时间比较用的是 `now + schedule.time_offset`，但显示的 `currentTime` 是原始墙钟

### 3.3 插件系统（`src/core/plugin/`）

**插件包格式**：目录下有 `cwplugin.json`（**不是** plugin.json）+ 入口 `.py`，可选 `libs/`。

```jsonc
// cwplugin.json 必需字段
{ "id", "name", "version", "api_version", "entry", "author", "icon"? }
// api_version 是 PEP440 SpecifierSet，当前 SDK 版本为 0.7.0（src/core/plugin/api.py）
// entry 指向的 .py 里必须定义 class Plugin(CW2Plugin)
```

**生命周期**：扫描 → 只加载 `configs.plugins.enabled` 里的 → 实例化 → `on_load()`。

⚠️ **插件仍然只在启动时加载**。启用/禁用、安装、卸载、更新**一律延迟到重启**（`markRestartRequired()`），没有运行时卸载路径。所以“启用后没反应”的第一个怀疑对象就是**没重启**。

**加载时会做**（`loader.py`）：

- 注入伪造模块 `sys.modules["ClassWidgets.SDK"]`
  - ✅ `from ClassWidgets.SDK import X` 可用
  - ❌ `import ClassWidgets.SDK` / `from ClassWidgets import SDK` **会失败**（没有伪造父包，实测确认）
- 把插件目录和 `libs/` 加进 `sys.path`（加载期间 `insert(0,...)`，之后 `append`）
- 外部插件的 `icon` 会被改写成 `QUrl.fromLocalFile(...)`

**加载失败现在可见**：`PluginLoader.failures` 会被整理成 `PluginManager.pluginLoadFailures` 并通过应用内通知提示“有插件加载失败”，不再只是日志里的一行 exception。

**插件 API 表面积**（`PluginAPI`）：`widgets / notification / schedule / schedulemanagement / globalconfig / application / diagnostics / theme / runtime / config / automation / actions / ui`。

**捆绑依赖的机制（重要，见 §6.3）**：插件的 `libs/` 里是打包时收集的**预编译二进制**，与打包者的 Python 版本绑定。

### 3.4 插件广场（`src/core/plaza/`）

- 默认地址 `https://plaza.cw.rinlit.cn`（`config.network.plaza_url`）
- Python 侧用 requests（只在 QThread 里跑），QML 侧大量直接 `XMLHttpRequest`
- 请求统一带 `User-Agent: ClassWidgets/<version>-<type>`；版本查询接口额外带 `X-CW-Client-Version`
- 主要端点：`/api/plugins`（列表/分页/排序）、`/api/plugins/{id}`、`/api/plugins/versions`、`/resources/readme|icon|release`、`/api/banners`、`/api/plugins/search|tags|suggest|random|certified`
- 下载走 `PluginDownloader`：支持 HTTP Range 断点续传、100MB 上限、30s 停滞超时
- 安全模式下不注册广场入口
- 没有应用内发评论的能力，“写评论”会打开网页

### 3.5 主题（`src/core/themes/`）

- 主题 = 目录下的 `cwtheme.json` + `ClassWidgets/theme/` 覆盖文件
- `ThemeUrlInterceptor` 把 QML 里的 `ClassWidgets/theme` 路径重写到当前主题；**基础 qmldir 不重写**（否则未覆盖的组件会丢）
- 内置 5 套：default（在 `src/qml`）、cw1、win10、material、vista
- ⚠️ **每个主题（包括 vista）都整份重写 `Widget.qml`**，改组件接口要同步改所有主题
- 安全模式只加载内置主题
- 主题加载失败由 `ThemeRecoveryController` 处理：回退默认主题并弹窗说明

### 3.6 小组件（`src/core/widgets/`）

- 通过 `api.widgets.register(widget_id, name, qml_path, backend_obj, settings_qml, default_settings)` 注册
- 实例列表存在 `preferences.widgets_presets`，QML 侧由 `WidgetListModel` 暴露
- **启用插件 ≠ 显示组件**：组件还要单独“添加”到桌面（右键 → 编辑小组件界面 → 添加）
- 内置 6 个（来自 `src/plugins/cw_widgets`）：`currentActivity`、`time`、`eventCountdown`、`upcomingActivities`、`dynamicNotification`、`customText`
- 编辑模式下拖动小组件会**实时换位**（上游 #229，已合入）

### 3.7 窗口（`src/core/windows/`、`src/core/widgets/core.py`）

- **主窗口 `src/qml/MainInterface.qml`**：无边框、置顶、尺寸≈整个屏幕；靠 `setMask(QRegion)` 做点击穿透（mask = 所有可见小组件的并集）
- 辅助窗口由 `AppWindowManager` **按名字懒加载并缓存**：
  `settings / editor / plugin_plaza / whatsnew / class_swap / class_swap_restore / single_instance / theme_load_error / problem_report / tutorial / debugger`
- 辅助窗口各自持有独立 QML 引擎（非共享引擎）
- 启动时若检测到当天的临时换课记录，会弹 `class_swap_restore` 让用户选择继续或丢弃

### 3.8 配置（`src/core/config/`）

- 文件：`<WORK_PATH>/configs/configs.json`（默认 `%LOCALAPPDATA%\Class_Widgets_2\configs\configs.json`），Pydantic 模型在 `model.py`，8 个 section：
  `app / locale / schedule / preferences / interactions / plugins / network / notifications`
- **键锁**：`Configs.isKeyLocked("dotted.key")`，锁定的键写入会被静默拒绝
- ⚠️ 键锁对**字典项的写入无效**（`plugins.configs`、`reschedule_day` 等）
- fork 额外做了两件事：
  - 配置变更后 **500ms 防抖落盘**（`save_debounce_timer`），避免强杀前丢失最近修改
  - `Configs.set()` 会把 QML 传来的 `QJSValue` 数组显式转成 `list`（否则 pydantic 列表字段赋值静默失败）
- 更新通道**不再**在每次启动时被重置；只有为空时才回退到 `__update_channel__`

### 3.9 其它

| 子系统 | 位置                             | 要点                                                                                                                    |
| ------ | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| 通知   | `core/notification/`             | 4 个等级；provider 制；可同时走系统托盘通知 + 应用内组件 + 音效                                                         |
| 自动化 | `core/automations/`              | 每秒 tick；`AutoHideTask`（Windows 专用 win32gui，上课/最大化/全屏自动隐藏）、`UpdateCheckTask`、`PlazaUpdateCheckTask` |
| 崩溃   | `core/crash/`                    | 见 §3.11                                                                                                                |
| 换课   | `schedule/swapper.py`            | 通过写 `overrides` 实现，记录存 `config.schedule.class_swap`，跨天在启动时清理                                          |
| 调休   | `config.schedule.reschedule_day` | `{日期: 星期}` 映射，覆盖当天按周几走                                                                                   |
| 单实例 | `utils/instance_locker.py`       | `QLockFile`，锁文件在 `%TEMP%/ClassWidgets2.lock`                                                                       |
| 开机自启 | `utils/auto_startup.py`        | 仅 Windows，写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`                                                     |

### 3.10 更新器

```
checkUpdate()  →  channel == "huoiop"：
                     GET https://api.huoiop.cn/updates/check/cw2   （见 workers.py）
                  其它 channel：
                     GET network.releases_url（默认 classwidgets.rinlit.cn/2/releases.json）
                  按 configs.app.channel 取对应分组 → {version, url:{windows,...}}
                  比较方式：字符串不等即视为有更新
startDownload() →  <WORK_PATH>/temp/cw2_update/update.zip（仅 Windows；github.com 域名走镜像前缀）
startInstall()  →  WindowsUpdater.apply_update(zip, INSTALL_PATH)
                   解压到 temp/extracted（校验 zip 路径穿越、符号链接）
                   跳过用户数据目录（portable/data/configs/plugins/themes/logs/cache/temp/audio）
                   生成 replace_and_restart.cmd → cmd /c 执行 → os._exit(0)
重启后带 --update-done → 删临时目录、打开「更新内容」窗口
```

**已修复的旧问题**（相对于上一版文档）：

- 覆盖目标不再是 `Path.cwd()`，而是 `INSTALL_PATH`（源码运行时=项目根，打包后=exe 所在目录）
- 解压前会校验绝对路径、`..`、盘符、链接，并拒绝覆盖用户数据目录
- 压缩包里必须存在 `Class Widgets 2.exe`

**仍存在的问题**：

- 不校验哈希/签名
- `os._exit(0)` 在 InstallWorker 的 `finished` 信号之前执行，`_on_install_finished` 里的收尾逻辑实际走不到
- 响应缺少 `content-length` 时 `downloaded / total * 100` 会 ZeroDivisionError
- 版本比较是字符串不等，线上版本更旧也会提示“有更新”（`auto_check_updates` 在 fork 里默认关闭）

### 3.11 崩溃处理

- `CrashHandler` 安装 `sys.excepthook` 与 `threading.excepthook`（也接住了 `src/app.py` 里 `run()` 的启动异常）
- `build_crash_report()` 生成 `CrashReport`（版本、系统完整版本号、运行时长、日志目录、当前主题、插件清单等）
- `diagnosis.py` 按规则归因到插件：`plugin-module` / `plugin-path` / `plugin-message` / `plugin-context`，输出 high/medium/low 置信度；内置插件永远不会被列为“可禁用的第三方插件”
- 报告交给 `ProblemReport` 窗口（上下文属性 `ProblemReportBridge`），可复制摘要、导出报告+日志尾部、
  直接禁用被归因的第三方插件、重启、以安全模式重启、忽略并继续
- 崩溃报告窗口是懒加载窗口 `problem_report`

---

## 4. 数据格式速查

### 4.1 课程表文件（`configs/schedules/*.json`）

```jsonc
{
  "meta": {
    "id": "...",
    "version": 1,
    "maxWeekCycle": 2,
    "startDate": "2026-09-01",
  },
  "subjects": [
    {
      "id": "math",
      "name": "数学",
      "simplifiedName": null,
      "teacher": "",
      "icon": "ic_fluent_ruler_24_regular",
      "color": "#0000FF",
      "location": "9101",
      "isLocalClassroom": true,
    },
  ],
  "days": [
    {
      "id": "Monday-All",
      "dayOfWeek": [1],
      "weeks": "all",
      "date": null,
      "entries": [
        {
          "id": "e1",
          "type": "class",
          "subjectId": "math",
          "startTime": "10:00",
          "endTime": "12:00",
          "title": null,
        },
      ],
    },
  ],
  "overrides": [
    {
      "id": "swap_xxx",
      "entryId": "e1",
      "dayOfWeek": [1],
      "weeks": "all",
      "subjectId": "physics",
      "title": null,
      "startTime": null,
      "endTime": null,
    },
  ],
}
```

⚠️ 字段名注意：是 `isLocalClassroom`（小写 r）；写成 `isLocalClassRoom` 会被 Pydantic 静默忽略。

### 4.2 配置（`<WORK_PATH>/configs/configs.json`）

8 个 section，各 section 的模型在 `src/core/config/model.py`，汇总它们的 `RootConfig` 在 `manager.py`。几个常打交道的：

```
app.version / app.channel / app.tutorial_completed / app.debug_mode / app.no_logs
schedule.current_schedule / preparation_time / time_offset / default_duration / class_swap
preferences.current_theme / scale_factor / opacity / widgets_anchor / widgets_presets / font
interactions.hide.{state,in_class,clicked,maximized,fullscreen,action,fully_hide,no_hide_subjects}
interactions.tapped_action / interactions.hover_fade
plugins.enabled / plugins.configs / plugins.pending_operations
network.releases_url / auto_check_updates / plaza_url / mirrors / current_mirror
notifications.enabled / volume / providers
```

fork 特有：

```
interactions.hide.fully_hide         完全隐藏（不在屏幕边缘留唤回小条）
interactions.hide.no_hide_subjects   永不自动隐藏的课程名称（对所有隐藏触发条件生效）
app.channel                          用户选择持久化，不再被启动重置
network.auto_check_updates           默认 false
```

### 4.3 路径规则

所有**可写数据**都走 `src/core/storage/directories.py`：

| 常量 | 默认位置 |
| --- | --- |
| `WORK_PATH` | `%LOCALAPPDATA%\Class_Widgets_2`（`platformdirs.user_data_path(..., roaming=False)`） |
| `CONFIGS_PATH` | `<WORK_PATH>/configs` |
| `SCHEDULES_PATH` | `<WORK_PATH>/configs/schedules` |
| `PLUGINS_PATH` | `<WORK_PATH>/plugins` |
| `THEMES_PATH` | `<WORK_PATH>/themes` |
| `LOGS_PATH` | `<WORK_PATH>/logs` |
| `CACHE_PATH` | `<WORK_PATH>/cache`（插件缓存在其下 `plugin-cache`） |
| `TEMP_PATH` | `<WORK_PATH>/temp` |
| `CUSTOM_AUDIO_PATH` | `<WORK_PATH>/audio` |
| `RESOURCE_PATH` / `INSTALL_PATH` | 源码运行=项目根；打包后=exe 所在目录 |

- 如果 `INSTALL_PATH/PORTABLE`（**文件**，不是目录）存在，`WORK_PATH` 改为 `<INSTALL_PATH>/data`
- 只有版本号恰为 `2.0.0.dev31546377` 时才启用旧布局（数据放在程序目录）。本 fork 的版本不会触发
- 资源路径（`src/qml`、`assets`、`examples`、内置主题/插件）始终留在应用目录
- `PathManager` 给 QML 提供 `root(name)` / `assets(name)` / `qml(name)` / `images(name)`，返回 `file://` URI

**迁移规则**（`storage/migration.py`，代码路径）：

- 启动最早阶段调用 `prepare_work_directory()`
- 若在安装目录/资源目录发现旧布局的 `configs/`、`plugins/`、`themes/`，**整体 move** 到 `WORK_PATH`
- 迁移前验证旧配置能通过 Pydantic；目标已存在、路径是链接、旧数据含链接 → 抛 `DataMigrationError`，**不会合并或覆盖**
- 迁移后会修正配置里的插件归档路径与自定义铃声路径
- 迁移只处理这三个目录；`logs/` 不迁移，旧日志留在原地

---

## 5. 开发环境与运行

### 5.1 运行（源码）

```bash
cd "D:/Huoiop 项目/CW2"
PYTHONIOENCODING=utf-8 PYTHONUTF8=1 .venv/Scripts/python.exe src/app.py
```

以安全模式运行：

```bash
PYTHONIOENCODING=utf-8 PYTHONUTF8=1 .venv/Scripts/python.exe src/app.py --safe-mode
```

⚠️ **必须带 UTF-8 环境变量**。RinUI 启动时会 `print("✨ RinUIWindow Initializing")`，中文 Windows 控制台默认 GBK，编码不出来直接崩：

```
UnicodeEncodeError: 'gbk' codec can't encode character '\u2728'
```

（双击打包版没这个问题，因为它没有控制台。仓库里没有 `run_dev.cmd`，旧文档提到的那个文件已不存在。）

### 5.2 构建打包

> **统一用 Python 3.12 构建。**
>
> 理由：PyInstaller 会把「运行它的那个解释器」打进包，而**插件的预编译依赖与应用的 Python
> 版本强绑定**（见 §6.3）。官方 release 是 3.12，本机也就统一到 3.12，这样自己打的包和官方包
> 对插件是通用的，不会出现“某插件在官方版能用、在自己打的包上加载失败”。
>
> 本机 `.venv` 就是 3.12，所以下面的命令直接用即可。
> 3.12 解释器**不在 PATH 上**（避免抢占系统的 `python`），需要时用全路径：
> `C:\Users\hutao\AppData\Local\Programs\Python\Python312\python.exe`

上游已改为 **`.spec` 构建**（`ClassWidgets-2.spec` 已纳入版本管理，`.gitignore` 里做了 `!ClassWidgets-2.spec` 例外）。
spec 里包含：平台图标、全部 add-data、动态收集全量标准库、`contents_directory='.'`、macOS BUNDLE。

```bash
cd "D:/Huoiop 项目/CW2"
PYTHONIOENCODING=utf-8 .venv/Scripts/python.exe -m PyInstaller --noconfirm ClassWidgets-2.spec
```

产物：`dist/Class Widgets 2/`。

CI（`.github/workflows/build&release.yml`）的后续步骤仍然是：

1. 按 `scripts/qt_files_clean-Windows.json` 清理多余 Qt 文件（455MB → 220MB 左右）
2. 写 `PORTABLE` 标记后打 zip（`dist/ClassWidgets-2-Windows.zip`，解压即用）
3. Inno Setup 安装包（`scripts/cw2-cicd.iss`）

> 旧文档里的手写 `--add-data ... src/app.py` 命令已不再使用；它与 spec 内容重复且容易漂移。
> fork 的 release 工作流还删掉了 WebDAV 上传与 SignPath 签名步骤，构建命令与上游一致。

### 5.3 验证 QML 改动（推荐的实测方法）

**不要只靠肉眼看代码**。这套项目有两个坑（§6.1、§6.2）会让“看起来对”的 QML 实际不工作。推荐两种手段：

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

- 源码运行/打包版都写 `<WORK_PATH>/logs/ClassWidgets-<时间>.log`（默认 `%LOCALAPPDATA%\Class_Widgets_2\logs\`）
- `app.no_logs=true` 时不写文件
- 仓库根目录的 `logs/` 是旧布局遗留，不会再新增
- 插件加载失败、QML 警告都在日志里；**调试界面看不到的失败，第一站就是日志**（插件加载失败现在也会弹通知）

### 5.6 重建 venv（环境坏了 / 换机器时）

本机统一用 **Python 3.12**，但 3.12 **不在 PATH 上**（见 §5.2），建 venv 要用全路径：

```bash
PY312="C:/Users/hutao/AppData/Local/Programs/Python/Python312/python.exe"
"$PY312" -m venv .venv

# 依赖按 pyproject.toml 装
.venv/Scripts/python.exe -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple \
  PySide6~=6.10.3 "RinUI>=0.4.4.1" loguru packaging pydantic pyyaml requests \
  markdown-it-py~=4.2.0 "icalendar~=7.3.0" "recurring-ical-events~=3.8.2" \
  "tzdata~=2026.4" "platformdirs~=4.11.3" pyinstaller
```

⚠️ 三个坑：

- **别用 `requirements.txt`** —— 它 pin 的版本和实际能装的**对不上**，也不含 pyinstaller。
  CI 其实走的是 `pyproject.toml` + `uv.lock`，那个文件基本是遗留物。
- **全局 pip 源（阿里云）下 PySide6 会截断**，报
  `ERROR: THESE PACKAGES DO NOT MATCH THE HASHES FROM THE REQUIREMENTS FILE`。
  用 `-i` 临时换清华源即可，**不要改全局配置**。
- 上游 #221 新增了 **`platformdirs`**（工作目录规范化）。拉上游后如果启动报
  `ModuleNotFoundError: No module named 'platformdirs'`，先补装它。

（`pywin32` 不用手动装 —— 它是 RinUI 的依赖，`sys_platform == 'win32'` 时自动带上。）

---

## 6. 踩坑清单（重要，都是实际踩到的）

### 6.1 Python 传来的 list 不是真正的 JS 数组

`Configs.data` 里的列表、`@Slot(result=list)` 返回的列表，在 QML 侧 `Array.isArray()` **为 false**，是个“类数组对象”。

**后果**：直接当 `Repeater` 的 model → **一个子项都渲染不出来**（静默，无报错）。

```qml
// ❌ 会渲染不出任何东西
Repeater { model: somePythonList; ... }
// ✅ 先转成真数组
function toArray(v) { var o=[]; if(v && typeof v.length==="number") for(var i=0;i<v.length;i++) o.push(v[i]); return o }
```

> 注意：反方向（QML 数组 → Python）在 `Configs.set()` 里已经做了 `QJSValue` 转换（fork 改动），
> 但 `@Slot` 参数仍要留意类型。

### 6.2 Repeater delegate 的勾选态只在创建时读一次

`Component.onCompleted: checked = ...` 是一次性赋值。如果**先**赋值 model（触发 delegate 重建）、**后**赋值选中列表，所有 delegate 都会显示未选中。

**正确顺序**：先把选中数据准备好，最后再赋值 model。

### 6.3 插件的预编译依赖与应用的 Python 版本强绑定

插件 `libs/` 里的 `.pyd` 带 ABI 标签（`cp312` / `cp313` / `cp314`），**必须与应用运行的 Python 版本精确一致**。

判断“会不会出事”的三条件（同时满足才炸）：

1. 库含编译扩展（`.pyd`/`.so`）
2. 应用**自己没用过**这个库（不在 `sys.modules` 里）
3. 插件捆的二进制与应用 Python 版本不一致

（因为 `sys.modules` 优先级 > `sys.path`，应用启动时已加载的模块会直接命中内存，插件捆的那份不会被读。）

⚠️ 顺带：**CW2 的应用包内嵌的 Python 版本，取决于构建时用的解释器**（PyInstaller 会把运行它的解释器打包）。

- 官方 release 2.0.1.0 = **Python 3.12**（实测 `python312.dll`，包内 `.pyd` 全 cp312）
- 本机 `.venv` 也是 **Python 3.12**（刻意对齐官方，详见 §5.2）
- `pyproject.toml` 是区间 `>=3.12,<3.14`，语法上 3.13 也合法 —— 但**插件二进制不能通用**，
  所以本机统一用 3.12，避免“自己打的包和官方包插件不通用”

### 6.4 lupdate 不能只对单个文件跑

`pyside6-lupdate <单个文件> -ts zh_CN.ts` 会把**其他所有文件**的词条标成 `type="vanished"`，`lrelease` 编译后中文界面会**整个丢翻译**。

正确做法：全量扫描（`scripts/update_ts.sh` 里的写法）。

```bash
.venv/Lib/site-packages/PySide6/lupdate.exe $(find src/ -name "*.py" -o -name "*.qml") -ts assets/locales/zh_CN.ts
.venv/Lib/site-packages/PySide6/lrelease.exe assets/locales/zh_CN.ts
```

> fork 的 i18n 自动工作流已删除；按用户约定，界面文案仍由上游/GitHub/Weblate 的流程处理（§9）。

### 6.5 工作目录迁移的坑

上游 #221 把可写数据从程序目录移到了 `WORK_PATH`。迁移是**有意的保守设计**：

- **目标目录已存在就会拒绝启动**，不会合并或覆盖。不要在启动前手动把 `configs/` 之类复制到
  `%LOCALAPPDATA%\Class_Widgets_2\`，除非你确定自己是在做别的事
- `WORK_PATH` 不能等于安装目录/资源目录（旧版本号除外），也不能是符号链接/junction
- 旧 `configs.json` 必须能通过 Pydantic 校验，否则迁移中止
- **迁移异常发生在 `AppCentral.__init__` 里，早于 CrashHandler 安装**，且 `src/app.py` 只包住了
  `run()` → 进程会直接退出。遇到“启动即闪退”，先在控制台看 traceback，或检查
  `<WORK_PATH>/.data-migration.lock`
- `PORTABLE` 是**文件**标记。若在源码根目录放一个名为 `PORTABLE` 的文件，数据会写到项目根的
  `data/`（该目录已被 gitignore）

### 6.6 其它零散坑

| 坑                                        | 说明                                                                  |
| ----------------------------------------- | --------------------------------------------------------------------- |
| 单实例锁                                  | `%TEMP%/ClassWidgets2.lock`。强杀进程后会残留，重启应用前可能要手动删 |
| 强制结束进程                              | 会跳过 `cleanup()`（配置保存、锁释放）。优先用应用内退出；配置有 500ms 防抖落盘，损失比过去小 |
| `dist/` 是旧产物                          | 改了源码后 `dist/` 不会自动更新，容易误以为是新版本                   |
| `.spec` 现在是源码                        | `ClassWidgets-2.spec` 被显式纳入版本管理，别把它当构建垃圾删掉        |
| `configs/` / `plugins/` / `data/`         | 都在 `.gitignore` 里，别提交                                          |
| `logs/`                                   | 已 gitignore；新日志在 `%LOCALAPPDATA%`                               |
| 主题覆盖                                  | 改 `Theme/components/*` 的接口要同步改 5 套主题的 `Widget.qml`        |
| QML 上下文                                | 新增窗口记得走 `setup_qml_context`，否则 `Configs`/`AppCentral` 都是 undefined |

---

## 7. 本 fork 的现状

### 7.1 已合入上游

- `2026-10-17` 合并上游 `main`（`4b745ab`，19 个提交；上游 tag `2.0.0.dev20261014`），合并提交 `82e1977`
- 之前的合并：51 个提交（0906 线）、18 个、15 个等
- 本次合并的冲突只有两处：
  - `.github/workflows/build&release.yml`：保留 fork 精简结构，采纳上游的 `.spec` 构建
  - `src/core/crash/diagnosis.py`：本地是上游漏提交时按接口补的桩，改为采用上游完整实现
- 本次新增依赖：`platformdirs`（已装进 `.venv`）
- 上游带来的主要变化：
  - **工作目录/程序目录分离**（#221）
  - **`.spec` 统一构建 + 收集全量标准库**（#222）
  - 崩溃归因与 `ProblemReport`、**安全模式**
  - 插件加载失败通知、不兼容插件提示
  - 插件广场特定 UA / 新版本查询 API
  - 小组件编辑态实时换位（#229）
  - 「灵动通知」误注册「即将进行」设置项修复

### 7.2 本 fork 的自定义改动

以 `git diff upstream/main HEAD` 为准（截至本次合并）：

| 功能 | 位置 |
| --- | --- |
| 版本号 `2.0.0.huoiop.0927`、版本类型 `branch`、默认更新通道 `huoiop` | `src/__init__.py` |
| 更新通道「Huoiop 特调」（走 `api.huoiop.cn/updates/check/cw2`） | `core/updater/workers.py`、`pages/settings/Update.qml` |
| 通道选择不在启动时被重置 | `core/config/manager.py` 的 `_ensure_defaults` |
| 「永不自动隐藏的课程」：按课程名匹配、覆盖所有自动隐藏触发条件；弹窗可跨课表勾选 | `builtin_tasks.py`、`config/model.py`、`schedule/manager.py`、`dialogs/NeverHideCoursesPopup.qml`、`pages/settings/General/Interactions.qml`、`pages/tutorial/Interactions.qml` |
| `fully_hide`（完全隐藏，无边缘唤回条）；完全隐藏时点托盘图标直接唤回 | `config/model.py`、`central.py`、`Components/WidgetsContainer.qml` |
| 灵动通知期间临时恢复被隐藏的小组件，通知结束后回到隐藏位 | `widgets/dynamicNotification.qml` |
| 配置 500ms 防抖落盘；`Configs.set` 支持 QJSValue 数组 | `core/config/manager.py` |
| 编辑器：拖动时间块到视口边缘自动滚动；缩放上限 0.5–8；短时段卡片按比例收缩内边距；默认时长改用 `onValueModified` | `Components/editor/TimeAxis.js`、`timeline/EntryListView.qml`、`schedule/ScheduleCourseCard.qml`、`schedule/ScheduleTableView.qml`、`pages/editor/Settings.qml` |
| 默认主题去掉上游的灰黑描边层；`MarqueeTitle` 支持左对齐 | `Theme/components/Widget.qml`、`Theme/components/MarqueeTitle.qml` |
| 「关于」页显示基于的上游版本 | `pages/settings/About.qml` |
| CI/仓库整理：fork 版 git-cliff、删除 i18n 自动工作流、精简发布工作流、提交本项目指引 | `.git-cliff.toml`、`.github/`、`PROJECT_GUIDE.md` |

> 已随上游合入、**不再算 fork 自定义**的功能：主窗口高度 -1px（#213）、
> 预备铃“Starting soon”文案、小组件拖动实时换位（#229）。

### 7.3 远端分支（`github.com/Huoiop/Class-Widgets-2`）

| 分支 | 用途 |
| --- | --- |
| `main` | 当前开发主线（上游 + fork 改动） |
| `pr-course-exempt` | 上游 PR #198（永不自动隐藏功能） |
| `pr-fully-hide` | `fully_hide` 功能 |
| `pr-widget-live-reorder` | 小组件实时换位（已随上游 #229 合入） |
| 本地 `backup-before-cleanup` | 编辑器“纯缩放”改动前的备份 |
| 本地 `pr-widget-window-height` | 主窗口高度 -1px（已随上游 #213 合入；远端跟踪已消失） |

⚠️ **提 PR 的限制**：当前用的是**细粒度 PAT**，对别人名下的公开仓库（上游）只有只读权限 → **无法用 API 创建/修改上游的 PR**，只能推分支到 fork，再由用户在网页上开 PR。推 fork 分支本身是通的。

⚠️ 上游合并后 GitHub 的 “Sync fork / 丢弃提交”按钮**不要点**（会抹掉自定义提交）。

---

## 8. 已知问题（按严重程度排）

1. **课程表解析失败会销毁原文件** —— `schedule/manager.py` 的 `load()` 异常分支里，备份路径拼成了
   `xxx.json/backup/....json`（`schedule_path` 是文件不是目录），备份必然失败且被吞掉；之后用空课表
   覆盖**原文件**。任何 JSON/校验/版本错误 → 原课表永久丢失。**旧版本实测复现过，本次合并后代码未修。**
2. **配置解析失败会用默认配置覆盖原文件** —— `config/manager.py` 的 `load_config()` 捕获异常后只记
   warning，随后照常 `save()`。损坏的 `configs.json` 会被默认值覆盖。**代码路径确认。**
3. **`ThemeAPI.current()` 必然抛异常** —— `core/plugin/components.py` 读的是
   `themeManager.current_theme`，实际属性是 `currentTheme`。
4. **`UtilsBackend.getGlobalVolume/setGlobalVolume` 重复定义** —— 同一个类里有两组同名 Slot
   （约 355/362 行与 430/437 行），后定义的一组生效。
5. **`ConfigManager.save_timer` 建了但从未 `start()`** —— 60 秒周期保存不生效；不过 fork 的 500ms
   防抖 timer 会在配置变更时落盘，实际影响有限。
6. **`UpdateCheckTask` 每次检查都重复 `connect` 一次 `updateAvailable`**，只在成功路径 disconnect
   → 连接会累积（`automations/update_check.py`）。
7. **更新器剩余问题** —— 无哈希/签名校验；`os._exit(0)` 早于 `finished` 回调；缺 `content-length`
   时 ZeroDivisionError；字符串比较版本号（§3.10）。
8. **`src/app.py` 的 `--wait-for-pid` 全仓库无人发送** —— 属遗留代码。
9. **`AppCentral.__init__` 的异常不在崩溃处理范围内** —— 数据迁移失败会直接退出进程（§6.5）。

---

## 9. 工作约定（用户偏好，务必遵守）

这些是用户在协作中明确提出过的：

1. **界面文案直接用英文**，不需要手工做翻译 —— `.ts` / `.qm` 由 GitHub / Weblate 的自动化流程处理，**不要手改翻译文件**
2. **PR / issue 的标题与描述用中文**；程序内界面文案仍直接用英文原文（`qsTr("Starting soon")`），其他语言交给自动翻译
3. **注释要精简** —— 只保留必要的“为什么”，不要大段铺垫。这条被上游评审提过两次
4. **验证要实测**，不要只看代码 —— QML 改动尽量用实例化/截图验证；改完 Python 至少 `py_compile`
5. **改动范围要克制** —— 用户多次强调“只做要求的事”，不要顺手重构无关代码
6. **提 PR 到上游需要用户手动创建**（原因见 §7.3），GitHub 的 “Sync fork / 丢弃提交”按钮**不要点**（会抹掉自定义提交）
7. **拉上游后先看依赖** —— `pyproject.toml` 新增依赖（如 `platformdirs`）要装进 `.venv`，否则启动即 ImportError

---

## 10. 快速上手检查清单

接手新任务时建议先做：

- [ ] 确认要改的是**源码运行**（`.venv`，3.12）还是**打包版**（`dist/`）—— 现在两者的**数据目录默认是同一个**
      `%LOCALAPPDATA%\Class_Widgets_2`，除非打包目录里有 `PORTABLE` 文件（则用 `data/`）
- [ ] 检查仓库根 `configs/`、`themes/` 是否还在：在的话说明本次启动会触发一次迁移
- [ ] 读一遍本文件的 §3 对应子系统 + §6 踩坑清单
- [ ] 改 QML 前先想清楚 §6.1 / §6.2 两个坑
- [ ] 改完跑 `py_compile` / `qmllint`，再按 §5.3 做一次实测
- [ ] 启动验证时记得带 `PYTHONIOENCODING=utf-8 PYTHONUTF8=1`；怀疑插件/主题问题时加 `--safe-mode` 对照
- [ ] 打包时确认用的是 **Python 3.12**，并且走 `ClassWidgets-2.spec`（§5.2）
- [ ] 拉取上游后：`git fetch upstream && git merge upstream/main`，装新依赖，跑一次导入/编译检查
- [ ] 涉及插件/主题/更新的改动，注意 `%LOCALAPPDATA%\Class_Widgets_2`、`dist/`、远端分支的现状（§7）
