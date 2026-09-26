from pathlib import Path
import platform

import requests
from PySide6.QtCore import QThread, Signal

from src.core.updater.downloader import UpdateDownloader
from src.core.updater.updater import WindowsUpdater

# UPDATE_URL = "http://localhost:8080/releases.json"
UPDATE_URL = "https://classwidgets.rinlit.cn/2/releases.json"

# “Huoiop 特调”通道：独立于官方 releases.json，走自建接口
HUOIOP_CHANNEL = "huoiop"
HUOIOP_UPDATE_URL = "https://api.huoiop.cn/updates/check/cw2"


class CheckUpdateWorker(QThread):
    finished = Signal(str, str, str)  # status, version, url_or_error

    def __init__(self, channel, current_version):
        super().__init__()
        self.channel = channel
        self.current_version = current_version
        self.url = UPDATE_URL

    def start(self, url=None):
        super().start()
        if url:
            self.url = url

    def run(self):
        try:
            if self.channel == HUOIOP_CHANNEL:
                self._check_huoiop()
            else:
                self._check_releases()
        except Exception as e:
            self.finished.emit("Error", "", str(e))

    def _check_releases(self):
        """官方通道：releases.json 按 channel 分组"""
        if not self.url:
            self.url = UPDATE_URL
        resp = requests.get(self.url, timeout=5)
        resp.raise_for_status()
        data = resp.json()
        info = data.get(self.channel)
        if not info:
            self.finished.emit("Error", "", "Missing channel info")
            return

        version = info.get("version", "")
        sys_name = platform.system().lower()
        url = info.get("url", {}).get(sys_name, "") or ""

        if version != self.current_version:
            self.finished.emit("UpdateAvailable", version, url)
        else:
            self.finished.emit("UpToDate", version, "")

    def _check_huoiop(self):
        """Huoiop 特调通道：{status, data:{lver, mver, dlurl}}

        lver 为服务端最新版本号，dlurl 为新版本 zip 包地址。
        """
        resp = requests.get(HUOIOP_UPDATE_URL, timeout=5)
        resp.raise_for_status()
        payload = resp.json()
        if not payload.get("status"):
            self.finished.emit("Error", "", "Huoiop update check returned status=false")
            return

        info = payload.get("data") or {}
        version = str(info.get("lver") or "")
        url = str(info.get("dlurl") or "")
        if not version:
            self.finished.emit("Error", "", "Missing version info")
            return
        if not url:
            self.finished.emit("Error", "", "Missing download url")
            return

        if version != self.current_version:
            self.finished.emit("UpdateAvailable", version, url)
        else:
            self.finished.emit("UpToDate", version, "")


class DownloadWorker(QThread):
    progress = Signal(float, float)
    finished = Signal(bool, str, bool)  # success, error_msg, manual_stop

    def __init__(self, downloader: UpdateDownloader):
        super().__init__()
        self.downloader = downloader

    def run(self):
        try:
            success = self.downloader.download(progress_callback=self.progress.emit)
            if success:
                self.finished.emit(True, "", False)
            else:
                self.finished.emit(False, "Download cancelled or failed.", self.downloader.manual_stop)
        except Exception as e:
            self.finished.emit(False, str(e), False)

    def stop(self, force=False):
        try:
            self.downloader.stop(force)
        except Exception:
            pass


class InstallWorker(QThread):
    finished = Signal(bool, str)  # success, error_msg

    def __init__(self, updater: WindowsUpdater, zip_path: Path, target_dir: Path):
        super().__init__()
        self.updater = updater
        self.zip_path = zip_path
        self.target_dir = target_dir

    def run(self):
        try:
            self.updater.apply_update(self.zip_path, self.target_dir)
            self.finished.emit(True, "")
        except Exception as e:
            self.finished.emit(False, str(e))
