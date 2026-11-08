"""Interface gráfica (GTK3) do TubeFetch."""

from __future__ import annotations

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import threading
from pathlib import Path
from typing import Optional

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")

from gi.repository import Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

from . import APP_DESCRIPTION, APP_ID, APP_NAME, APP_VERSION  # noqa: E402
from .downloader import DownloadJob, DownloadOptions, ffmpeg_available  # noqa: E402
from .ytdlp_loader import YTDLP_ORIGIN, YTDLP_VERSION  # noqa: E402

CONFIG_DIR = Path(GLib.get_user_config_dir()) / "tubefetch"
CONFIG_FILE = CONFIG_DIR / "config.json"
LEGACY_CONFIG_FILE = Path(GLib.get_user_config_dir()) / "baixador-yt" / "config.json"

VIDEO_QUALITIES = [
    ("Melhor qualidade", "best"),
    ("1080p", "1080"),
    ("720p", "720"),
    ("480p", "480"),
    ("360p", "360"),
]

AUDIO_QUALITIES = [
    ("Melhor (V0)", "0"),
    ("320 kbps", "320"),
    ("192 kbps", "192"),
    ("128 kbps", "128"),
]

CSS = """
.section-label {
    font-weight: 700;
}
.url-entry {
    font-size: 1.05em;
    min-height: 38px;
}
.status-label {
    font-weight: 600;
}
.footer-label {
    font-size: 0.82em;
}
.log-view {
    font-size: 0.86em;
}
.download-button {
    font-weight: 700;
}
"""


def _default_download_dir() -> str:
    try:
        folder = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOAD)
    except Exception:
        folder = None
    if folder and os.path.isdir(folder):
        return folder
    fallback = os.path.join(os.path.expanduser("~"), "Downloads")
    if os.path.isdir(fallback):
        return fallback
    return os.path.expanduser("~")


def _load_config() -> dict:
    if not CONFIG_FILE.exists() and LEGACY_CONFIG_FILE.is_file():
        # Migra as preferências da versão antiga (baixador-yt).
        try:
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            shutil.copy2(LEGACY_CONFIG_FILE, CONFIG_FILE)
        except OSError:
            pass
    try:
        with open(CONFIG_FILE, encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_config(config: dict) -> None:
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        temporary = CONFIG_FILE.with_suffix(".tmp")
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(config, handle, ensure_ascii=False, indent=2)
        os.replace(temporary, CONFIG_FILE)
    except OSError:
        pass


def _format_bytes(value) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "—"
    if number <= 0:
        return "—"
    units = ["B", "KB", "MB", "GB", "TB"]
    index = 0
    while number >= 1024 and index < len(units) - 1:
        number /= 1024
        index += 1
    if index == 0:
        return f"{int(number)} B"
    return f"{number:.1f} {units[index]}".replace(".", ",")


def _format_eta(value) -> str:
    try:
        seconds = int(value)
    except (TypeError, ValueError):
        return ""
    if seconds < 0:
        return ""
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes}:{secs:02d}"


def _vendor_version(path: Path) -> Optional[str]:
    versions = []
    for entry in glob.glob(str(path / "yt_dlp-*.dist-info")):
        match = re.match(r"yt_dlp-([^-]+)-", os.path.basename(entry))
        if match:
            versions.append(match.group(1))
    return versions[-1] if versions else None


class MainWindow(Gtk.ApplicationWindow):
    def __init__(self, application: Gtk.Application, initial_url: Optional[str] = None):
        super().__init__(application=application)
        self._app = application
        self._config = _load_config()
        self._destination = self._config.get("destination") or _default_download_dir()
        self._mode = "audio" if self._config.get("mode") == "audio" else "video"
        self._qualities = {
            "video": self._config.get("video_quality", "best"),
            "audio": self._config.get("audio_quality", "0"),
        }
        self._job: Optional[DownloadJob] = None
        self._pulse_id = 0
        self._setting_playlist = False
        self._playlist_touched = False
        self._quality_updating = False
        self._updating_ytdlp = False

        self.set_title(APP_NAME)
        self.set_icon_name("tubefetch")
        self.set_default_size(780, 720)
        self.set_size_request(640, 560)

        self._build_header()
        self._build_content()
        self._apply_config()
        self.connect("destroy", self._on_destroy)

        if initial_url:
            self.set_url(initial_url)

    # ------------------------------------------------------------------
    # Construção da interface
    # ------------------------------------------------------------------
    def _build_header(self) -> None:
        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.set_title(APP_NAME)
        header.set_subtitle(f"YouTube · yt-dlp {YTDLP_VERSION}")
        self.set_titlebar(header)

        menu = Gtk.Menu()

        open_item = Gtk.MenuItem(label="Abrir pasta de downloads")
        open_item.connect("activate", self._open_destination)
        menu.append(open_item)

        update_item = Gtk.MenuItem(label="Atualizar yt-dlp")
        update_item.connect("activate", self._update_ytdlp)
        menu.append(update_item)

        menu.append(Gtk.SeparatorMenuItem())

        about_item = Gtk.MenuItem(label="Sobre")
        about_item.connect("activate", self._show_about)
        menu.append(about_item)
        menu.show_all()

        menu_button = Gtk.MenuButton()
        menu_button.set_popup(menu)
        menu_button.set_image(
            Gtk.Image.new_from_icon_name("open-menu-symbolic", Gtk.IconSize.BUTTON)
        )
        menu_button.set_tooltip_text("Menu")
        header.pack_end(menu_button)

    def _build_content(self) -> None:
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        content.set_border_width(18)
        self.add(content)

        # Link ---------------------------------------------------------
        content.pack_start(self._section_label("Link do YouTube"), False, False, 0)

        url_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.url_entry = Gtk.Entry()
        self.url_entry.set_placeholder_text(
            "Cole aqui o link do vídeo ou da playlist..."
        )
        self.url_entry.set_hexpand(True)
        self.url_entry.get_style_context().add_class("url-entry")
        self.url_entry.connect("changed", self._on_url_changed)
        self.url_entry.connect("activate", lambda *_: self._on_download_clicked())
        url_box.pack_start(self.url_entry, True, True, 0)

        paste_button = Gtk.Button(label="Colar")
        paste_button.set_tooltip_text("Colar link da área de transferência")
        paste_button.connect("clicked", self._paste_url)
        url_box.pack_start(paste_button, False, False, 0)
        content.pack_start(url_box, False, False, 0)

        # Formato ------------------------------------------------------
        format_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.video_radio = Gtk.RadioButton.new_with_label(None, "Vídeo (MP4)")
        self.audio_radio = Gtk.RadioButton.new_with_label_from_widget(
            self.video_radio, "Música (MP3)"
        )
        self.video_radio.connect("toggled", self._on_mode_toggled)
        self.audio_radio.connect("toggled", self._on_mode_toggled)
        format_box.pack_start(self.video_radio, False, False, 0)
        format_box.pack_start(self.audio_radio, False, False, 0)
        format_box.pack_start(
            Gtk.Separator(orientation=Gtk.Orientation.VERTICAL), False, False, 6
        )
        format_box.pack_start(Gtk.Label(label="Qualidade:"), False, False, 0)

        self.quality_combo = Gtk.ComboBoxText()
        self.quality_combo.connect("changed", self._on_quality_changed)
        format_box.pack_start(self.quality_combo, False, False, 0)
        content.pack_start(format_box, False, False, 0)

        # Playlist -----------------------------------------------------
        playlist_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.playlist_check = Gtk.CheckButton(label="Baixar playlist inteira")
        self.playlist_check.connect("toggled", self._on_playlist_toggled)
        playlist_box.pack_start(self.playlist_check, False, False, 0)

        self.items_revealer = Gtk.Revealer()
        self.items_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_LEFT)
        items_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        items_box.pack_start(Gtk.Label(label="Itens:"), False, False, 0)
        self.items_entry = Gtk.Entry()
        self.items_entry.set_width_chars(20)
        self.items_entry.set_placeholder_text("ex.: 1-10, 15")
        self.items_entry.set_tooltip_text(
            "Opcional. Baixe apenas alguns itens da playlist."
        )
        items_box.pack_start(self.items_entry, False, False, 0)
        self.items_revealer.add(items_box)
        playlist_box.pack_start(self.items_revealer, False, False, 0)

        self.metadata_check = Gtk.CheckButton(label="Incorporar metadados")
        self.metadata_check.set_active(True)
        self.metadata_check.set_tooltip_text(
            "Adiciona título, artista e outras informações ao arquivo."
        )
        playlist_box.pack_end(self.metadata_check, False, False, 0)
        content.pack_start(playlist_box, False, False, 0)

        # Destino ------------------------------------------------------
        destination_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        destination_box.pack_start(Gtk.Label(label="Salvar em:"), False, False, 0)
        self.dest_button = Gtk.FileChooserButton(
            title="Escolher pasta de destino",
            action=Gtk.FileChooserAction.SELECT_FOLDER,
        )
        self.dest_button.set_hexpand(True)
        self.dest_button.connect("file-set", self._on_destination_changed)
        destination_box.pack_start(self.dest_button, True, True, 0)
        content.pack_start(destination_box, False, False, 0)

        content.pack_start(
            Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 2
        )

        # Ações --------------------------------------------------------
        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.download_button = Gtk.Button(label="Baixar")
        self.download_button.set_size_request(140, 42)
        self.download_button.get_style_context().add_class("suggested-action")
        self.download_button.get_style_context().add_class("download-button")
        self.download_button.connect("clicked", self._on_download_clicked)
        action_box.pack_start(self.download_button, False, False, 0)

        self.cancel_button = Gtk.Button(label="Cancelar")
        self.cancel_button.set_no_show_all(True)
        self.cancel_button.connect("clicked", self._on_cancel_clicked)
        action_box.pack_start(self.cancel_button, False, False, 0)

        open_button = Gtk.Button(label="Abrir pasta")
        open_button.connect("clicked", self._open_destination)
        action_box.pack_end(open_button, False, False, 0)
        content.pack_start(action_box, False, False, 0)

        # Progresso ----------------------------------------------------
        self.progress = Gtk.ProgressBar()
        self.progress.set_show_text(True)
        self.progress.set_text("Pronto")
        self.progress.set_fraction(0.0)
        content.pack_start(self.progress, False, False, 0)

        self.status_label = Gtk.Label(
            label="Cole um link do YouTube para começar.", xalign=0
        )
        self.status_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.status_label.get_style_context().add_class("status-label")
        content.pack_start(self.status_label, False, False, 0)

        # Log ----------------------------------------------------------
        self.log_expander = Gtk.Expander(label="Detalhes")
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scrolled.set_min_content_height(150)
        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_cursor_visible(False)
        self.log_view.set_monospace(True)
        self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.log_view.get_style_context().add_class("log-view")
        self.log_buffer = self.log_view.get_buffer()
        scrolled.add(self.log_view)
        self.log_expander.add(scrolled)
        content.pack_start(self.log_expander, False, False, 0)

        footer = Gtk.Label(
            label=f"yt-dlp {YTDLP_VERSION} · {YTDLP_ORIGIN}", xalign=1
        )
        footer.get_style_context().add_class("dim-label")
        footer.get_style_context().add_class("footer-label")
        content.pack_start(footer, False, False, 0)

    def _section_label(self, text: str) -> Gtk.Label:
        label = Gtk.Label(label=text, xalign=0)
        label.get_style_context().add_class("section-label")
        return label

    # ------------------------------------------------------------------
    # Configuração inicial
    # ------------------------------------------------------------------
    def _apply_config(self) -> None:
        if not os.path.isdir(self._destination):
            self._destination = _default_download_dir()

        try:
            self.dest_button.set_filename(self._destination)
        except Exception:
            self.dest_button.set_current_folder(self._destination)

        self._setting_playlist = True
        self.playlist_check.set_active(bool(self._config.get("playlist", False)))
        self._setting_playlist = False
        self.items_revealer.set_reveal_child(self.playlist_check.get_active())

        self.items_entry.set_text(str(self._config.get("playlist_items", "")))
        self.metadata_check.set_active(bool(self._config.get("embed_metadata", True)))

        if self._mode == "audio":
            self.audio_radio.set_active(True)
        else:
            self.video_radio.set_active(True)
        self._populate_qualities()

    def _populate_qualities(self) -> None:
        self._quality_updating = True
        self.quality_combo.remove_all()
        choices = AUDIO_QUALITIES if self._mode == "audio" else VIDEO_QUALITIES
        for label, identifier in choices:
            self.quality_combo.append(identifier, label)
        self.quality_combo.set_active_id(self._qualities[self._mode])
        if self.quality_combo.get_active_id() is None:
            self.quality_combo.set_active(0)
            self._qualities[self._mode] = choices[0][1]
        self._quality_updating = False

    # ------------------------------------------------------------------
    # Eventos simples
    # ------------------------------------------------------------------
    def set_url(self, url: str) -> None:
        self.url_entry.set_text(url.strip())
        self.url_entry.grab_focus()
        self.url_entry.set_position(-1)

    def _paste_url(self, *_args) -> None:
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        text = clipboard.wait_for_text()
        if text:
            self.set_url(text)

    def _on_url_changed(self, entry: Gtk.Entry) -> None:
        text = entry.get_text().strip()
        if not text:
            self._playlist_touched = False
            return
        if (
            "list=" in text
            and not self._playlist_touched
            and not self.playlist_check.get_active()
        ):
            self._setting_playlist = True
            self.playlist_check.set_active(True)
            self._setting_playlist = False

    def _on_mode_toggled(self, button: Gtk.RadioButton) -> None:
        if not button.get_active():
            return
        self._mode = "audio" if self.audio_radio.get_active() else "video"
        self._populate_qualities()

    def _on_quality_changed(self, combo: Gtk.ComboBoxText) -> None:
        if self._quality_updating:
            return
        identifier = combo.get_active_id()
        if identifier:
            self._qualities[self._mode] = identifier

    def _on_playlist_toggled(self, button: Gtk.CheckButton) -> None:
        self.items_revealer.set_reveal_child(button.get_active())
        if not self._setting_playlist:
            self._playlist_touched = True

    def _on_destination_changed(self, button: Gtk.FileChooserButton) -> None:
        filename = button.get_filename()
        if filename and os.path.isdir(filename):
            self._destination = filename

    # ------------------------------------------------------------------
    # Download
    # ------------------------------------------------------------------
    def _on_download_clicked(self, *_args) -> None:
        if self._job is not None:
            return

        url = self.url_entry.get_text().strip()
        if not url:
            self._show_error("Link vazio", "Cole o link de um vídeo ou playlist do YouTube.")
            return
        if not re.match(r"^https?://", url, re.IGNORECASE):
            self._show_error(
                "Link inválido",
                "O link precisa começar com http:// ou https://.",
            )
            return

        playlist = self.playlist_check.get_active()
        playlist_items = self.items_entry.get_text().strip()
        if playlist and playlist_items and not re.fullmatch(r"[0-9,\-\s]+", playlist_items):
            self._show_error(
                "Itens inválidos",
                "Use apenas números, vírgulas e hífens. Exemplo: 1-10, 15",
            )
            return

        if not os.path.isdir(self._destination):
            try:
                os.makedirs(self._destination, exist_ok=True)
            except OSError as exc:
                self._show_error("Pasta inválida", f"Não foi possível criar a pasta:\n{exc}")
                return

        if not ffmpeg_available():
            self._show_error(
                "ffmpeg não encontrado",
                "O ffmpeg é necessário para juntar vídeo e áudio e para "
                "converter o áudio em MP3.\n\n"
                "Instale com:\n    sudo apt install ffmpeg",
            )
            return

        self._save_current_config()
        self._log_clear()
        self._append_log(f"Link: {url}")
        self._append_log(f"Destino: {self._destination}")
        self._append_log(
            "Formato: "
            + ("MP3" if self._mode == "audio" else "MP4")
            + " · qualidade "
            + (self.quality_combo.get_active_id() or "")
        )
        if playlist:
            self._append_log("Playlist: completa" + (f" (itens {playlist_items})" if playlist_items else ""))

        self.progress.set_fraction(0.0)
        self.progress.set_text("Iniciando...")
        self.status_label.set_text("Preparando download...")
        self._set_running(True)
        self._start_pulse()

        options = DownloadOptions(
            url=url,
            destination=self._destination,
            mode=self._mode,
            quality=self._qualities[self._mode],
            playlist=playlist,
            playlist_items=playlist_items,
            embed_metadata=self.metadata_check.get_active(),
        )

        self._job = DownloadJob(
            options,
            on_progress=lambda payload: GLib.idle_add(self._on_progress, payload),
            on_status=lambda text: GLib.idle_add(self._on_status, text),
            on_log=lambda text: GLib.idle_add(self._on_log, text),
            on_title=lambda text: GLib.idle_add(self._on_title, text),
            on_done=lambda success, message: GLib.idle_add(
                self._on_done, success, message
            ),
        )

        threading.Thread(target=self._job.run, daemon=True).start()

    def _on_cancel_clicked(self, *_args) -> None:
        if self._job is not None:
            self._job.cancel()
            self.cancel_button.set_sensitive(False)
            self.status_label.set_text("Cancelando...")

    def _on_progress(self, payload: dict) -> bool:
        self._stop_pulse()
        fraction = max(0.0, min(1.0, float(payload.get("percent") or 0.0)))
        self.progress.set_fraction(fraction)

        parts = [f"{fraction * 100:.1f}%".replace(".", ",")]
        speed = payload.get("speed")
        if speed:
            parts.append(f"{_format_bytes(speed)}/s")
        eta = _format_eta(payload.get("eta"))
        if eta:
            parts.append(f"restam {eta}")
        self.progress.set_text(" · ".join(parts))

        index = payload.get("index")
        count = payload.get("count")
        title = payload.get("title") or ""
        phase = payload.get("phase") or "Baixando"
        if index and count:
            text = f"Item {index} de {count} · {phase}"
            if title:
                text += f" — {title}"
            self.status_label.set_text(text)
        elif title:
            self.status_label.set_text(f"{phase} — {title}")
        else:
            self.status_label.set_text(phase)
        return False

    def _on_status(self, text: str) -> bool:
        self.status_label.set_text(text)
        return False

    def _on_title(self, title: str) -> bool:
        if self._job is not None:
            self.status_label.set_text(title)
        return False

    def _on_log(self, text: str) -> bool:
        self._append_log(text)
        return False

    def _on_done(self, success: bool, message: str) -> bool:
        self._stop_pulse()
        self._job = None
        self._set_running(False)

        if success:
            self.progress.set_fraction(1.0)
            self.progress.set_text("100%")
            self.status_label.set_text(message)
            self._notify("Download concluído", f"Arquivos salvos em {self._destination}")
        else:
            self.status_label.set_text(message)
            if "cancelado" in message.lower():
                self.progress.set_fraction(0.0)
                self.progress.set_text("Cancelado")
            else:
                self.progress.set_text("Falhou")
                self.log_expander.set_expanded(True)
                self._show_error("Não foi possível baixar", message[:700])
        return False

    def _set_running(self, running: bool) -> None:
        for widget in (
            self.url_entry,
            self.video_radio,
            self.audio_radio,
            self.quality_combo,
            self.playlist_check,
            self.items_entry,
            self.metadata_check,
            self.dest_button,
        ):
            widget.set_sensitive(not running)
        self.download_button.set_sensitive(not running)
        self.cancel_button.set_visible(running)
        self.cancel_button.set_sensitive(True)

    def _start_pulse(self) -> None:
        self._stop_pulse()
        self._pulse_id = GLib.timeout_add(120, self._pulse)

    def _pulse(self) -> bool:
        self.progress.pulse()
        return True

    def _stop_pulse(self) -> None:
        if self._pulse_id:
            GLib.source_remove(self._pulse_id)
            self._pulse_id = 0

    # ------------------------------------------------------------------
    # Log
    # ------------------------------------------------------------------
    def _log_clear(self) -> None:
        self.log_buffer.set_text("")

    def _append_log(self, text: str) -> None:
        end = self.log_buffer.get_end_iter()
        self.log_buffer.insert(end, text + "\n")
        if self.log_buffer.get_line_count() > 4000:
            start = self.log_buffer.get_start_iter()
            cut = self.log_buffer.get_iter_at_line(1000)
            self.log_buffer.delete(start, cut)
        end = self.log_buffer.get_end_iter()
        self.log_view.scroll_to_iter(end, 0.0, False, 0.0, 0.0)

    # ------------------------------------------------------------------
    # Ações do menu
    # ------------------------------------------------------------------
    def _open_destination(self, *_args) -> None:
        try:
            os.makedirs(self._destination, exist_ok=True)
            Gio.AppInfo.launch_default_for_uri(
                Path(self._destination).as_uri(), None
            )
        except Exception as exc:
            self._show_error("Não foi possível abrir a pasta", str(exc))

    def _update_ytdlp(self, *_args) -> None:
        if self._updating_ytdlp:
            return
        if not self._confirm(
            "Atualizar yt-dlp?",
            "O aplicativo vai baixar a versão mais recente do yt-dlp para a sua "
            "pasta de usuário. É necessário estar conectado à internet.\n\n"
            "O download atual usa a versão embutida "
            f"{YTDLP_VERSION}.",
        ):
            return

        self._updating_ytdlp = True
        self.status_label.set_text("Atualizando yt-dlp...")
        self._append_log("Atualizando yt-dlp com pip...")
        threading.Thread(target=self._run_ytdlp_update, daemon=True).start()

    def _run_ytdlp_update(self) -> None:
        target = Path(GLib.get_user_data_dir()) / "tubefetch" / "vendor"
        target.mkdir(parents=True, exist_ok=True)
        command = [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--upgrade",
            "--target",
            str(target),
            "--disable-pip-version-check",
            "yt-dlp",
        ]
        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            assert process.stdout is not None
            for line in process.stdout:
                line = line.rstrip()
                if line:
                    GLib.idle_add(self._on_log, line)
            returncode = process.wait()
        except Exception as exc:  # noqa: BLE001
            GLib.idle_add(self._on_ytdlp_update_done, False, str(exc))
            return
        GLib.idle_add(self._on_ytdlp_update_done, returncode == 0, "")

    def _on_ytdlp_update_done(self, success: bool, error: str) -> bool:
        self._updating_ytdlp = False
        if not success:
            self.status_label.set_text("Falha ao atualizar o yt-dlp.")
            self.log_expander.set_expanded(True)
            self._show_error(
                "Falha ao atualizar o yt-dlp",
                error or "Verifique a conexão com a internet e os detalhes.",
            )
            return False

        target = Path(GLib.get_user_data_dir()) / "tubefetch" / "vendor"
        version = _vendor_version(target) or "mais recente"
        self.status_label.set_text(f"yt-dlp {version} instalado. Reinicie o aplicativo.")
        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.NONE,
            text=f"yt-dlp {version} foi baixado.",
        )
        dialog.format_secondary_text(
            "Feche e abra o aplicativo novamente para usar a nova versão."
        )
        dialog.add_button("Depois", Gtk.ResponseType.CLOSE)
        restart = dialog.add_button("Reiniciar agora", Gtk.ResponseType.OK)
        restart.get_style_context().add_class("suggested-action")
        response = dialog.run()
        dialog.destroy()
        if response == Gtk.ResponseType.OK:
            self._restart()
        return False

    def _restart(self) -> None:
        self._save_current_config()
        os.execv(sys.executable, [sys.executable, "-m", "tubefetch"] + sys.argv[1:])

    def _show_about(self, *_args) -> None:
        dialog = Gtk.AboutDialog(transient_for=self, modal=True)
        dialog.set_program_name(APP_NAME)
        dialog.set_version(APP_VERSION)
        dialog.set_comments(
            APP_DESCRIPTION
            + f"\n\nyt-dlp {YTDLP_VERSION} ({YTDLP_ORIGIN})"
        )
        dialog.set_license_type(Gtk.License.MIT_X11)
        dialog.set_authors(["LazLabs"])
        dialog.set_logo_icon_name("tubefetch")
        dialog.run()
        dialog.destroy()

    # ------------------------------------------------------------------
    # Utilidades
    # ------------------------------------------------------------------
    def _notify(self, title: str, body: str) -> None:
        try:
            notification = Gio.Notification.new(title)
            notification.set_body(body)
            notification.set_icon(Gio.ThemedIcon.new("tubefetch"))
            self._app.send_notification(None, notification)
        except Exception:
            pass

    def _show_error(self, title: str, message: str) -> None:
        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.CLOSE,
            text=title,
        )
        dialog.format_secondary_text(message)
        dialog.run()
        dialog.destroy()

    def _confirm(self, title: str, message: str) -> bool:
        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text=title,
        )
        dialog.format_secondary_text(message)
        response = dialog.run()
        dialog.destroy()
        return response == Gtk.ResponseType.OK

    def _save_current_config(self) -> None:
        _save_config(
            {
                "destination": self._destination,
                "mode": self._mode,
                "video_quality": self._qualities["video"],
                "audio_quality": self._qualities["audio"],
                "playlist": self.playlist_check.get_active(),
                "playlist_items": self.items_entry.get_text().strip(),
                "embed_metadata": self.metadata_check.get_active(),
            }
        )

    def _on_destroy(self, *_args) -> None:
        self._stop_pulse()
        if self._job is not None:
            self._job.cancel()
        self._save_current_config()


class TubeFetchApplication(Gtk.Application):
    def __init__(self) -> None:
        super().__init__(
            application_id=APP_ID,
            flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE,
        )
        self._window: Optional[MainWindow] = None
        self._pending_url: Optional[str] = None

    def do_startup(self) -> None:
        Gtk.Application.do_startup(self)
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode("utf-8"))
        screen = Gdk.Screen.get_default()
        if screen is not None:
            Gtk.StyleContext.add_provider_for_screen(
                screen,
                provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
            )

    def do_command_line(self, command_line: Gio.ApplicationCommandLine) -> int:
        arguments = command_line.get_arguments()
        urls = [
            argument
            for argument in arguments[1:]
            if argument.lower().startswith(("http://", "https://"))
        ]
        self._pending_url = urls[0] if urls else None
        self.activate()
        return 0

    def do_activate(self) -> None:
        if self._window is None:
            self._window = MainWindow(self)
            self._window.show_all()
        self._window.present()
        if self._pending_url:
            self._window.set_url(self._pending_url)
            self._pending_url = None
