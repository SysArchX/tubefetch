"""Navegador estilo Chrome (GTK3 + WebKit2GTK) do FastSearchX.

A janela principal do aplicativo é este navegador com abas. O baixador de
vídeos/músicas (yt-dlp) continua disponível pelo botão de download da barra de
ferramentas, pelo menu e pelo botão direito sobre um link.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Callable, Optional
from urllib.parse import quote_plus, unquote, urlparse

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")

from gi.repository import Gdk, Gio, GLib, Gtk, Pango, WebKit2  # noqa: E402

from . import APP_DESCRIPTION, APP_NAME, APP_VERSION  # noqa: E402

HOME_URL = "https://www.google.com"
SEARCH_ENGINE = "https://www.google.com/search?q={}"
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

BROWSER_CSS = """
.browser-toolbar {
    background-image: linear-gradient(to bottom, #f7f7f8, #ececee);
    border-bottom: 1px solid rgba(0, 0, 0, 0.12);
    padding: 6px 8px;
}
.address-field {
    background-color: #ffffff;
    border: 1px solid rgba(0, 0, 0, 0.18);
    border-radius: 999px;
    padding: 5px 12px;
    min-height: 26px;
}
.address-field:focus {
    border-color: #1a73e8;
    box-shadow: 0 0 0 2px rgba(26, 115, 232, 0.20);
}
.browser-tab-close {
    padding: 0;
    min-width: 18px;
    min-height: 18px;
}
.browser-download-bar {
    background-image: linear-gradient(to bottom, #f6f6f7, #ededef);
    border-top: 1px solid rgba(0, 0, 0, 0.12);
}
.browser-download-done {
    color: #137333;
    font-weight: 600;
}
"""


def _download_dir() -> Path:
    try:
        folder = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOAD)
    except Exception:
        folder = None
    base = Path(folder) if folder else Path.home() / "Downloads"
    if not base.is_dir():
        base = Path.home()
    return base


def _unique_path(folder: Path, filename: str) -> Path:
    filename = filename.strip() or "download"
    target = folder / filename
    if not target.exists():
        return target
    stem, suffix = target.stem, target.suffix
    index = 1
    while True:
        candidate = folder / f"{stem} ({index}){suffix}"
        if not candidate.exists():
            return candidate
        index += 1


def _filename_from_uri(uri: str) -> str:
    try:
        path = unquote(urlparse(uri).path)
    except Exception:
        path = ""
    name = os.path.basename(path)
    if not name or name in {"/", "."}:
        name = "download"
    return name


def normalize_input(text: str) -> str:
    """Transforma o texto da barra de endereço em URL (como o Chrome)."""
    value = (text or "").strip()
    if not value:
        return HOME_URL
    lower = value.lower()
    if lower.startswith(("http://", "https://", "file://", "about:")):
        return value
    if lower.startswith(("www.", "ftp.")) or (
        "." in value and " " not in value and not value.startswith(".")
    ):
        return "https://" + value
    if lower in {"localhost"} or lower.startswith("localhost:"):
        return "http://" + value
    return SEARCH_ENGINE.format(quote_plus(value))


class DownloadEntry:
    """Uma linha da barra de downloads (estilo Chrome)."""

    def __init__(self, download: WebKit2.Download, path: Path):
        self.download = download
        self.path = path
        self.cancelled = False
        self.finished = False
        self.failed = False
        self.last_bytes = -1
        self.stable_ticks = 0

        self.row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.row.set_border_width(6)

        self.icon = Gtk.Image.new_from_icon_name(
            "folder-download-symbolic", Gtk.IconSize.BUTTON
        )
        self.row.pack_start(self.icon, False, False, 0)

        text_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.label = Gtk.Label(label=path.name)
        self.label.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        self.label.set_xalign(0)
        self.progress = Gtk.ProgressBar()
        self.progress.set_size_request(240, -1)
        text_box.pack_start(self.label, False, False, 0)
        text_box.pack_start(self.progress, False, False, 0)
        self.row.pack_start(text_box, True, True, 0)

        self.action = Gtk.Button()
        self.action.set_relief(Gtk.ReliefStyle.NONE)
        self.action.set_image(
            Gtk.Image.new_from_icon_name("window-close-symbolic", Gtk.IconSize.BUTTON)
        )
        self.action.set_tooltip_text("Cancelar download")
        self.row.pack_end(self.action, False, False, 0)

        self.row.show_all()
        self.progress.hide()


class BrowserWindow(Gtk.ApplicationWindow):
    """Janela principal: navegador com abas."""

    def __init__(
        self,
        application: Gtk.Application,
        on_download: Optional[Callable[[str], None]] = None,
    ):
        super().__init__(application=application)
        self._on_download = on_download
        self._context = WebKit2.WebContext.get_default()
        self._downloads: list[DownloadEntry] = []
        self._download_loop: Optional[int] = None
        self._context_handler = None
        self._tabs: dict[WebKit2.WebView, Gtk.Widget] = {}
        self._address_focused = False
        self._window_fullscreen = False
        self._download_folder = _download_dir()

        self.set_title(APP_NAME)
        self.set_icon_name("fastsearchx")
        self.set_default_size(1180, 780)
        self.set_size_request(720, 480)
        self._accel_group = Gtk.AccelGroup()
        self.add_accel_group(self._accel_group)
        self.connect("destroy", self._on_destroy)

        self._build_ui()
        self._install_download_handler()
        self._connect_shortcuts()

        self.new_tab(HOME_URL)
        self._refresh_navigation()

    # ------------------------------------------------------------------
    # Interface
    # ------------------------------------------------------------------
    def _build_ui(self) -> None:
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(outer)

        # Barra de ferramentas -----------------------------------------
        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        toolbar.get_style_context().add_class("browser-toolbar")
        outer.pack_start(toolbar, False, False, 0)

        self.back_button = self._tool_button(
            "go-previous-symbolic", "Voltar (Alt+←)", self.go_back
        )
        self.forward_button = self._tool_button(
            "go-next-symbolic", "Avançar (Alt+→)", self.go_forward
        )
        self.reload_button = self._tool_button(
            "view-refresh-symbolic", "Recarregar (Ctrl+R)", self.reload
        )
        self.home_button = self._tool_button(
            "go-home-symbolic", "Página inicial", self.go_home
        )
        for button in (
            self.back_button,
            self.forward_button,
            self.reload_button,
            self.home_button,
        ):
            toolbar.pack_start(button, False, False, 0)

        address_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        address_box.set_hexpand(True)
        address_box.set_margin_start(6)
        address_box.set_margin_end(6)

        self.security_icon = Gtk.Image.new_from_icon_name(
            "channel-secure-symbolic", Gtk.IconSize.BUTTON
        )
        self.security_icon.set_tooltip_text("Conexão HTTPS")
        address_box.pack_start(self.security_icon, False, False, 0)

        self.address_entry = Gtk.Entry()
        self.address_entry.set_placeholder_text("Pesquise no Google ou digite um endereço")
        self.address_entry.set_hexpand(True)
        self.address_entry.get_style_context().add_class("address-field")
        self.address_entry.connect("activate", self._on_address_activated)
        self.address_entry.connect("focus-in-event", self._on_address_focus_in)
        self.address_entry.connect("focus-out-event", self._on_address_focus_out)
        address_box.pack_start(self.address_entry, True, True, 0)
        toolbar.pack_start(address_box, True, True, 0)

        self.download_button = self._tool_button(
            "folder-download-symbolic",
            "Baixar vídeo/áudio desta página",
            self._download_current_page,
        )
        self.new_tab_button = self._tool_button(
            "tab-new-symbolic", "Novo separador (Ctrl+T)", lambda: self.new_tab()
        )
        for button in (self.download_button, self.new_tab_button):
            toolbar.pack_start(button, False, False, 0)

        menu_button = Gtk.MenuButton()
        menu_button.set_image(
            Gtk.Image.new_from_icon_name("open-menu-symbolic", Gtk.IconSize.BUTTON)
        )
        menu_button.set_tooltip_text("Menu")
        menu_button.set_popup(self._build_menu())
        toolbar.pack_start(menu_button, False, False, 0)

        # Barra de progresso fina (estilo Chrome) ----------------------
        self.load_bar = Gtk.ProgressBar()
        self.load_bar.set_size_request(-1, 3)
        self.load_bar.set_fraction(0.0)
        self.load_bar.set_show_text(False)
        outer.pack_start(self.load_bar, False, False, 0)

        # Abas ---------------------------------------------------------
        self.notebook = Gtk.Notebook()
        self.notebook.set_scrollable(True)
        self.notebook.set_show_border(False)
        self.notebook.connect("switch-page", self._on_switch_page)
        outer.pack_start(self.notebook, True, True, 0)

        # Barra de downloads ------------------------------------------
        self.download_revealer = Gtk.Revealer()
        self.download_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP)
        download_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        download_box.get_style_context().add_class("browser-download-bar")

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        header.set_border_width(6)
        header_label = Gtk.Label(label="Downloads")
        header_label.set_xalign(0)
        header_label.get_style_context().add_class("section-label")
        header.pack_start(header_label, True, True, 0)
        open_folder = Gtk.Button(label="Abrir pasta")
        open_folder.set_relief(Gtk.ReliefStyle.NONE)
        open_folder.connect("clicked", self._open_download_folder)
        header.pack_end(open_folder, False, False, 0)
        clear_button = Gtk.Button()
        clear_button.set_relief(Gtk.ReliefStyle.NONE)
        clear_button.set_image(
            Gtk.Image.new_from_icon_name("window-close-symbolic", Gtk.IconSize.BUTTON)
        )
        clear_button.set_tooltip_text("Fechar a barra de downloads")
        clear_button.connect("clicked", lambda *_: self.download_revealer.set_reveal_child(False))
        header.pack_end(clear_button, False, False, 0)
        download_box.pack_start(header, False, False, 0)

        self.download_list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        download_box.pack_start(self.download_list, False, False, 0)
        self.download_revealer.add(download_box)
        outer.pack_end(self.download_revealer, False, False, 0)

        # Barra de status (destino de links) ---------------------------
        self.status_label = Gtk.Label(label="")
        self.status_label.set_xalign(0)
        self.status_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.status_label.set_margin_start(10)
        self.status_label.set_margin_end(10)
        self.status_label.set_margin_top(2)
        self.status_label.set_margin_bottom(2)
        self.status_label.get_style_context().add_class("footer-label")
        outer.pack_end(self.status_label, False, False, 0)

    def _tool_button(self, icon: str, tooltip: str, callback) -> Gtk.Button:
        button = Gtk.Button()
        button.set_relief(Gtk.ReliefStyle.NONE)
        button.set_image(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.BUTTON))
        button.set_tooltip_text(tooltip)
        button.connect("clicked", lambda *_: callback())
        return button

    def _build_menu(self) -> Gtk.Menu:
        menu = Gtk.Menu()

        def item(label: str, callback) -> None:
            entry = Gtk.MenuItem(label=label)
            entry.connect("activate", lambda *_: callback())
            menu.append(entry)

        item("Novo separador (Ctrl+T)", lambda: self.new_tab())
        item("Baixar vídeo/áudio desta página", self._download_current_page)
        item("Downloads (Ctrl+J)", self._show_downloads)
        menu.append(Gtk.SeparatorMenuItem())
        item("Abrir pasta de downloads", self._open_download_folder)
        menu.append(Gtk.SeparatorMenuItem())
        item("Sobre o FastSearchX", self._show_about)
        item("Sair", lambda: self.get_application().quit())
        menu.show_all()
        return menu

    # ------------------------------------------------------------------
    # Abas
    # ------------------------------------------------------------------
    def _new_webview(self) -> WebKit2.WebView:
        view = WebKit2.WebView.new_with_context(self._context)
        settings = view.get_settings()
        for attribute, value in (
            ("enable-javascript", True),
            ("enable-media", True),
            ("enable-media-stream", True),
            ("enable-mediasource", True),
            ("enable-smooth-scrolling", True),
            ("enable-webrtc", True),
        ):
            try:
                settings.set_property(attribute, value)
            except (TypeError, ValueError):
                pass
        try:
            settings.set_user_agent(USER_AGENT)
        except (AttributeError, TypeError):
            pass

        view.connect("load-changed", self._on_load_changed)
        view.connect("notify::title", self._on_title_changed)
        view.connect("notify::uri", self._on_uri_changed)
        view.connect("notify::estimated-load-progress", self._on_progress)
        view.connect("create", self._on_create_window)
        view.connect("context-menu", self._on_context_menu)
        view.connect("mouse-target-changed", self._on_mouse_target_changed)
        view.connect("enter-fullscreen", self._on_enter_fullscreen)
        view.connect("leave-fullscreen", self._on_leave_fullscreen)
        return view

    def new_tab(self, url: Optional[str] = None) -> WebKit2.WebView:
        view = self._new_webview()
        label = self._make_tab_label("Nova aba", view)
        page = self.notebook.append_page(view, label)
        self._tabs[view] = label
        self.notebook.set_current_page(page)
        view.load_uri(url or HOME_URL)
        self.notebook.show_all()
        if self._address_focused:
            self.address_entry.grab_focus()
        return view

    def _make_tab_label(self, title: str, view: WebKit2.WebView) -> Gtk.Box:
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        label = Gtk.Label(label=title)
        label.set_ellipsize(Pango.EllipsizeMode.END)
        label.set_max_width_chars(24)
        label.set_xalign(0)
        box.pack_start(label, True, True, 0)

        close = Gtk.Button()
        close.set_relief(Gtk.ReliefStyle.NONE)
        close.set_focus_on_click(False)
        close.get_style_context().add_class("browser-tab-close")
        close.set_image(
            Gtk.Image.new_from_icon_name("window-close-symbolic", Gtk.IconSize.MENU)
        )
        close.set_tooltip_text("Fechar separador")
        close.connect("clicked", lambda *_: self.close_tab(view))
        box.pack_end(close, False, False, 0)
        box.show_all()
        return box

    def current_view(self) -> Optional[WebKit2.WebView]:
        return self.notebook.get_nth_page(self.notebook.get_current_page())

    def close_tab(self, view: WebKit2.WebView) -> None:
        if view not in self._tabs:
            return
        index = self.notebook.page_num(view)
        self._tabs.pop(view, None)
        self.notebook.remove_page(index)
        try:
            view.stop_loading()
            view.destroy()
        except Exception:
            pass
        if self.notebook.get_n_pages() == 0:
            self.close()
        else:
            self._refresh_navigation()

    def _on_switch_page(self, notebook, page, page_num) -> None:
        self._refresh_navigation()

    # ------------------------------------------------------------------
    # Navegação
    # ------------------------------------------------------------------
    def open_url(self, url: str) -> None:
        target = normalize_input(url)
        view = self.current_view()
        if view is None:
            self.new_tab(target)
        else:
            view.load_uri(target)

    def _on_address_activated(self, entry: Gtk.Entry) -> None:
        self.open_url(entry.get_text())
        self.current_view().grab_focus()

    def go_back(self) -> None:
        view = self.current_view()
        if view is not None and view.can_go_back():
            view.go_back()

    def go_forward(self) -> None:
        view = self.current_view()
        if view is not None and view.can_go_forward():
            view.go_forward()

    def reload(self) -> None:
        view = self.current_view()
        if view is None:
            return
        if view.is_loading():
            view.stop_loading()
        else:
            view.reload()

    def go_home(self) -> None:
        view = self.current_view()
        if view is not None:
            view.load_uri(HOME_URL)

    def _refresh_navigation(self) -> None:
        view = self.current_view()
        if view is None:
            return
        self.back_button.set_sensitive(view.can_go_back())
        self.forward_button.set_sensitive(view.can_go_forward())
        self.reload_button.set_image(
            Gtk.Image.new_from_icon_name(
                "process-stop-symbolic" if view.is_loading() else "view-refresh-symbolic",
                Gtk.IconSize.BUTTON,
            )
        )
        if not self._address_focused:
            self._set_address(view.get_uri() or "")

        uri = view.get_uri() or ""
        secure = uri.startswith("https://")
        self.security_icon.set_from_icon_name(
            "channel-secure-symbolic" if secure else "dialog-warning-symbolic",
            Gtk.IconSize.BUTTON,
        )
        self.security_icon.set_tooltip_text(
            "Conexão segura (HTTPS)" if secure else "Site sem HTTPS"
        )

    def _set_address(self, text: str) -> None:
        self.address_entry.set_text(text)
        self.address_entry.set_position(-1)

    def _on_address_focus_in(self, entry, event) -> bool:
        self._address_focused = True
        GLib.idle_add(entry.select_region, 0, -1)
        return False

    def _on_address_focus_out(self, entry, event) -> bool:
        self._address_focused = False
        self._refresh_navigation()
        return False

    # ------------------------------------------------------------------
    # Eventos do WebView
    # ------------------------------------------------------------------
    def _on_load_changed(self, view: WebKit2.WebView, event) -> None:
        if event == WebKit2.LoadEvent.STARTED:
            self.load_bar.show()
            self.load_bar.set_fraction(0.0)
        elif event == WebKit2.LoadEvent.COMMITTED:
            pass
        elif event == WebKit2.LoadEvent.FINISHED:
            self.load_bar.set_fraction(1.0)
            GLib.timeout_add(250, self._hide_load_bar)
        if view is self.current_view():
            self._refresh_navigation()

    def _hide_load_bar(self) -> bool:
        if not any(view.is_loading() for view in self._tabs):
            self.load_bar.hide()
            self.load_bar.set_fraction(0.0)
        return False

    def _on_progress(self, view: WebKit2.WebView, *_args) -> None:
        if view is self.current_view():
            value = view.get_estimated_load_progress()
            if 0.0 <= value < 1.0:
                self.load_bar.show()
                self.load_bar.set_fraction(value)

    def _on_title_changed(self, view: WebKit2.WebView, *_args) -> None:
        title = view.get_title() or view.get_uri() or "Nova aba"
        label = self._tabs.get(view)
        if label is not None:
            text_label = label.get_children()[0]
            if isinstance(text_label, Gtk.Label):
                text_label.set_text(title)
        if view is self.current_view():
            self.set_title(f"{title} — {APP_NAME}")
            if not self._address_focused:
                self._set_address(view.get_uri() or "")

    def _on_uri_changed(self, view: WebKit2.WebView, *_args) -> None:
        if view is self.current_view() and not self._address_focused:
            self._set_address(view.get_uri() or "")
            self._refresh_navigation()

    def _on_create_window(self, view: WebKit2.WebView, action) -> WebKit2.WebView:
        new_view = self._new_webview()
        label = self._make_tab_label("Nova aba", new_view)
        self.notebook.append_page(new_view, label)
        self._tabs[new_view] = label
        new_view.connect("ready-to-show", self._on_ready_to_show)
        self.notebook.show_all()
        return new_view

    def _on_ready_to_show(self, view: WebKit2.WebView) -> None:
        self.notebook.set_current_page(self.notebook.page_num(view))
        self.notebook.show_all()

    def _on_mouse_target_changed(self, view, hit_test, modifiers) -> None:
        try:
            if hit_test.context_is_link():
                self.status_label.set_text(hit_test.get_link_uri() or "")
            else:
                self.status_label.set_text("")
        except Exception:
            pass

    def _on_enter_fullscreen(self, view) -> bool:
        self.fullscreen()
        self._window_fullscreen = True
        return True

    def _on_leave_fullscreen(self, view) -> bool:
        if self._window_fullscreen:
            self.unfullscreen()
            self._window_fullscreen = False
        return True

    # ------------------------------------------------------------------
    # Menu de contexto (botão direito)
    # ------------------------------------------------------------------
    def _on_context_menu(self, view: WebKit2.WebView, context_menu, event, hit_test) -> bool:
        self._context_actions = []
        try:
            if hit_test.context_is_link():
                uri = hit_test.get_link_uri()
                if uri:
                    self._append_menu_action(
                        context_menu,
                        "Abrir link em nova aba",
                        lambda: self.new_tab(uri),
                    )
                    self._append_menu_action(
                        context_menu,
                        "Baixar link com o FastSearchX",
                        lambda: self._request_download(uri),
                    )
            if hit_test.context_is_media():
                uri = hit_test.get_media_uri()
                if uri:
                    self._append_menu_action(
                        context_menu,
                        "Baixar mídia com o FastSearchX",
                        lambda: self._request_download(uri),
                    )
            if hit_test.context_is_image():
                uri = hit_test.get_image_uri()
                if uri:
                    self._append_menu_action(
                        context_menu,
                        "Salvar imagem",
                        lambda: self._request_download(uri),
                    )
        except Exception:
            pass
        return False

    def _append_menu_action(self, context_menu, label: str, callback) -> None:
        action = Gio.SimpleAction.new(f"ctx-{id(callback)}", None)
        action.connect("activate", lambda *_args: callback())
        item = WebKit2.ContextMenuItem.new_from_gaction(action, label, None)
        context_menu.append(item)
        # Mantém a ação viva enquanto o menu existir.
        self._context_actions.append(action)

    # ------------------------------------------------------------------
    # Downloads
    # ------------------------------------------------------------------
    def _install_download_handler(self) -> None:
        try:
            self._context_handler = self._context.connect(
                "download-started", self._on_download_started
            )
        except TypeError:
            self._context_handler = None

    def _on_download_started(self, context, download: WebKit2.Download) -> None:
        try:
            uri = download.get_request().get_uri() or ""
        except Exception:
            uri = ""
        path = _unique_path(self._download_folder, _filename_from_uri(uri))
        try:
            download.set_destination(str(path))
        except Exception:
            pass

        entry = DownloadEntry(download, path)
        entry.cancel_handler = entry.action.connect(
            "clicked", lambda *_: self._cancel_download(entry)
        )
        self.download_list.pack_start(entry.row, False, False, 0)
        self.download_list.show_all()
        self.download_revealer.set_reveal_child(True)
        self._downloads.append(entry)
        self._ensure_download_loop()

    def _ensure_download_loop(self) -> None:
        if self._download_loop is None:
            self._download_loop = GLib.timeout_add(400, self._poll_downloads)

    def _poll_downloads(self) -> bool:
        active = 0
        for entry in list(self._downloads):
            if entry.finished or entry.cancelled or entry.failed:
                continue
            active += 1
            download = entry.download
            try:
                progress = download.get_estimated_progress()
                received = download.get_received_data_length()
            except Exception:
                entry.failed = True
                self._mark_failed(entry)
                continue

            if progress is not None and progress >= 1.0:
                self._mark_finished(entry)
                continue

            if progress is not None and progress >= 0:
                entry.progress.show()
                entry.progress.set_fraction(min(progress, 0.999))
                entry.label.set_text(
                    f"{entry.path.name} — {int(progress * 100)}%"
                )

            if received == entry.last_bytes:
                entry.stable_ticks += 1
            else:
                entry.stable_ticks = 0
                entry.last_bytes = received

            # Tamanho desconhecido: considera concluído após 3 s sem crescer.
            if progress is not None and progress < 0 and entry.stable_ticks >= 8:
                self._mark_finished(entry)

        if active == 0:
            self._download_loop = None
            GLib.timeout_add(6000, self._hide_download_bar_if_done)
            return False
        return True

    def _mark_finished(self, entry: DownloadEntry) -> None:
        entry.finished = True
        entry.progress.set_fraction(1.0)
        entry.progress.hide()
        label = entry.label.get_text().split(" — ")[0]
        entry.label.set_text(f"{label} — concluído")
        entry.label.get_style_context().add_class("browser-download-done")
        entry.action.set_image(
            Gtk.Image.new_from_icon_name("folder-open-symbolic", Gtk.IconSize.BUTTON)
        )
        entry.action.set_tooltip_text("Abrir a pasta do download")
        if getattr(entry, "cancel_handler", None):
            try:
                entry.action.disconnect(entry.cancel_handler)
            except Exception:
                pass
            entry.cancel_handler = None
        entry.action.connect("clicked", lambda *_: self._open_folder(entry.path.parent))
        self._notify("Download concluído", entry.path.name)

    def _mark_failed(self, entry: DownloadEntry) -> None:
        entry.failed = True
        entry.progress.hide()
        entry.label.set_text(f"{entry.path.name} — falhou")
        entry.action.set_image(
            Gtk.Image.new_from_icon_name("window-close-symbolic", Gtk.IconSize.BUTTON)
        )

    def _cancel_download(self, entry: DownloadEntry) -> None:
        if entry.finished or entry.cancelled:
            return
        entry.cancelled = True
        try:
            entry.download.cancel()
        except Exception:
            pass
        entry.progress.hide()
        entry.label.set_text(f"{entry.path.name} — cancelado")
        entry.action.set_sensitive(False)

    def _hide_download_bar_if_done(self) -> bool:
        if self._downloads and all(
            entry.finished or entry.cancelled or entry.failed
            for entry in self._downloads
        ):
            self.download_revealer.set_reveal_child(False)
            for entry in self._downloads:
                entry.row.destroy()
            self._downloads.clear()
        return False

    def _show_downloads(self) -> None:
        self.download_revealer.set_reveal_child(True)

    def _open_download_folder(self, *_args) -> None:
        self._open_folder(self._download_folder)

    def _open_folder(self, folder: Path) -> None:
        try:
            Gio.AppInfo.launch_default_for_uri(folder.as_uri(), None)
        except Exception:
            try:
                import subprocess

                subprocess.Popen(["xdg-open", str(folder)])
            except Exception:
                pass

    # ------------------------------------------------------------------
    # Integração com o baixador
    # ------------------------------------------------------------------
    def _download_current_page(self, *_args) -> None:
        view = self.current_view()
        if view is None:
            return
        uri = view.get_uri() or ""
        if uri:
            self._request_download(uri)

    def _request_download(self, url: str) -> None:
        if self._on_download is not None:
            self._on_download(url)
        else:
            self._open_downloader_window(url)

    def _open_downloader_window(self, url: str) -> None:
        from .window import MainWindow

        window = MainWindow(self.get_application(), url)
        window.show_all()
        window.present()

    # ------------------------------------------------------------------
    # Diversos
    # ------------------------------------------------------------------
    def _connect_shortcuts(self) -> None:
        self._accel_group = Gtk.AccelGroup()
        self.add_accel_group(self._accel_group)
        bindings = [
            ("<Primary>l", lambda: self.address_entry.grab_focus()),
            ("<Primary>t", lambda: self.new_tab()),
            ("<Primary>w", lambda: self._close_current_tab()),
            ("<Primary>r", self.reload),
            ("<Primary>j", self._show_downloads),
            ("<Primary>q", lambda: self.get_application().quit()),
            ("<Alt>Left", self.go_back),
            ("<Alt>Right", self.go_forward),
            ("<Primary>plus", self._zoom_in),
            ("<Primary>equal", self._zoom_in),
            ("<Primary>minus", self._zoom_out),
            ("<Primary>0", self._zoom_reset),
        ]
        for shortcut, callback in bindings:
            key, mod = Gtk.accelerator_parse(shortcut)
            self._accel_group.connect(
                key,
                mod,
                Gtk.AccelFlags.VISIBLE,
                lambda *_args: (callback(), True)[1],
            )
        self.connect("key-press-event", self._on_key_press)

    def _on_key_press(self, widget, event) -> bool:
        if event.keyval == Gdk.KEY_F5:
            self.reload()
            return True
        if event.keyval == Gdk.KEY_Escape:
            view = self.current_view()
            if view is not None and view.is_loading():
                view.stop_loading()
                return True
        return False

    def _close_current_tab(self) -> None:
        view = self.current_view()
        if view is not None:
            self.close_tab(view)

    def _zoom(self, delta: float) -> None:
        view = self.current_view()
        if view is not None:
            view.set_zoom_level(max(0.25, min(5.0, view.get_zoom_level() + delta)))

    def _zoom_in(self) -> None:
        self._zoom(0.1)

    def _zoom_out(self) -> None:
        self._zoom(-0.1)

    def _zoom_reset(self) -> None:
        view = self.current_view()
        if view is not None:
            view.set_zoom_level(1.0)

    def _notify(self, title: str, body: str) -> None:
        application = self.get_application()
        if application is None:
            return
        try:
            notification = Gio.Notification.new(title)
            notification.set_body(body)
            application.send_notification(None, notification)
        except Exception:
            pass

    def _show_about(self) -> None:
        dialog = Gtk.AboutDialog(transient_for=self, modal=True)
        dialog.set_program_name(APP_NAME)
        dialog.set_version(APP_VERSION)
        dialog.set_comments(APP_DESCRIPTION)
        dialog.set_logo_icon_name("fastsearchx")
        dialog.set_license_type(Gtk.License.MIT_X11)
        dialog.set_website("https://github.com/SysArchX/FastSearchX")
        dialog.set_website_label("github.com/SysArchX/FastSearchX")
        dialog.run()
        dialog.destroy()

    def _on_destroy(self, *_args) -> None:
        if self._download_loop is not None:
            GLib.source_remove(self._download_loop)
            self._download_loop = None
        for entry in self._downloads:
            if not entry.finished:
                try:
                    entry.download.cancel()
                except Exception:
                    pass
        if self._context_handler is not None:
            try:
                self._context.disconnect(self._context_handler)
            except Exception:
                pass
            self._context_handler = None
