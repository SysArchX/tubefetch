"""Camada de download baseada no yt-dlp."""

from __future__ import annotations

import os
import re
import shutil
import threading
import time
from dataclasses import dataclass
from typing import Callable, Optional

from .ytdlp_loader import QJS_PATH, yt_dlp

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
_AUDIO_QUALITIES = {"0", "128", "192", "320"}


def ffmpeg_available() -> bool:
    """Informa se o ffmpeg está disponível no PATH."""
    return shutil.which("ffmpeg") is not None


@dataclass
class DownloadOptions:
    """Opções escolhidas pelo usuário na interface."""

    url: str
    destination: str
    mode: str = "video"  # "video" ou "audio"
    quality: str = "best"  # vídeo: best/1080/720/480/360 | áudio: 0/320/192/128
    playlist: bool = False
    playlist_items: str = ""
    embed_metadata: bool = True


class _Logger:
    """Repassa as mensagens do yt-dlp para a interface."""

    def __init__(self, job: "DownloadJob") -> None:
        self.job = job

    def debug(self, msg: str) -> None:
        text = str(msg)
        if text.startswith("[debug]"):
            return
        self.job._handle_info(text)
        self.job._log(text)

    def info(self, msg: str) -> None:
        self.job._handle_info(msg)
        self.job._log(msg)

    def warning(self, msg: str) -> None:
        self.job._log(f"Aviso: {msg}")

    def error(self, msg: str) -> None:
        self.job._errors.append(str(msg))
        self.job._log(f"Erro: {msg}")


class DownloadJob:
    """Executa um download do yt-dlp em uma thread separada.

    Os callbacks são chamados a partir da thread de download. A interface
    deve reenviá-los para o loop principal do GTK com ``GLib.idle_add``.
    """

    def __init__(
        self,
        options: DownloadOptions,
        on_progress: Optional[Callable[[dict], None]] = None,
        on_status: Optional[Callable[[str], None]] = None,
        on_log: Optional[Callable[[str], None]] = None,
        on_done: Optional[Callable[[bool, str], None]] = None,
        on_title: Optional[Callable[[str], None]] = None,
    ) -> None:
        self.options = options
        self.on_progress = on_progress
        self.on_status = on_status
        self.on_log = on_log
        self.on_done = on_done
        self.on_title = on_title

        self._cancel_event = threading.Event()
        self._done_called = False
        self._last_emit = 0.0
        self._current_title: Optional[str] = None
        self._playlist_count: Optional[int] = None
        self._playlist_selected_count: Optional[int] = None
        self._playlist_first_index: Optional[int] = None
        self._finished_ids: set[str] = set()
        self._skipped_existing = 0
        self._errors: list[str] = []
        self._ydl = None

        # Progresso agregado de vídeo + áudio baixados separadamente
        self._selected_format_ids: list[str] = []
        self._format_sizes: dict[str, float] = {}
        self._stream_downloaded: dict[str, float] = {}
        self._stream_total: dict[str, float] = {}

    # ------------------------------------------------------------------
    # Controle
    # ------------------------------------------------------------------
    def cancel(self) -> None:
        """Solicita o cancelamento do download."""
        self._cancel_event.set()

    @property
    def cancelled(self) -> bool:
        return self._cancel_event.is_set()

    def _check_cancel(self) -> None:
        if self._cancel_event.is_set():
            raise yt_dlp.utils.DownloadCancelled("Cancelado pelo usuário")

    # ------------------------------------------------------------------
    # Callbacks internos
    # ------------------------------------------------------------------
    def _log(self, message: str) -> None:
        text = _ANSI_RE.sub("", str(message)).strip()
        if not text or text.startswith("[debug]"):
            return
        if self.on_log:
            try:
                self.on_log(text)
            except Exception:
                pass

    def _status(self, message: str) -> None:
        if self.on_status:
            try:
                self.on_status(message)
            except Exception:
                pass

    def _emit(self, payload: dict, force: bool = False) -> None:
        now = time.monotonic()
        if not force and now - self._last_emit < 0.08:
            return
        self._last_emit = now
        if self.on_progress:
            try:
                self.on_progress(payload)
            except Exception:
                pass

    def _update_metadata(self, info: dict) -> None:
        count = info.get("playlist_count")
        if count and not self._playlist_count:
            self._playlist_count = int(count)

        selected = info.get("n_entries")
        if selected and not self._playlist_selected_count:
            self._playlist_selected_count = int(selected)

        index = info.get("playlist_index")
        if index and self._playlist_first_index is None:
            self._playlist_first_index = int(index)

        title = info.get("title")
        if title and title != self._current_title:
            self._current_title = title
            if self.on_title:
                try:
                    self.on_title(str(title))
                except Exception:
                    pass

    def _playlist_overall(self, index, fraction: float) -> float:
        count = self._playlist_selected_count or self._playlist_count
        if index and count:
            first = self._playlist_first_index or 1
            return max(0.0, min(1.0, ((index - first) + fraction) / count))
        return fraction

    def _handle_info(self, message: str) -> None:
        """Captura a lista de formatos escolhidos pelo yt-dlp.

        A mensagem tem o formato:
            [info] ID: Downloading 1 format(s): 395+251
        """
        match = re.search(r"Downloading \d+ format\(s\): (.+)$", str(message))
        if not match:
            if "has already been downloaded" in str(message):
                self._skipped_existing += 1
            return
        identifiers = [
            part.strip() for part in match.group(1).split("+") if part.strip()
        ]
        if not identifiers:
            return
        self._selected_format_ids = identifiers
        self._format_sizes.clear()
        self._stream_downloaded.clear()
        self._stream_total.clear()

    def _register_formats(self, info: dict) -> None:
        if self._format_sizes:
            return
        for fmt in info.get("formats") or []:
            identifier = str(fmt.get("format_id") or "")
            if not identifier:
                continue
            size = fmt.get("filesize") or fmt.get("filesize_approx") or 0
            if size:
                self._format_sizes[identifier] = float(size)

    def _item_fraction(self, downloaded, total, info: dict) -> float:
        """Calcula o progresso considerando vídeo e áudio separados."""
        identifier = str(info.get("format_id") or "")
        if identifier:
            self._stream_downloaded[identifier] = float(downloaded or 0)
            if total:
                self._stream_total[identifier] = float(total)

        selected = list(self._selected_format_ids)
        for known in self._stream_total:
            if known not in selected:
                selected.append(known)

        if selected:
            total_all = 0.0
            done_all = 0.0
            for format_id in selected:
                size = (
                    self._stream_total.get(format_id)
                    or self._format_sizes.get(format_id)
                    or 0
                )
                if size <= 0:
                    continue
                total_all += size
                done_all += min(self._stream_downloaded.get(format_id, 0), size)
            if total_all > 0:
                return min(1.0, done_all / total_all)

        return (downloaded / total) if total else 0.0

    @staticmethod
    def _phase(info: dict) -> str:
        vcodec = info.get("vcodec")
        acodec = info.get("acodec")
        has_video = bool(vcodec and vcodec != "none")
        has_audio = bool(acodec and acodec != "none")
        if has_video and not has_audio:
            return "Baixando vídeo"
        if has_audio and not has_video:
            return "Baixando áudio"
        return "Baixando"

    # ------------------------------------------------------------------
    # Hooks do yt-dlp
    # ------------------------------------------------------------------
    def _progress_hook(self, data: dict) -> None:
        self._check_cancel()

        status = data.get("status")
        info = data.get("info_dict") or {}
        self._update_metadata(info)

        if status == "downloading":
            self._register_formats(info)
            total = data.get("total_bytes") or data.get("total_bytes_estimate") or 0
            downloaded = data.get("downloaded_bytes") or 0
            fraction = self._item_fraction(downloaded, total, info)
            raw_index = info.get("playlist_index")
            count = (
                self._playlist_selected_count
                or info.get("playlist_count")
                or self._playlist_count
            )
            index = (
                raw_index - (self._playlist_first_index or 1) + 1
                if raw_index
                else None
            )
            overall = self._playlist_overall(raw_index, fraction)

            self._emit(
                {
                    "percent": overall,
                    "item_percent": fraction,
                    "index": index,
                    "count": count,
                    "title": info.get("title") or "",
                    "phase": self._phase(info),
                    "speed": data.get("speed"),
                    "eta": data.get("eta"),
                    "downloaded": downloaded,
                    "total": total,
                }
            )

        elif status == "finished":
            self._register_formats(info)
            item_id = info.get("id")
            if item_id:
                self._finished_ids.add(str(item_id))

            total = data.get("total_bytes") or 0
            fraction = self._item_fraction(total, total, info)
            raw_index = info.get("playlist_index")
            count = (
                self._playlist_selected_count
                or info.get("playlist_count")
                or self._playlist_count
            )
            index = (
                raw_index - (self._playlist_first_index or 1) + 1
                if raw_index
                else None
            )
            overall = self._playlist_overall(raw_index, fraction)

            self._emit(
                {
                    "percent": overall,
                    "item_percent": fraction,
                    "index": index,
                    "count": count,
                    "title": info.get("title") or "",
                    "phase": "Processando",
                    "speed": None,
                    "eta": 0,
                    "downloaded": total,
                    "total": total,
                },
                force=True,
            )
            self._status("Processando arquivo...")

    def _postprocessor_hook(self, data: dict) -> None:
        self._check_cancel()
        name = data.get("postprocessor") or ""
        status = data.get("status")

        labels = {
            "FFmpegExtractAudio": "Convertendo áudio para MP3...",
            "FFmpegMetadata": "Incorporando metadados...",
            "Merger": "Juntando vídeo e áudio...",
            "MoveFiles": "Organizando arquivos...",
        }

        if status == "started":
            self._status(labels.get(name, "Processando arquivo..."))
        elif status == "finished":
            self._status("Finalizando...")

    # ------------------------------------------------------------------
    # Montagem das opções do yt-dlp
    # ------------------------------------------------------------------
    def _format_selector(self) -> str:
        options = self.options

        if options.mode == "audio":
            return "bestaudio/best"

        quality = options.quality
        if quality == "best":
            return "bestvideo+bestaudio/best"
        return (
            f"bestvideo[height<={quality}]+bestaudio/"
            f"best[height<={quality}]/best"
        )

    def _build_options(self) -> dict:
        options = self.options
        destination = os.path.abspath(os.path.expanduser(options.destination))
        os.makedirs(destination, exist_ok=True)

        if options.playlist:
            outtmpl = os.path.join(
                destination,
                "%(playlist_title,playlist|Playlist)s",
                "%(playlist_index)03d - %(title)s.%(ext)s",
            )
        else:
            outtmpl = os.path.join(destination, "%(title)s.%(ext)s")

        has_ffmpeg = ffmpeg_available()

        if not has_ffmpeg:
            raise RuntimeError(
                "O ffmpeg não está instalado. Ele é necessário para juntar "
                "vídeo e áudio e para converter o áudio em MP3.\n\n"
                "Instale com:\n    sudo apt install ffmpeg"
            )

        ydl_opts: dict = {
            "outtmpl": outtmpl,
            "format": self._format_selector(),
            "noplaylist": not options.playlist,
            "ignoreerrors": True,
            "quiet": True,
            "no_warnings": False,
            "noprogress": True,
            "logger": _Logger(self),
            "progress_hooks": [self._progress_hook],
            "postprocessor_hooks": [self._postprocessor_hook],
            "retries": 10,
            "fragment_retries": 10,
            "socket_timeout": 30,
            "concurrent_fragment_downloads": 4,
            "continuedl": True,
            "overwrites": False,
            "windowsfilenames": False,
            "restrictfilenames": False,
            "trim_file_name": 180,
            "postprocessors": [],
        }

        if has_ffmpeg:
            ffmpeg_path = shutil.which("ffmpeg")
            if ffmpeg_path:
                ydl_opts["ffmpeg_location"] = os.path.dirname(ffmpeg_path)

        if QJS_PATH:
            # QuickJS permite resolver os desafios JavaScript do YouTube.
            # O componente remoto (script solucionador) é baixado na primeira
            # utilização e fica em cache.
            ydl_opts["js_runtimes"] = {"quickjs": {"path": QJS_PATH}}
            ydl_opts["remote_components"] = {"ejs:github"}

        if options.playlist and options.playlist_items.strip():
            ydl_opts["playlist_items"] = options.playlist_items.strip()

        if options.mode == "audio":
            audio_quality = options.quality if options.quality in _AUDIO_QUALITIES else "0"
            ydl_opts["postprocessors"].append(
                {
                    "key": "FFmpegExtractAudio",
                    "preferredcodec": "mp3",
                    "preferredquality": audio_quality,
                }
            )
        else:
            ydl_opts["merge_output_format"] = "mp4"

        if options.embed_metadata and has_ffmpeg:
            ydl_opts["postprocessors"].append({"key": "FFmpegMetadata"})

        return ydl_opts

    # ------------------------------------------------------------------
    # Execução
    # ------------------------------------------------------------------
    def run(self) -> None:
        try:
            ydl_opts = self._build_options()
            self._log(f"yt-dlp {yt_dlp.version.__version__}")
            self._status("Analisando link...")

            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                self._ydl = ydl
                ydl.extract_info(self.options.url, download=True)

            if self._cancel_event.is_set():
                self._finish(False, "Download cancelado.")
            elif self._finished_ids or self._skipped_existing:
                self._finish(True, "Download concluído com sucesso.")
            elif self._errors:
                last_error = _ANSI_RE.sub("", self._errors[-1]).strip()
                self._finish(False, f"Erro: {last_error}")
            else:
                self._finish(
                    False,
                    "Nenhum item foi baixado. Confira o link e os detalhes.",
                )

        except yt_dlp.utils.DownloadCancelled:
            self._finish(False, "Download cancelado.")
        except Exception as exc:  # noqa: BLE001 - erro exibido ao usuário
            message = str(exc).strip() or exc.__class__.__name__
            self._log(f"Erro: {message}")
            self._finish(False, f"Erro: {message}")

    def _finish(self, success: bool, message: str) -> None:
        if self._done_called:
            return
        self._done_called = True
        self._status(message)
        if self.on_done:
            try:
                self.on_done(success, message)
            except Exception:
                pass
