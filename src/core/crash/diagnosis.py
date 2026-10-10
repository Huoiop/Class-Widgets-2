"""崩溃归因：判断一次未处理异常是否由某个插件引发。

注意：本模块在上游仓库里是缺失的——引入它的提交只带了引用它的代码，漏提交了
模块本身。这里按调用方实际用到的接口补齐，上游补上真文件后合并时直接采用上游
版本即可。
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

__all__ = [
    "CrashDiagnosis",
    "PluginRecord",
    "PluginSuspect",
    "diagnose_exception",
]

#: 栈帧落在插件目录里，指向性很强。
CONFIDENCE_TRACEBACK = 0.9
#: 异常发生在某个插件执行期间（调用方追踪到的当前插件），指向性较弱。
CONFIDENCE_ACTIVE_PLUGIN = 0.6


@dataclass(frozen=True)
class PluginRecord:
    """供归因比对的插件信息，由调用方从插件清单整理而来。"""

    plugin_id: str
    name: str = ""
    version: str = ""
    icon: str = ""
    path: str = ""
    builtin: bool = False


@dataclass(frozen=True)
class PluginSuspect:
    """归因结论指向的那个插件。"""

    plugin_id: str
    display_name: str = ""
    version: str = ""
    icon: str = ""
    builtin: bool = False
    rule: str = ""
    confidence: float = 0.0


@dataclass(frozen=True)
class CrashDiagnosis:
    """一次崩溃的归因结果；没有结论时 ``suspect`` 为 None。"""

    suspect: Optional[PluginSuspect] = None

    @property
    def blames_plugin(self) -> bool:
        return self.suspect is not None


def _normalized_path(path: str) -> str:
    """归一化路径，便于跨大小写/分隔符比较；空路径返回空串。"""
    if not path:
        return ""
    return os.path.normcase(os.path.abspath(path))


def _suspect(record: PluginRecord, rule: str, confidence: float) -> PluginSuspect:
    return PluginSuspect(
        plugin_id=record.plugin_id,
        display_name=record.name or record.plugin_id,
        version=record.version,
        icon=record.icon,
        builtin=record.builtin,
        rule=rule,
        confidence=confidence,
    )


def _from_traceback(exc_tb, records: list[PluginRecord]) -> Optional[PluginSuspect]:
    """取最深的、落在某个插件目录里的栈帧，它离抛出点最近。"""
    if exc_tb is None:
        return None

    roots = [
        (root, record)
        for root, record in ((_normalized_path(r.path), r) for r in records)
        if root
    ]
    if not roots:
        return None

    found: Optional[PluginRecord] = None
    tb = exc_tb
    while tb is not None:
        filename = _normalized_path(tb.tb_frame.f_code.co_filename)
        if filename:
            for root, record in roots:
                if filename.startswith(root + os.sep):
                    found = record
                    break
        tb = tb.tb_next

    return _suspect(found, "traceback", CONFIDENCE_TRACEBACK) if found else None


def _from_active_plugin(
    active_plugin_id: str, records: list[PluginRecord]
) -> Optional[PluginSuspect]:
    if not active_plugin_id:
        return None
    for record in records:
        if record.plugin_id == active_plugin_id:
            return _suspect(record, "active-plugin", CONFIDENCE_ACTIVE_PLUGIN)
    return None


def diagnose_exception(
    exc_tb=None,
    exc_value=None,
    *,
    plugins=(),
    active_plugin_id: str = "",
    message: str = "",
) -> CrashDiagnosis:
    """判断这次异常能否归因到某个插件，不能则返回空结论。

    ``exc_value`` 与 ``message`` 为调用签名兼容而保留，当前判断只用栈帧和
    调用方追踪到的当前插件。
    """
    records = [r for r in (plugins or ()) if isinstance(r, PluginRecord)]
    if not records:
        return CrashDiagnosis()

    suspect = _from_traceback(exc_tb, records)
    if suspect is None:
        suspect = _from_active_plugin(active_plugin_id, records)
    return CrashDiagnosis(suspect=suspect)
