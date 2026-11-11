// TubeFetch Browser — Android (Flutter / Dart)
//
// Navegador no estilo Chrome com Material 3:
//  1. Barra superior clássica (voltar, avançar, endereço, recarregar e menu ⋮).
//  2. Menu ⋮ com Histórico, Downloads, Configurações, Página inicial e Sobre.
//  3. Detecção automática de vídeos do YouTube e de mídia em qualquer site.
//  4. Download em MP3 (convertido) e MP4 com resolução de 360p a 4K.
//  5. Tela de Downloads com progresso em tempo real (estilo Snaptube).
//  6. Detecção de link copiado na área de transferência.
//  7. Temas claro/escuro/sistema e várias cores de destaque.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const String kHomeUrl = 'https://www.google.com';
const String kGitHubUrl = 'https://github.com/SysArchX/tubefetch';
const String kAppVersion = '1.4.1';

/// Canal nativo para receber links (navegador padrão) e abrir ajustes.
const MethodChannel kIntentChannel = MethodChannel('tubefetch/intent');
const String _kUserAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

/// Caminhos locais de download (Android).
///
/// Arquivos comuns ficam em `Download/TubeFetch`; vídeos e músicas ficam em
/// subpastas próprias.
abstract final class AppPaths {
  /// Raiz onde os downloads são salvos.
  ///
  /// - Android: `Download/TubeFetch` na memória compartilhada.
  /// - iOS: `Documents/TubeFetch` dentro do sandbox do app, que aparece no app
  ///   **Arquivos** em "No meu iPhone → TubeFetch" (precisa de
  ///   `UIFileSharingEnabled` no Info.plist).
  static String get _root {
    if (Platform.isAndroid) return '/storage/emulated/0/Download';
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) return '$home/Documents';
    return '${Directory.systemTemp.parent.path}/Documents';
  }

  static String get base => '$_root/TubeFetch';
  static String get videos => '$base/TubeFetch_videos';
  static String get music => '$base/TubeFetch_music';

  static Future<void> ensureFolders() async {
    for (final path in [base, videos, music]) {
      try {
        final dir = Directory(path);
        if (!await dir.exists()) await dir.create(recursive: true);
      } catch (_) {
        // Sem permissão ainda: será criado de novo antes do download.
      }
    }
  }

  /// Pasta adequada para o arquivo, conforme o tipo.
  static String folderFor({required bool isVideo, required bool isAudio}) {
    if (isVideo) return videos;
    if (isAudio) return music;
    return base;
  }

  static String folderForMime(String? mime) {
    final isVideo = isVideoMime(mime);
    final isAudio = isAudioMime(mime);
    return folderFor(isVideo: isVideo, isAudio: isAudio);
  }

  static String folderForName(String name) {
    final ext = fileExtension(name);
    const videoExts = {
      'mp4',
      'm4v',
      'webm',
      'mkv',
      'mov',
      'avi',
      '3gp',
      'mpeg',
      'mpg',
      'ts',
      'm3u8',
      'mpd',
    };
    const audioExts = {'mp3', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'flac'};
    if (videoExts.contains(ext)) return videos;
    if (audioExts.contains(ext)) return music;
    return base;
  }
}

// ---------------------------------------------------------------------------
// Armazenamento interno (configurações e histórico)
// ---------------------------------------------------------------------------

abstract final class AppStorage {
  static Directory? _dir;

  static Directory get dir {
    final cached = _dir;
    if (cached != null) return cached;
    Directory base;
    try {
      // No Android, systemTemp fica em .../<pacote>/cache.
      base = Directory('${Directory.systemTemp.parent.path}/files');
    } catch (_) {
      base = Directory.systemTemp;
    }
    try {
      if (!base.existsSync()) base.createSync(recursive: true);
    } catch (_) {
      base = Directory.systemTemp;
    }
    _dir = base;
    return base;
  }

  static File file(String name) => File('${dir.path}/$name');
}

class SettingsStore {
  static ThemeMode mode = ThemeMode.dark;
  static Color seed = const Color(0xFFE53935);
  static String lastClipboard = '';

  static Future<void> load() async {
    try {
      final f = AppStorage.file('settings.json');
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString());
      if (data is! Map) return;
      mode = switch (data['mode']) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };
      final value = data['seed'];
      if (value is int) seed = Color(value);
      lastClipboard = (data['lastClipboard'] ?? '').toString();
    } catch (_) {
      // Mantém os padrões.
    }
  }

  static Future<void> save() async {
    try {
      await AppStorage.file('settings.json').writeAsString(
        jsonEncode({
          'mode': mode.name,
          'seed': seed.toARGB32(),
          'lastClipboard': lastClipboard,
        }),
      );
    } catch (_) {
      // Ignora falhas de escrita.
    }
  }
}

class HistoryEntry {
  final String url;
  final String title;
  final DateTime time;

  const HistoryEntry({
    required this.url,
    required this.title,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
    'url': url,
    'title': title,
    'time': time.millisecondsSinceEpoch,
  };

  static HistoryEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final url = value['url'];
    if (url is! String) return null;
    final title = value['title'];
    final time = value['time'];
    return HistoryEntry(
      url: url,
      title: title is String ? title : url,
      time: DateTime.fromMillisecondsSinceEpoch(
        time is int ? time : DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}

class HistoryStore {
  HistoryStore._();
  static final HistoryStore instance = HistoryStore._();

  final List<HistoryEntry> entries = [];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = AppStorage.file('history.json');
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString());
      if (data is! List) return;
      entries
        ..clear()
        ..addAll(data.map(HistoryEntry.fromJson).whereType<HistoryEntry>());
    } catch (_) {
      // Histórico começa vazio.
    }
  }

  void record(String url, String title) {
    if (!url.startsWith('http')) return;
    entries.removeWhere((e) => e.url == url);
    entries.insert(
      0,
      HistoryEntry(
        url: url,
        title: title.isEmpty ? url : title,
        time: DateTime.now(),
      ),
    );
    if (entries.length > 300) entries.removeRange(300, entries.length);
    _save();
  }

  void remove(String url) {
    entries.removeWhere((e) => e.url == url);
    _save();
  }

  Future<void> clear() async {
    entries.clear();
    await _save();
  }

  Future<void> _save() async {
    try {
      await AppStorage.file('history.json')
          .writeAsString(jsonEncode(entries.map((e) => e.toJson()).toList()));
    } catch (_) {
      // Ignora falhas de escrita.
    }
  }
}

// ---------------------------------------------------------------------------
// Utilidades compartilhadas
// ---------------------------------------------------------------------------

String? canonicalYouTubeUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  String? id;
  if (host == 'youtu.be') {
    if (uri.pathSegments.isNotEmpty) id = uri.pathSegments.first;
  } else if (host == 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host.endsWith('youtube-nocookie.com')) {
    if (uri.path == '/watch') {
      id = uri.queryParameters['v'];
    } else if (uri.pathSegments.length >= 2) {
      final first = uri.pathSegments.first;
      if (first == 'shorts' || first == 'live' || first == 'embed') {
        id = uri.pathSegments[1];
      }
    }
  }
  if (id == null || id.isEmpty) return null;
  return 'https://www.youtube.com/watch?v=$id';
}

/// Extensões que tratamos como arquivo para download (e não como página).
const Set<String> _kDownloadExtensions = {
  '7z',
  'aac',
  'apk',
  'avi',
  'bin',
  'bz2',
  'csv',
  'deb',
  'dmg',
  'doc',
  'docx',
  'epub',
  'exe',
  'flac',
  'gif',
  'gz',
  'heic',
  'img',
  'iso',
  'jar',
  'jpeg',
  'jpg',
  'm4a',
  'm4v',
  'mkv',
  'mov',
  'mp3',
  'mp4',
  'mpeg',
  'mpg',
  'msix',
  'odp',
  'ods',
  'odt',
  'ogg',
  'opus',
  'otf',
  'pdf',
  'png',
  'ppt',
  'pptx',
  'rar',
  'raw',
  'rpm',
  'srt',
  'tar',
  'tgz',
  'torrent',
  'ttf',
  'txt',
  'vtt',
  'wav',
  'webm',
  'webp',
  'wim',
  'xls',
  'xlsx',
  'xz',
  'zip',
  'zipx',
  '3gp',
};

const Map<String, String> _kMimeExtensions = {
  'application/pdf': 'pdf',
  'application/zip': 'zip',
  'application/x-7z-compressed': '7z',
  'application/x-rar-compressed': 'rar',
  'application/gzip': 'gz',
  'application/x-tar': 'tar',
  'application/vnd.android.package-archive': 'apk',
  'application/octet-stream': 'bin',
  'text/plain': 'txt',
  'text/csv': 'csv',
  'application/json': 'json',
  'application/xml': 'xml',
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'audio/aac': 'aac',
  'audio/ogg': 'ogg',
  'audio/wav': 'wav',
  'audio/x-wav': 'wav',
  'audio/opus': 'opus',
  'audio/flac': 'flac',
  'video/mp4': 'mp4',
  'video/webm': 'webm',
  'video/x-matroska': 'mkv',
  'video/quicktime': 'mov',
  'video/mpeg': 'mpeg',
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
      'docx',
  'application/vnd.ms-excel': 'xls',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  'application/vnd.ms-powerpoint': 'ppt',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation':
      'pptx',
  'application/epub+zip': 'epub',
};

const Set<String> _kVideoExtensions = {
  'mp4',
  'm4v',
  'webm',
  'mkv',
  'mov',
  'avi',
  '3gp',
  'mpeg',
  'mpg',
  'ts',
};

const Set<String> _kAudioExtensions = {
  'mp3',
  'm4a',
  'aac',
  'wav',
  'ogg',
  'opus',
  'flac',
};

bool looksLikeMedia(String url) {
  final ext = fileExtension(Uri.tryParse(url)?.path ?? url);
  return _kVideoExtensions.contains(ext) || _kAudioExtensions.contains(ext);
}

bool isAudioUrl(String url) {
  final ext = fileExtension(Uri.tryParse(url)?.path ?? url);
  return _kAudioExtensions.contains(ext);
}

bool isVideoUrl(String url) {
  final ext = fileExtension(Uri.tryParse(url)?.path ?? url);
  return _kVideoExtensions.contains(ext);
}

bool isHlsUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  return path.endsWith('.m3u8');
}

bool isDashUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  return path.endsWith('.mpd');
}

bool isStreamingMediaUrl(String url) => isHlsUrl(url) || isDashUrl(url);

bool isHlsMime(String? mime) {
  final type = (mime ?? '').split(';').first.trim().toLowerCase();
  return type == 'application/vnd.apple.mpegurl' ||
      type == 'application/x-mpegurl' ||
      type == 'audio/mpegurl' ||
      type == 'audio/x-mpegurl';
}

bool isDashMime(String? mime) {
  final type = (mime ?? '').split(';').first.trim().toLowerCase();
  return type == 'application/dash+xml';
}

bool isStreamingMediaMime(String? mime) => isHlsMime(mime) || isDashMime(mime);

/// Vídeo, áudio, HLS ou DASH — deve ir para as subpastas de mídia.
bool isMediaUrl(String url) => looksLikeMedia(url) || isStreamingMediaUrl(url);

/// Recursos que vale a pena continuar observando no `shouldInterceptRequest`.
bool isSniffableMediaUrl(String url) {
  if (!url.startsWith('http')) return false;
  if (isHlsUrl(url) || isDashUrl(url)) return true;
  if (isVideoUrl(url)) return fileExtension(url) != 'ts';
  return isAudioUrl(url);
}

bool isAudioMime(String? mime) {
  final type = (mime ?? '').split(';').first.trim().toLowerCase();
  return type.startsWith('audio/');
}

bool isVideoMime(String? mime) {
  final type = (mime ?? '').split(';').first.trim().toLowerCase();
  return type.startsWith('video/');
}

String fileExtension(String name) {
  final clean = name.split('?').first.split('#').first;
  final dot = clean.lastIndexOf('.');
  if (dot < 0 || dot == clean.length - 1) return '';
  return clean.substring(dot + 1).toLowerCase();
}

bool hasFileExtension(String name) {
  final ext = fileExtension(name);
  return ext.isNotEmpty && ext.length <= 10;
}

IconData iconForFile(String name) {
  final ext = fileExtension(name);
  if (const {'mp3', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'flac'}.contains(ext)) {
    return Icons.music_note;
  }
  if (const {
    'mp4',
    'm4v',
    'webm',
    'mkv',
    'mov',
    'avi',
    '3gp',
    'mpeg',
    'mpg',
  }.contains(ext)) {
    return Icons.movie_outlined;
  }
  if (const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'}.contains(ext)) {
    return Icons.image_outlined;
  }
  if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
  if (const {
    'zip',
    'rar',
    '7z',
    'tar',
    'gz',
    'bz2',
    'xz',
    'tgz',
  }.contains(ext)) {
    return Icons.folder_zip_outlined;
  }
  if (ext == 'apk') return Icons.android;
  if (const {
    'doc',
    'docx',
    'odt',
    'txt',
    'rtf',
    'csv',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'ods',
    'odp',
    'json',
    'xml',
  }.contains(ext)) {
    return Icons.description_outlined;
  }
  if (const {
    'exe',
    'msix',
    'deb',
    'rpm',
    'dmg',
    'iso',
    'bin',
    'img',
  }.contains(ext)) {
    return Icons.install_desktop_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

bool looksLikeDownloadUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final path = uri.path.toLowerCase();
  if (path.isEmpty || path.endsWith('/')) return false;
  return _kDownloadExtensions.contains(fileExtension(path));
}

String? extensionForMime(String? mime) {
  if (mime == null) return null;
  final type = mime.split(';').first.trim().toLowerCase();
  return _kMimeExtensions[type];
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Extrai o nome do arquivo do cabeçalho `Content-Disposition`.
String? fileNameFromDisposition(String? header) {
  if (header == null || header.isEmpty) return null;

  final extended = RegExp(
    r"filename\*\s*=\s*([^']*)''([^;]+)",
    caseSensitive: false,
  ).firstMatch(header);
  if (extended != null) {
    try {
      return Uri.decodeComponent(extended.group(2)!.trim().replaceAll('"', ''));
    } catch (_) {
      // Usa o formato simples abaixo.
    }
  }

  final quoted = RegExp(
    r'filename\s*=\s*"([^"]+)"',
    caseSensitive: false,
  ).firstMatch(header);
  if (quoted != null) return quoted.group(1)!.trim();

  final plain = RegExp(
    r'filename\s*=\s*([^;]+)',
    caseSensitive: false,
  ).firstMatch(header);
  if (plain != null) return plain.group(1)!.trim().replaceAll('"', '');
  return null;
}

String? fileNameFromUrl(String url) {
  try {
    final uri = Uri.parse(url);
    for (final key in const ['filename', 'file', 'name', 'download']) {
      final value = uri.queryParameters[key];
      if (value != null && value.trim().isNotEmpty) {
        return Uri.decodeComponent(value.trim());
      }
    }
    if (uri.pathSegments.isEmpty) return null;
    final last = Uri.decodeComponent(uri.pathSegments.last).trim();
    if (last.isEmpty) return null;
    return last;
  } catch (_) {
    return null;
  }
}

String sanitizeFileName(String raw) {
  var name = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.isEmpty || name == '.' || name == '..') name = 'arquivo';
  if (name.length > 120) {
    if (hasFileExtension(name)) {
      final ext = fileExtension(name);
      name = '${name.substring(0, 110 - ext.length)}.$ext';
    } else {
      name = name.substring(0, 120);
    }
  }
  return name;
}

/// Gera um caminho livre, sem sobrescrever arquivos existentes.
String uniquePath(String directory, String fileName) {
  final safe = sanitizeFileName(fileName);
  var candidate = File('$directory/$safe');
  if (!candidate.existsSync()) return candidate.path;

  final ext = fileExtension(safe);
  final stem = ext.isEmpty
      ? safe
      : safe.substring(0, safe.length - ext.length - 1);
  var counter = 1;
  do {
    candidate = File(
      '$directory/${stem}_$counter${ext.isEmpty ? '' : '.$ext'}',
    );
    counter++;
  } while (candidate.existsSync());
  return candidate.path;
}

bool isPrivateHost(String host) {
  final value = host.trim().toLowerCase();
  if (value.isEmpty) return false;
  if (value == 'localhost' ||
      value.endsWith('.local') ||
      value.endsWith('.lan') ||
      value.endsWith('.home')) {
    return true;
  }
  final address = InternetAddress.tryParse(value);
  if (address == null) return false;
  if (address.isLoopback) return true;
  if (address.type == InternetAddressType.IPv6) return false;
  final bytes = address.rawAddress;
  if (bytes.length < 4) return false;
  return bytes[0] == 10 ||
      (bytes[0] == 192 && bytes[1] == 168) ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 169 && bytes[1] == 254);
}

String safeFileName(String title) {
  var name = title
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.isEmpty) name = 'TubeFetch';
  if (name.length > 80) name = name.substring(0, 80);
  return name;
}

String extensionOf(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  final dot = path.lastIndexOf('.');
  if (dot >= 0 && path.length - dot <= 6) return path.substring(dot + 1);
  return 'bin';
}

String shortNameOf(String url) {
  final uri = Uri.tryParse(url);
  final name = uri?.pathSegments.isNotEmpty == true
      ? uri!.pathSegments.last
      : url;
  return name.isEmpty ? url : name;
}

String shellQuote(String path) => "'${path.replaceAll("'", "'\\''")}'";

Future<bool> ensureStoragePermission() async {
  if (!Platform.isAndroid) return true;
  var manage = await Permission.manageExternalStorage.status;
  if (!manage.isGranted) {
    manage = await Permission.manageExternalStorage.request();
  }
  if (manage.isGranted) return true;
  final storage = await Permission.storage.request();
  return storage.isGranted;
}

Future<bool> runFfmpeg(String command) async {
  try {
    final session = await FFmpegKit.execute(command);
    final code = await session.getReturnCode();
    return ReturnCode.isSuccess(code);
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Gerenciador de downloads (fila + progresso em tempo real)
// ---------------------------------------------------------------------------

enum DownloadPhase {
  analyzing,
  downloading,
  processing,
  completed,
  failed,
  canceled,
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.sourceUrl,
    required this.isAudio,
    this.requestedHeight,
    required this.title,
    this.isDirect = false,
    this.isMedia = false,
    this.isStream = false,
    this.fileName,
    this.mimeType,
    this.referer,
    this.userAgent,
    this.extraHeaders,
  });

  final String id;
  final String sourceUrl;
  final bool isAudio;
  final int? requestedHeight;
  final bool isDirect;
  final bool isMedia;
  final bool isStream;
  String? fileName;
  final String? mimeType;
  final String? referer;
  final String? userAgent;
  final Map<String, String>? extraHeaders;

  String title;
  DownloadPhase phase = DownloadPhase.analyzing;
  double? progress;
  String message = 'Na fila...';
  String? outputPath;
  String? error;
  bool cancelRequested = false;
  CancelToken? cancelToken;
  int receivedBytes = 0;
  int? totalBytes;
  final DateTime createdAt = DateTime.now();

  bool get isActive =>
      phase == DownloadPhase.analyzing ||
      phase == DownloadPhase.downloading ||
      phase == DownloadPhase.processing;

  bool get isFinished => !isActive;

  bool get isGeneric => isDirect && !isAudio;

  bool get isVideo => isMedia && !isAudio;

  String get extension => fileExtension(fileName ?? outputPath ?? sourceUrl);
}

class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  final List<DownloadTask> tasks = [];
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get hasActive => tasks.any((t) => t.isActive);

  DownloadTask enqueue({
    required String url,
    required bool isAudio,
    int? height,
    String? title,
  }) {
    final task = DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      sourceUrl: url,
      isAudio: isAudio,
      requestedHeight: height,
      title: title ?? (isAudio ? 'Áudio' : 'Vídeo'),
    );
    tasks.insert(0, task);
    _notify(force: true);
    _run(task);
    return task;
  }

  /// Enfileira o download de vídeo/áudio de qualquer site.
  ///
  /// Links diretos (MP4/MP3) são baixados com progresso; HLS (`.m3u8`) e
  /// DASH (`.mpd`) são processados pelo FFmpeg e salvos nas subpastas.
  DownloadTask enqueueMedia({
    required String url,
    String? fileName,
    String? mimeType,
    String? referer,
    String? userAgent,
    Map<String, String>? headers,
    bool? isAudio,
    bool? isStream,
    String? title,
  }) {
    final audio =
        isAudio ?? isAudioMime(mimeType) || isAudioUrl(fileName ?? url);
    final streaming =
        isStream ??
        (isStreamingMediaUrl(url) || isStreamingMediaMime(mimeType));
    final suggested = (fileName != null && fileName.trim().isNotEmpty)
        ? fileName.trim()
        : (fileNameFromUrl(url) ?? 'midia');
    final task = DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      sourceUrl: url,
      isAudio: audio,
      title: (title != null && title.trim().isNotEmpty)
          ? title.trim()
          : suggested,
      isMedia: true,
      isStream: streaming,
      fileName: sanitizeFileName(suggested),
      mimeType: mimeType,
      referer: referer,
      userAgent: userAgent,
      extraHeaders: headers,
    );
    tasks.insert(0, task);
    _notify(force: true);
    _run(task);
    return task;
  }

  /// Enfileira o download de qualquer arquivo (link direto, LocalSend, etc.).
  DownloadTask enqueueFile({
    required String url,
    String? fileName,
    String? contentDisposition,
    String? mimeType,
    String? referer,
    String? userAgent,
    int? contentLength,
    Map<String, String>? headers,
    bool? isAudio,
  }) {
    final suggested =
        fileNameFromDisposition(contentDisposition) ??
        (fileName != null && fileName.trim().isNotEmpty
            ? fileName.trim()
            : fileNameFromUrl(url)) ??
        'arquivo';
    final audio = isAudio ?? (isAudioMime(mimeType) || isAudioUrl(suggested));
    final task = DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      sourceUrl: url,
      isAudio: audio,
      title: suggested,
      isDirect: true,
      fileName: sanitizeFileName(suggested),
      mimeType: mimeType,
      referer: referer,
      userAgent: userAgent,
      extraHeaders: headers,
    );
    task.totalBytes = contentLength != null && contentLength > 0
        ? contentLength
        : null;
    tasks.insert(0, task);
    _notify(force: true);
    _run(task);
    return task;
  }

  DownloadTask? activeForUrl(String url) {
    for (final task in tasks) {
      if (task.sourceUrl == url && task.isActive) return task;
    }
    return null;
  }

  // --- Downloads de blob (gerados por JavaScript) ------------------------

  final Map<String, _BlobDownload> _blobs = {};

  DownloadTask? startBlob({
    required String blobId,
    required String fileName,
    required String mimeType,
    required int size,
    String? referer,
  }) {
    final safe = sanitizeFileName(
      fileName.trim().isEmpty
          ? 'arquivo_${DateTime.now().millisecondsSinceEpoch}'
          : fileName,
    );
    final audio = isAudioMime(mimeType) || isAudioUrl(safe);
    final video = isVideoMime(mimeType) || isVideoUrl(safe);
    final out = uniquePath(
      AppPaths.folderFor(isVideo: video && !audio, isAudio: audio),
      safe,
    );
    final task = DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      sourceUrl: 'blob:$blobId',
      isAudio: audio,
      title: safe,
      isDirect: true,
      isMedia: video || audio,
      fileName: safe,
      mimeType: mimeType,
      referer: referer,
    );
    task.totalBytes = size > 0 ? size : null;
    task.outputPath = out;
    task.phase = DownloadPhase.downloading;
    task.message = size > 0 ? 'Baixando 0%' : 'Baixando...';
    tasks.insert(0, task);
    try {
      final file = File(out);
      _blobs[blobId] = _BlobDownload(
        task: task,
        file: file,
        sink: file.openWrite(),
      );
    } catch (_) {
      task.phase = DownloadPhase.failed;
      task.message = 'Falhou';
      task.error = 'não foi possível criar o arquivo';
    }
    _notify(force: true);
    return task;
  }

  void appendBlobChunk(String blobId, String base64Data) {
    final blob = _blobs[blobId];
    if (blob == null) return;
    if (blob.task.cancelRequested) {
      unawaited(abortBlob(blobId));
      return;
    }
    try {
      final bytes = base64Decode(base64Data);
      blob.sink.add(bytes);
      blob.received += bytes.length;
      blob.task.receivedBytes = blob.received;
      final total = blob.task.totalBytes;
      if (total != null && total > 0) {
        blob.task.progress = (blob.received / total).clamp(0.0, 1.0).toDouble();
        blob.task.message =
            'Baixando ${(blob.task.progress! * 100).toStringAsFixed(0)}% • '
            '${formatBytes(blob.received)} de ${formatBytes(total)}';
      } else {
        blob.task.progress = null;
        blob.task.message = 'Baixando... ${formatBytes(blob.received)}';
      }
      _notify();
    } catch (_) {
      unawaited(abortBlob(blobId));
    }
  }

  Future<void> finishBlob(String blobId) async {
    final blob = _blobs.remove(blobId);
    if (blob == null) return;
    try {
      await blob.sink.flush();
      await blob.sink.close();
      if (blob.task.cancelRequested) throw const _Canceled();
      blob.task.progress = 1;
      blob.task.phase = DownloadPhase.completed;
      blob.task.message = 'Concluído • ${formatBytes(blob.received)}';
    } catch (_) {
      if (blob.task.cancelRequested) {
        blob.task.phase = DownloadPhase.canceled;
        blob.task.message = 'Cancelado';
      } else {
        blob.task.phase = DownloadPhase.failed;
        blob.task.message = 'Falhou';
        blob.task.error = 'falha ao salvar o arquivo';
      }
      try {
        if (await blob.file.exists()) await blob.file.delete();
      } catch (_) {}
    }
    _notify(force: true);
  }

  Future<void> abortBlob(String blobId) async {
    final blob = _blobs.remove(blobId);
    if (blob == null) return;
    try {
      await blob.sink.close();
    } catch (_) {}
    try {
      if (await blob.file.exists()) await blob.file.delete();
    } catch (_) {}
    blob.task.phase = DownloadPhase.canceled;
    blob.task.message = 'Cancelado';
    _notify(force: true);
  }

  void cancel(String id) {
    for (final task in tasks) {
      if (task.id == id && task.isActive) {
        task.cancelRequested = true;
        task.cancelToken?.cancel('cancelado');
        task.message = 'Cancelando...';
        _notify(force: true);
      }
    }
    for (final entry in _blobs.entries.toList()) {
      if (entry.value.task.id == id) {
        unawaited(abortBlob(entry.key));
      }
    }
    FFmpegKit.cancel();
  }

  void remove(String id) {
    tasks.removeWhere((t) => t.id == id && !t.isActive);
    _notify(force: true);
  }

  void clearFinished() {
    tasks.removeWhere((t) => t.isFinished);
    _notify(force: true);
  }

  void _notify({bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastNotify).inMilliseconds >= 150) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  Future<void> _run(DownloadTask task) async {
    final temps = <String>[];
    YoutubeExplode? yt;
    try {
      if (!await ensureStoragePermission()) {
        throw Exception('permissão de armazenamento negada');
      }
      await AppPaths.ensureFolders();

      final canonical = canonicalYouTubeUrl(task.sourceUrl);
      if (task.isMedia) {
        await _runMedia(task);
      } else if (task.isDirect || canonical == null) {
        await _runFile(task);
      } else {
        yt = YoutubeExplode();
        task.message = 'Analisando vídeo...';
        _notify(force: true);

        final video = await yt.videos.get(canonical);
        task.title = video.title;
        _notify(force: true);

        final manifest = await yt.videos.streamsClient.getManifest(video.id);
        if (task.cancelRequested) throw const _Canceled();

        final stamp = DateTime.now().millisecondsSinceEpoch;
        final base = safeFileName(task.title);

        if (task.isAudio) {
          final audio = _bestAudio(manifest);
          if (audio == null) throw Exception('áudio indisponível');
          final out = '${AppPaths.music}/${base}_$stamp.mp3';
          final temp = '${AppPaths.base}/.tmp_$stamp.${audio.container.name}';
          temps.add(temp);

          task.phase = DownloadPhase.downloading;
          task.message = 'Baixando áudio...';
          _notify(force: true);
          await _downloadYouTube(task, yt, audio, temp, 'áudio');

          task.phase = DownloadPhase.processing;
          task.progress = null;
          task.message = 'Convertendo para MP3...';
          _notify(force: true);
          final ok = await runFfmpeg(
            '-y -i ${shellQuote(temp)} -vn -c:a libmp3lame -b:a 192k '
            '${shellQuote(out)}',
          );
          if (task.cancelRequested) throw const _Canceled();
          if (!ok) throw Exception('falha ao converter para MP3');
          task.outputPath = out;
        } else {
          final selection = _selectVideo(manifest, task.requestedHeight);
          if (selection == null) {
            throw Exception('nenhuma resolução disponível');
          }
          final height = selection.height;

          if (selection.needsMux) {
            final out = '${AppPaths.videos}/${base}_${height}p_$stamp.mp4';
            final tempVideo =
                '${AppPaths.base}/.tmp_v_$stamp.'
                '${selection.video.container.name}';
            final tempAudio =
                '${AppPaths.base}/.tmp_a_$stamp.'
                '${selection.audio!.container.name}';
            temps
              ..add(tempVideo)
              ..add(tempAudio);

            task.phase = DownloadPhase.downloading;
            task.message = 'Baixando vídeo ${height}p...';
            _notify(force: true);
            await _downloadYouTube(
              task,
              yt,
              selection.video,
              tempVideo,
              'vídeo ${height}p',
            );
            await _downloadYouTube(
              task,
              yt,
              selection.audio!,
              tempAudio,
              'áudio',
            );

            task.phase = DownloadPhase.processing;
            task.progress = null;
            task.message = 'Juntando áudio e vídeo...';
            _notify(force: true);
            var ok = await runFfmpeg(
              '-y -i ${shellQuote(tempVideo)} -i ${shellQuote(tempAudio)} '
              '-c copy -movflags +faststart ${shellQuote(out)}',
            );
            if (task.cancelRequested) throw const _Canceled();
            if (!ok) {
              final outMkv = '${AppPaths.videos}/${base}_${height}p_$stamp.mkv';
              ok = await runFfmpeg(
                '-y -i ${shellQuote(tempVideo)} -i ${shellQuote(tempAudio)} '
                '-c copy ${shellQuote(outMkv)}',
              );
              if (task.cancelRequested) throw const _Canceled();
              if (ok) {
                task.outputPath = outMkv;
              } else {
                final fallback =
                    '${AppPaths.videos}/${base}_${height}p_'
                    '$stamp.${selection.video.container.name}';
                await File(tempVideo).rename(fallback);
                task.outputPath = fallback;
                task.message = 'Salvo sem áudio';
              }
            } else {
              task.outputPath = out;
            }
          } else {
            final ext = selection.video.container.name;
            final out = '${AppPaths.videos}/${base}_${height}p_$stamp.$ext';
            task.phase = DownloadPhase.downloading;
            task.message = 'Baixando vídeo ${height}p...';
            _notify(force: true);
            await _downloadYouTube(
              task,
              yt,
              selection.video,
              out,
              'vídeo ${height}p',
            );
            task.outputPath = out;
          }
        }
      }

      if (task.cancelRequested) throw const _Canceled();
      task.phase = DownloadPhase.completed;
      task.progress = 1;
      if (!task.message.startsWith('Concluído')) task.message = 'Concluído';
      _notify(force: true);
    } on _Canceled {
      task.phase = DownloadPhase.canceled;
      task.message = 'Cancelado';
      _notify(force: true);
    } catch (e) {
      if (task.cancelRequested) {
        task.phase = DownloadPhase.canceled;
        task.message = 'Cancelado';
      } else {
        task.phase = DownloadPhase.failed;
        task.error = e.toString();
        task.message = 'Falhou';
      }
      _notify(force: true);
    } finally {
      yt?.close();
      for (final path in temps) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _runFile(DownloadTask task) async {
    final url = task.sourceUrl;

    if (url.startsWith('data:')) {
      await _saveDataUri(task, url);
      return;
    }
    if (url.startsWith('blob:')) {
      throw Exception('download de blob não suportado por este caminho');
    }
    if (url.startsWith('content:') || url.startsWith('file:')) {
      throw Exception('endereço não suportado');
    }

    task.phase = DownloadPhase.analyzing;
    task.progress = null;
    task.message = 'Conectando...';
    _notify(force: true);

    final headers = <String, String>{
      'User-Agent': task.userAgent?.isNotEmpty == true
          ? task.userAgent!
          : _kUserAgent,
      'Accept': '*/*',
      if (task.referer != null && task.referer!.isNotEmpty)
        'Referer': task.referer!,
      ...?task.extraHeaders,
    };
    final cookies = await _cookiesFor(url);
    if (cookies.isNotEmpty) headers['Cookie'] = cookies;

    final dio = _buildDio();
    task.cancelToken = CancelToken();

    final response = await dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        headers: headers,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
      ),
      cancelToken: task.cancelToken,
    );

    final body = response.data;
    if (body == null) throw Exception('resposta vazia do servidor');

    final responseHeaders = response.headers;
    final finalUrl = response.realUri.toString();
    final declaredTotal = int.tryParse(
      responseHeaders.value('content-length') ?? '',
    );
    final candidate = (declaredTotal != null && declaredTotal > 0)
        ? declaredTotal
        : task.totalBytes;
    final total = (candidate != null && candidate > 0) ? candidate : null;

    final fileName = _pickFileName(
      suggested: task.fileName,
      contentDisposition: responseHeaders.value('content-disposition'),
      url: finalUrl,
      mimeType: responseHeaders.value('content-type') ?? task.mimeType,
    );
    task.fileName = fileName;
    task.title = fileName;
    task.totalBytes = total;

    final detectedMime = responseHeaders.value('content-type') ?? task.mimeType;
    final folder = AppPaths.folderFor(
      isVideo: isVideoMime(detectedMime) || isVideoUrl(fileName),
      isAudio: isAudioMime(detectedMime) || isAudioUrl(fileName),
    );
    final out = uniquePath(folder, fileName);
    task.outputPath = out;
    final file = File(out);
    final sink = file.openWrite();
    var received = 0;

    task.phase = DownloadPhase.downloading;
    task.message = total != null ? 'Baixando 0%' : 'Baixando...';
    _notify(force: true);

    try {
      await for (final chunk in body.stream) {
        if (task.cancelRequested) throw const _Canceled();
        sink.add(chunk);
        received += chunk.length;
        task.receivedBytes = received;
        if (total != null) {
          task.progress = (received / total).clamp(0.0, 1.0).toDouble();
          task.message =
              'Baixando ${(task.progress! * 100).toStringAsFixed(0)}% • '
              '${formatBytes(received)} de ${formatBytes(total)}';
        } else {
          task.progress = null;
          task.message = 'Baixando... ${formatBytes(received)}';
        }
        _notify();
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      try {
        await sink.flush();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    }

    task.progress = 1;
    task.message = 'Concluído • ${formatBytes(received)}';
    _notify(force: true);
  }

  /// Download de vídeo/áudio de qualquer site.
  ///
  /// Links diretos são baixados com progresso real. Playlists HLS/DASH são
  /// processadas pelo FFmpeg (com progresso quando a duração é conhecida).
  Future<void> _runMedia(DownloadTask task) async {
    final url = task.sourceUrl;

    if (url.startsWith('data:')) {
      await _saveDataUri(task, url);
      return;
    }
    if (url.startsWith('blob:')) {
      throw Exception('download de blob não suportado por este caminho');
    }
    if (url.startsWith('content:') || url.startsWith('file:')) {
      throw Exception('endereço não suportado');
    }

    task.phase = DownloadPhase.analyzing;
    task.progress = null;
    task.message = (task.isStream || isStreamingMediaUrl(url))
        ? 'Analisando transmissão...'
        : 'Conectando...';
    _notify(force: true);

    final headers = <String, String>{
      'User-Agent': task.userAgent?.isNotEmpty == true
          ? task.userAgent!
          : _kUserAgent,
      'Accept': '*/*',
      if (task.referer != null && task.referer!.isNotEmpty)
        'Referer': task.referer!,
      ...?task.extraHeaders,
    };
    final cookies = await _cookiesFor(url);
    if (cookies.isNotEmpty) headers['Cookie'] = cookies;

    if (task.isStream || isStreamingMediaUrl(url)) {
      await _runMediaStream(task, headers);
    } else {
      await _runMediaDirect(task, headers);
    }
  }

  Future<void> _runMediaDirect(
    DownloadTask task,
    Map<String, String> headers,
  ) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final folder = AppPaths.folderFor(
      isVideo: !task.isAudio,
      isAudio: task.isAudio,
    );
    try {
      Directory(folder).createSync(recursive: true);
    } catch (_) {}
    final temp = '$folder/.tf_tmp_$stamp.part';

    try {
      final info = await _streamToTemp(task, task.sourceUrl, headers, temp);
      final mime = info.contentType ?? task.mimeType;
      var name = _pickFileName(
        suggested: task.fileName,
        contentDisposition: info.contentDisposition,
        url: info.realUrl,
        mimeType: mime,
      );
      if (!hasFileExtension(name)) {
        final ext = extensionForMime(mime);
        if (ext != null && ext != 'bin') name = '$name.$ext';
      }

      final audioFile = task.isAudio || isAudioMime(mime) || isAudioUrl(name);
      final videoFile = isVideoMime(mime) || isVideoUrl(name);

      if (task.isAudio && !isAudioMime(mime) && !isAudioUrl(name)) {
        // Vídeo escolhido como áudio: extrai a faixa para MP3.
        final stem = _withoutExtension(name);
        final out = uniquePath(
          AppPaths.music,
          '${stem.isEmpty ? 'audio_$stamp' : stem}.mp3',
        );
        final duration = await _probeDuration(temp, headers: const {});
        task.phase = DownloadPhase.processing;
        task.progress = null;
        task.message = 'Convertendo para MP3...';
        _notify(force: true);
        final ok = await _runFfmpegTask(task, [
          '-y',
          '-i',
          temp,
          '-vn',
          '-c:a',
          'libmp3lame',
          '-b:a',
          '192k',
          out,
        ], totalMs: duration);
        if (task.cancelRequested) throw const _Canceled();
        if (!ok) throw Exception('falha ao converter para MP3');
        task.outputPath = out;
        task.fileName = out.split('/').last;
        task.title = task.fileName!;
        task.message = 'Concluído • ${formatBytes(info.received)}';
        return;
      }

      final targetFolder = AppPaths.folderFor(
        isVideo: videoFile && !audioFile,
        isAudio: audioFile,
      );
      final out = uniquePath(targetFolder, name);
      try {
        Directory(targetFolder).createSync(recursive: true);
      } catch (_) {}
      await File(temp).rename(out);
      task.outputPath = out;
      task.fileName = name;
      task.title = name;
      task.message = 'Concluído • ${formatBytes(info.received)}';
    } catch (_) {
      try {
        final file = File(temp);
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _runMediaStream(
    DownloadTask task,
    Map<String, String> headers,
  ) async {
    final url = task.sourceUrl;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final rawName = (task.fileName != null && task.fileName!.isNotEmpty)
        ? task.fileName!
        : (fileNameFromUrl(url) ?? task.title);
    var stem = _withoutExtension(sanitizeFileName(rawName));
    final generic = {
      '',
      'midia',
      'media',
      'video',
      'audio',
      'playlist',
      'master',
      'index',
      'manifest',
      'stream',
    };
    if (generic.contains(stem.toLowerCase())) {
      stem = task.isAudio ? 'audio_$stamp' : 'video_$stamp';
    }

    final folder = task.isAudio ? AppPaths.music : AppPaths.videos;
    try {
      Directory(folder).createSync(recursive: true);
    } catch (_) {}

    final duration = await _probeDuration(url, headers: headers);

    if (task.isAudio) {
      final out = uniquePath(folder, '$stem.mp3');
      if (await _runMediaAudio(task, url, headers, out, duration)) {
        task.outputPath = out;
        task.fileName = out.split('/').last;
        task.title = task.fileName!;
        return;
      }
      if (task.cancelRequested) throw const _Canceled();
      // Alguns streams não convertem para MP3: tenta M4A.
      final m4a = uniquePath(folder, '$stem.m4a');
      if (await _runMediaAudio(task, url, headers, m4a, duration, m4a: true)) {
        task.outputPath = m4a;
        task.fileName = m4a.split('/').last;
        task.title = task.fileName!;
        return;
      }
      throw Exception('não foi possível extrair o áudio da transmissão');
    }

    final out = uniquePath(folder, '$stem.mp4');
    if (await _runMediaVideo(task, url, headers, out, duration)) {
      task.outputPath = out;
      task.fileName = out.split('/').last;
      task.title = task.fileName!;
      return;
    }
    if (task.cancelRequested) throw const _Canceled();

    // Fallback 1: contêiner Matroska costuma aceitar qualquer codec.
    final mkv = uniquePath(folder, '$stem.mkv');
    if (await _runMediaVideo(task, url, headers, mkv, duration)) {
      task.outputPath = mkv;
      task.fileName = mkv.split('/').last;
      task.title = task.fileName!;
      return;
    }
    if (task.cancelRequested) throw const _Canceled();

    // Fallback 2: recodifica para MP4 (mais lento, porém compatível).
    task.phase = DownloadPhase.processing;
    task.message = 'Recodificando vídeo...';
    _notify(force: true);
    final reencoded = uniquePath(folder, '$stem.mp4');
    final ok = await _runFfmpegTask(task, [
      '-y',
      ..._ffmpegHttpArgs(headers),
      '-protocol_whitelist',
      'file,http,https,tcp,tls,crypto,data',
      '-i',
      url,
      '-c:v',
      'mpeg4',
      '-q:v',
      '5',
      '-c:a',
      'aac',
      '-b:a',
      '160k',
      '-movflags',
      '+faststart',
      reencoded,
    ], totalMs: duration);
    if (task.cancelRequested) throw const _Canceled();
    if (!ok) throw Exception('não foi possível baixar a transmissão');
    task.outputPath = reencoded;
    task.fileName = reencoded.split('/').last;
    task.title = task.fileName!;
  }

  Future<bool> _runMediaVideo(
    DownloadTask task,
    String url,
    Map<String, String> headers,
    String out,
    int? duration,
  ) async {
    task.phase = DownloadPhase.downloading;
    task.message = 'Baixando vídeo...';
    _notify(force: true);
    return _runFfmpegTask(task, [
      '-y',
      ..._ffmpegHttpArgs(headers),
      '-protocol_whitelist',
      'file,http,https,tcp,tls,crypto,data',
      '-i',
      url,
      '-c',
      'copy',
      '-bsf:a',
      'aac_adtstoasc',
      '-movflags',
      '+faststart',
      out,
    ], totalMs: duration);
  }

  Future<bool> _runMediaAudio(
    DownloadTask task,
    String url,
    Map<String, String> headers,
    String out,
    int? duration, {
    bool m4a = false,
  }) async {
    task.phase = DownloadPhase.downloading;
    task.message = 'Baixando áudio...';
    _notify(force: true);
    return _runFfmpegTask(task, [
      '-y',
      ..._ffmpegHttpArgs(headers),
      '-protocol_whitelist',
      'file,http,https,tcp,tls,crypto,data',
      '-i',
      url,
      '-vn',
      '-c:a',
      m4a ? 'aac' : 'libmp3lame',
      '-b:a',
      '192k',
      out,
    ], totalMs: duration);
  }

  /// Copia a resposta HTTP para [path], atualizando o progresso da tarefa.
  Future<_DownloadInfo> _streamToTemp(
    DownloadTask task,
    String url,
    Map<String, String> headers,
    String path,
  ) async {
    final dio = _buildDio();
    task.cancelToken = CancelToken();

    final response = await dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        headers: headers,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
      ),
      cancelToken: task.cancelToken,
    );

    final body = response.data;
    if (body == null) throw Exception('resposta vazia do servidor');

    final declared = int.tryParse(
      response.headers.value('content-length') ?? '',
    );
    final candidate = (declared != null && declared > 0)
        ? declared
        : task.totalBytes;
    final total = (candidate != null && candidate > 0) ? candidate : null;
    task.totalBytes = total;
    task.phase = DownloadPhase.downloading;
    task.message = total != null ? 'Baixando 0%' : 'Baixando...';
    _notify(force: true);

    final file = File(path);
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in body.stream) {
        if (task.cancelRequested) throw const _Canceled();
        sink.add(chunk);
        received += chunk.length;
        task.receivedBytes = received;
        if (total != null && total > 0) {
          task.progress = (received / total).clamp(0.0, 1.0).toDouble();
          task.message =
              'Baixando ${(task.progress! * 100).toStringAsFixed(0)}% • '
              '${formatBytes(received)} de ${formatBytes(total)}';
        } else {
          task.progress = null;
          task.message = 'Baixando... ${formatBytes(received)}';
        }
        _notify();
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      try {
        await sink.flush();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    }

    return _DownloadInfo(
      realUrl: response.realUri.toString(),
      contentType: response.headers.value('content-type'),
      contentDisposition: response.headers.value('content-disposition'),
      received: received,
    );
  }

  static List<String> _ffmpegHttpArgs(Map<String, String> headers) {
    final args = <String>[];
    final userAgent = headers['User-Agent'];
    if (userAgent != null && userAgent.isNotEmpty) {
      args.addAll(['-user_agent', userAgent]);
    }
    final buffer = StringBuffer();
    headers.forEach((key, value) {
      if (key == 'User-Agent' || value.isEmpty) return;
      buffer.write('$key: $value\r\n');
    });
    if (buffer.isNotEmpty) {
      args.addAll(['-headers', buffer.toString()]);
    }
    return args;
  }

  static Future<int?> _probeDuration(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    try {
      final session = await FFprobeKit.getMediaInformationFromCommandArguments([
        '-v',
        'error',
        '-hide_banner',
        '-print_format',
        'json',
        '-show_format',
        '-show_streams',
        '-show_chapters',
        ..._ffmpegHttpArgs(headers),
        '-i',
        path,
      ], 20000);
      final value = double.tryParse(
        session.getMediaInformation()?.getDuration() ?? '',
      );
      if (value == null || value <= 0) return null;
      return (value * 1000).round();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _runFfmpegTask(
    DownloadTask task,
    List<String> args, {
    int? totalMs,
  }) async {
    final completer = Completer<void>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (completed) {
        if (!completer.isCompleted) completer.complete();
      },
      null,
      (statistics) {
        if (task.cancelRequested) return;
        final size = statistics.getSize();
        if (size > 0) task.receivedBytes = size;
        final time = statistics.getTime();
        final total = totalMs ?? 0;
        if (total > 0 && time > 0) {
          final ratio = (time / total).clamp(0.0, 1.0).toDouble();
          task.progress = ratio;
          task.message =
              'Processando ${(ratio * 100).toStringAsFixed(0)}% • '
              '${formatBytes(size)}';
        } else {
          task.progress = null;
          task.message = size > 0
              ? 'Baixando... ${formatBytes(size)}'
              : 'Processando...';
        }
        _notify();
      },
    );

    final sessionId = session.getSessionId();
    if (task.cancelRequested) {
      try {
        await FFmpegKit.cancel(sessionId);
      } catch (_) {}
    }

    await completer.future;
    if (task.cancelRequested) return false;
    final code = await session.getReturnCode();
    return ReturnCode.isSuccess(code);
  }

  static String _withoutExtension(String name) {
    final ext = fileExtension(name);
    if (ext.isEmpty) return name;
    return name.substring(0, name.length - ext.length - 1);
  }

  static String _pickFileName({
    String? suggested,
    String? contentDisposition,
    required String url,
    String? mimeType,
  }) {
    var name =
        fileNameFromDisposition(contentDisposition) ??
        (suggested != null && suggested.trim().isNotEmpty
            ? suggested.trim()
            : null) ??
        fileNameFromUrl(url) ??
        'arquivo';
    name = sanitizeFileName(name);
    if (!hasFileExtension(name)) {
      final ext = extensionForMime(mimeType);
      if (ext != null && ext != 'bin') name = '$name.$ext';
    }
    return name;
  }

  static Future<void> _saveDataUri(DownloadTask task, String url) async {
    final data = Uri.parse(url).data;
    if (data == null) throw Exception('dados inválidos');
    final bytes = data.contentAsBytes();
    var name =
        task.fileName ?? 'arquivo_${DateTime.now().millisecondsSinceEpoch}';
    if (!hasFileExtension(name)) {
      final ext = extensionForMime(data.mimeType);
      if (ext != null) name = '$name.$ext';
    }
    final folder = AppPaths.folderFor(
      isVideo: isVideoMime(data.mimeType) || isVideoUrl(name),
      isAudio: isAudioMime(data.mimeType) || isAudioUrl(name),
    );
    final out = uniquePath(folder, name);
    await File(out).writeAsBytes(bytes, flush: true);
    task.outputPath = out;
    task.progress = 1;
    task.receivedBytes = bytes.length;
    task.totalBytes = bytes.length;
    task.message = 'Concluído • ${formatBytes(bytes.length)}';
  }

  static Future<String> _cookiesFor(String url) async {
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(url),
      );
      if (cookies.isEmpty) return '';
      return cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {
      return '';
    }
  }

  static Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(hours: 2),
        sendTimeout: const Duration(seconds: 30),
        followRedirects: true,
        maxRedirects: 8,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 30);
        client.badCertificateCallback = (certificate, host, port) =>
            isPrivateHost(host);
        return client;
      },
    );
    return dio;
  }

  Future<void> _downloadYouTube(
    DownloadTask task,
    YoutubeExplode yt,
    StreamInfo info,
    String path,
    String label,
  ) async {
    final sink = File(path).openWrite();
    var received = 0;
    final total = info.size.totalBytes;
    try {
      await for (final chunk in yt.videos.streamsClient.get(info)) {
        if (task.cancelRequested) throw const _Canceled();
        sink.add(chunk);
        received += chunk.length;
        final ratio = total > 0 ? received / total : null;
        task.progress = ratio?.clamp(0.0, 1.0).toDouble();
        task.message = ratio == null
            ? 'Baixando $label...'
            : 'Baixando $label: ${(ratio * 100).toStringAsFixed(0)}%';
        _notify();
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  static AudioOnlyStreamInfo? _bestAudio(StreamManifest manifest) {
    final mp4 = manifest.audioOnly
        .where((a) => a.container == StreamContainer.mp4)
        .toList();
    final pool = mp4.isNotEmpty ? mp4 : manifest.audioOnly.toList();
    if (pool.isEmpty) return null;
    pool.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return pool.first;
  }

  static T? _pick<T extends VideoStreamInfo>(Iterable<T> streams, int height) {
    final matches = streams
        .where((s) => s.videoResolution.height == height)
        .toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return matches.first;
  }

  static _Selection? _selectVideo(
    StreamManifest manifest,
    int? requestedHeight,
  ) {
    final all = <VideoStreamInfo>[...manifest.muxed, ...manifest.videoOnly];
    if (all.isEmpty) return null;

    final heights = all.map((s) => s.videoResolution.height).toSet().toList();
    int target;
    if (requestedHeight != null && heights.contains(requestedHeight)) {
      target = requestedHeight;
    } else if (requestedHeight != null) {
      heights.sort(
        (a, b) =>
            (a - requestedHeight).abs().compareTo((b - requestedHeight).abs()),
      );
      target = heights.first;
    } else {
      heights.sort();
      target = heights.last;
    }

    final muxed = _pick(manifest.muxed, target);
    if (muxed != null) {
      return _Selection(video: muxed, height: target);
    }
    final videoOnly = _pick(manifest.videoOnly, target);
    if (videoOnly == null) return null;
    final audio = _bestAudio(manifest);
    return _Selection(video: videoOnly, audio: audio, height: target);
  }
}

class _Selection {
  final VideoStreamInfo video;
  final AudioOnlyStreamInfo? audio;
  final int height;

  _Selection({required this.video, this.audio, required this.height});

  bool get needsMux => audio != null;
}

class _DownloadInfo {
  const _DownloadInfo({
    required this.realUrl,
    required this.received,
    this.contentType,
    this.contentDisposition,
  });

  final String realUrl;
  final int received;
  final String? contentType;
  final String? contentDisposition;
}

class _BlobDownload {
  _BlobDownload({required this.task, required this.file, required this.sink});

  final DownloadTask task;
  final File file;
  final IOSink sink;
  int received = 0;
}

class _Canceled implements Exception {
  const _Canceled();
}

// ---------------------------------------------------------------------------
// Inicialização
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsStore.load();
  await HistoryStore.instance.load();
  AppPaths.ensureFolders();
  runApp(const TubeFetchApp());
}

// ---------------------------------------------------------------------------
// App + tema
// ---------------------------------------------------------------------------

class TubeFetchApp extends StatefulWidget {
  const TubeFetchApp({super.key});

  @override
  State<TubeFetchApp> createState() => _TubeFetchAppState();
}

class _TubeFetchAppState extends State<TubeFetchApp> {
  ThemeMode _mode = SettingsStore.mode;
  Color _seed = SettingsStore.seed;

  void _onThemeChanged(ThemeMode mode, Color seed) {
    setState(() {
      _mode = mode;
      _seed = seed;
    });
    SettingsStore.mode = mode;
    SettingsStore.seed = seed;
    SettingsStore.save();
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? const Color(0xFF0F0F10) : const Color(0xFFF7F7F8);
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _seed,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: background,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TubeFetch',
      debugShowCheckedModeBanner: false,
      themeMode: _mode,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: BrowserScreen(
        themeMode: _mode,
        seed: _seed,
        onThemeChanged: _onThemeChanged,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Navegador (barra superior estilo Chrome)
// ---------------------------------------------------------------------------

class BrowserScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final Color seed;
  final void Function(ThemeMode, Color) onThemeChanged;

  const BrowserScreen({
    super.key,
    required this.themeMode,
    required this.seed,
    required this.onThemeChanged,
  });

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _isLoading = true;
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String _currentUrl = kHomeUrl;
  String _pageTitle = '';

  String? _detectedVideoUrl;
  List<String> _pageMedia = const [];
  List<String> _jsMedia = const [];
  final Set<String> _sniffedMedia = {};
  DateTime _lastMediaUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<String> _autoPrompted = {};
  bool _dialogOpen = false;
  bool _mediaBannerDismissed = false;
  Timer? _iosMediaTimer;
  String? _lastClipboardPrompt;
  String? _pendingIntentUrl;
  final Map<String, DateTime> _recentDownloads = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastClipboardPrompt = SettingsStore.lastClipboard;
    _urlController.text = kHomeUrl;
    _listenForIntents();
    if (Platform.isIOS) {
      // O WKWebView não tem shouldInterceptRequest: consultamos o DOM e o
      // performance timing da página periodicamente para achar mídia.
      _iosMediaTimer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => _pullPageMedia(),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  void _listenForIntents() {
    kIntentChannel.setMethodCallHandler((call) async {
      if (call.method == 'openUrl' && call.arguments is String) {
        final url = call.arguments as String;
        if (url.isNotEmpty) _loadUrl(url);
      }
    });

    () async {
      try {
        final url = await kIntentChannel.invokeMethod<String>('getInitialUrl');
        if (!mounted || url == null || url.isEmpty) return;
        if (_controller == null) {
          _pendingIntentUrl = url;
        } else {
          _loadUrl(url);
        }
      } catch (_) {
        // Sem link inicial.
      }
    }();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _iosMediaTimer?.cancel();
    _urlController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  Future<void> _syncNavState() async {
    final controller = _controller;
    if (controller == null) return;
    final back = await controller.canGoBack();
    final forward = await controller.canGoForward();
    if (mounted) {
      setState(() {
        _canGoBack = back;
        _canGoForward = forward;
      });
    }
  }

  // --- Ponte JavaScript -----------------------------------------------------

  Future<void> _injectBridge() async {
    const js = r'''
      (function () {
        function tfPost(payload) {
          try {
            var msg = JSON.stringify(payload);
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('TubeFetchBridge', msg);
            } else if (window.TubeFetchBridge && window.TubeFetchBridge.postMessage) {
              window.TubeFetchBridge.postMessage(msg);
            }
          } catch (e) {}
        }
        window.__tfPost = tfPost;

        // --- Detecção de rede (funciona também no iOS/WKWebView) ----------
        // O WKWebView não expõe shouldInterceptRequest, então observamos as
        // requisições do próprio JavaScript (fetch/XHR) e o performance timing.
        var tfMediaRe = /\.(mp4|m4v|webm|mkv|mov|m3u8|mpd|mp3|m4a|aac|ogg|opus|flac|wav)(\?|#|$)/i;
        window.__tfNet = window.__tfNet || [];
        function tfNoteNet(u) {
          try {
            if (!u || typeof u !== 'string') return;
            if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
            if (!tfMediaRe.test(u)) return;
            if (window.__tfNet.indexOf(u) === -1) window.__tfNet.push(u);
          } catch (e) {}
        }
        if (!window.__tfNetHooked) {
          window.__tfNetHooked = true;
          try {
            var tfOrigFetch = window.fetch;
            if (tfOrigFetch) {
              window.fetch = function (input) {
                try {
                  tfNoteNet(typeof input === 'string' ? input : (input && input.url));
                } catch (e) {}
                return tfOrigFetch.apply(this, arguments);
              };
            }
          } catch (e) {}
          try {
            var tfOrigOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function (method, url) {
              try { tfNoteNet(String(url)); } catch (e) {}
              return tfOrigOpen.apply(this, arguments);
            };
          } catch (e) {}
        }

        function collectMedia() {
          var out = [], seen = {};
          function add(u) {
            if (!u || typeof u !== 'string') return;
            if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
            if (!seen[u]) { seen[u] = true; out.push(u); }
          }
          try {
            document.querySelectorAll('video, audio').forEach(function (el) {
              add(el.currentSrc || el.src);
              el.querySelectorAll('source').forEach(function (s) { add(s.src); });
            });
            document.querySelectorAll('a[href]').forEach(function (a) {
              var h = a.href || '';
              if (/\.(mp4|m4v|webm|mkv|mov|mp3|m4a|aac|wav|ogg|opus)(\?|$)/i.test(h)) add(h);
            });
          } catch (e) {}
          try {
            (window.__tfNet || []).forEach(add);
          } catch (e) {}
          try {
            performance.getEntriesByType('resource').forEach(function (e) {
              if (e && tfMediaRe.test(e.name || '')) add(e.name);
            });
          } catch (e) {}
          return out;
        }

        // Usado pelo Dart como fallback quando o callHandler não responde.
        window.__tfCollect = function () {
          try { return JSON.stringify(collectMedia()); } catch (e) { return '[]'; }
        };

        window.__tfReport = function () {
          try {
            tfPost({
              type: 'page',
              url: location.href,
              title: document.title || '',
              media: collectMedia()
            });
          } catch (e) {}
        };

        window.__tfDownloadBlob = function (blobUrl, name) {
          try {
            var id = 'blob_' + Date.now() + '_' + Math.random().toString(36).slice(2);
            fetch(blobUrl).then(function (response) {
              return response.blob();
            }).then(function (blob) {
              var fileName = name || ('arquivo_' + Date.now());
              var size = blob.size || 0;
              tfPost({ type: 'blobStart', id: id, name: fileName, size: size, mime: blob.type || '' });
              var offset = 0;
              var chunkSize = 512 * 1024;
              function next() {
                if (offset >= size) { tfPost({ type: 'blobEnd', id: id }); return; }
                var slice = blob.slice(offset, Math.min(offset + chunkSize, size));
                var reader = new FileReader();
                reader.onload = function () {
                  var result = String(reader.result || '');
                  var comma = result.indexOf(',');
                  tfPost({
                    type: 'blobChunk',
                    id: id,
                    data: comma >= 0 ? result.substring(comma + 1) : ''
                  });
                  offset += chunkSize;
                  setTimeout(next, 0);
                };
                reader.onerror = function () { tfPost({ type: 'blobError', id: id }); };
                reader.readAsDataURL(slice);
              }
              next();
            }).catch(function () { tfPost({ type: 'blobError', id: id }); });
          } catch (e) {}
        };

        if (window.__tfBridgeInstalled) {
          window.__tfReport();
          return;
        }
        window.__tfBridgeInstalled = true;

        var filePattern = /\.(7z|aac|apk|avi|bin|bz2|csv|deb|dmg|docx?|epub|exe|flac|gif|gz|heic|img|iso|jar|jpe?g|m4a|m4v|mkv|mov|mp3|mp4|mpeg|mpg|msix|odp|ods|odt|ogg|opus|otf|pdf|png|pptx?|rar|raw|rpm|srt|tar|tgz|torrent|ttf|txt|vtt|wav|webm|webp|wim|xlsx?|xz|zip|zipx|3gp)(\?|#|$)/i;
        var mediaPattern = /\.(mp4|m4v|webm|mkv|mov|mp3|m4a|aac|wav|ogg|opus|flac|m3u8|mpd)(\?|#|$)/i;

        document.addEventListener('click', function (ev) {
          try {
            var el = ev.target;
            while (el && el.tagName && el.tagName.toLowerCase() !== 'a') {
              el = el.parentElement;
            }
            if (!el || !el.getAttribute) return;
            var href = el.href || el.getAttribute('href') || '';
            if (!href) return;
            var download = el.hasAttribute('download');
            var name = download ? (el.getAttribute('download') || '') : '';
            if (href.indexOf('blob:') === 0) {
              if (download || filePattern.test(href)) {
                ev.preventDefault();
                ev.stopPropagation();
                window.__tfDownloadBlob(href, name);
              }
              return;
            }
            if (mediaPattern.test(href)) {
              ev.preventDefault();
              ev.stopPropagation();
              tfPost({
                type: 'media',
                url: href,
                fileName: name,
                referer: location.href
              });
              return;
            }
            if (download || filePattern.test(href)) {
              ev.preventDefault();
              ev.stopPropagation();
              tfPost({
                type: 'download',
                url: href,
                fileName: name,
                referer: location.href
              });
            }
          } catch (e) {}
        }, true);

        var originalOpen = window.open;
        window.open = function (url) {
          try {
            var value = url == null ? '' : String(url);
            if (value.indexOf('blob:') === 0) {
              window.__tfDownloadBlob(value, '');
              return null;
            }
            if (value && mediaPattern.test(value)) {
              tfPost({
                type: 'media',
                url: value,
                fileName: '',
                referer: location.href
              });
              return null;
            }
            if (value && filePattern.test(value)) {
              tfPost({
                type: 'download',
                url: value,
                fileName: '',
                referer: location.href
              });
              return null;
            }
          } catch (e) {}
          return originalOpen ? originalOpen.apply(window, arguments) : null;
        };

        document.addEventListener('yt-navigate-finish', window.__tfReport);
        document.addEventListener('yt-page-data-updated', window.__tfReport);
        window.addEventListener('popstate', window.__tfReport);
        window.addEventListener('hashchange', window.__tfReport);
        window.__tfReport();
        setInterval(window.__tfReport, 3000);
      })();
    ''';
    try {
      await _controller?.evaluateJavascript(source: js);
    } catch (_) {
      // Página ainda carregando.
    }
    await _pullPageMedia();
  }

  /// Lê a lista de mídia direto do JavaScript (fallback sem depender do
  /// `callHandler`, que no iOS pode não responder em páginas com CSP rígida).
  Future<void> _pullPageMedia() async {
    final controller = _controller;
    if (controller == null || !mounted) return;
    try {
      final raw = await controller.evaluateJavascript(
        source: 'window.__tfCollect ? window.__tfCollect() : "[]"',
      );
      _applyJsMedia(raw);
    } catch (_) {
      // Página sem o bridge (ainda carregando ou domínio restrito).
    }
  }

  void _applyJsMedia(Object? raw) {
    dynamic data = raw;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        return;
      }
    }
    if (data is! List) return;
    final media = <String>[];
    for (final item in data) {
      final value = item?.toString() ?? '';
      if (value.startsWith('http')) media.add(value);
    }
    if (_listEquals(media, _jsMedia)) return;
    _jsMedia = List.unmodifiable(media);
    _updateMediaView(force: true);
  }

  void _onBridgeMessage(List<dynamic> args) {
    if (args.isEmpty) return;
    try {
      final raw = args.first;
      if (raw == null) return;
      final data = raw is String ? jsonDecode(raw) : raw;
      if (data is! Map) return;

      final type = (data['type'] ?? 'page').toString();
      switch (type) {
        case 'download':
          _startFileDownload(
            url: (data['url'] ?? '').toString(),
            fileName: (data['fileName'] ?? '').toString(),
            referer: (data['referer'] ?? _currentUrl).toString(),
          );
          return;
        case 'media':
          final mediaUrl = (data['url'] ?? '').toString();
          final mediaName = (data['fileName'] ?? '').toString();
          _startMediaDownload(
            url: mediaUrl,
            fileName: mediaName,
            referer: (data['referer'] ?? _currentUrl).toString(),
            isAudio: isAudioUrl(mediaName.isEmpty ? mediaUrl : mediaName),
          );
          return;
        case 'blobStart':
          DownloadManager.instance.startBlob(
            blobId: (data['id'] ?? '').toString(),
            fileName: (data['name'] ?? '').toString(),
            mimeType: (data['mime'] ?? '').toString(),
            size: data['size'] is int ? data['size'] as int : 0,
            referer: _currentUrl,
          );
          _openDownloads();
          return;
        case 'blobChunk':
          DownloadManager.instance.appendBlobChunk(
            (data['id'] ?? '').toString(),
            (data['data'] ?? '').toString(),
          );
          return;
        case 'blobEnd':
          DownloadManager.instance.finishBlob((data['id'] ?? '').toString());
          return;
        case 'blobError':
          DownloadManager.instance.abortBlob((data['id'] ?? '').toString());
          return;
      }

      final url = (data['url'] ?? '').toString();
      final title = (data['title'] ?? '').toString();
      final media = <String>[];
      final rawMedia = data['media'];
      if (rawMedia is List) {
        for (final item in rawMedia) {
          final value = (item ?? '').toString();
          if (value.startsWith('http')) media.add(value);
        }
      }
      _onPageInfo(url: url, title: title, media: media);
    } catch (_) {
      // Mensagem inválida.
    }
  }

  void _onPageInfo({
    required String url,
    required String title,
    required List<String> media,
  }) {
    if (!mounted) return;

    if (url.isNotEmpty && url != _currentUrl) {
      setState(() {
        _currentUrl = url;
        if (!_focusNode.hasFocus) _urlController.text = url;
      });
      _syncNavState();
    }

    if (title.isNotEmpty && title != _pageTitle) {
      _pageTitle = title;
      if (url != kHomeUrl) HistoryStore.instance.record(url, title);
    }

    final youtubeUrl = canonicalYouTubeUrl(url);
    if (youtubeUrl != null) {
      if (_detectedVideoUrl != youtubeUrl) {
        setState(() => _detectedVideoUrl = youtubeUrl);
      }
      _maybeAutoPrompt(youtubeUrl);
    } else if (_detectedVideoUrl != null) {
      setState(() => _detectedVideoUrl = null);
    }

    _jsMedia = List.unmodifiable(media);
    _updateMediaView(force: true);
  }

  void _updateMediaView({bool force = false}) {
    if (!mounted) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastMediaUpdate).inMilliseconds < 700) {
      return;
    }
    final merged = <String>{..._jsMedia, ..._sniffedMedia}.toList();
    if (_listEquals(merged, _pageMedia)) return;
    _lastMediaUpdate = now;
    setState(() => _pageMedia = List.unmodifiable(merged));
  }

  void _maybeSniffMedia(String url) {
    if (!isSniffableMediaUrl(url)) return;
    if (_sniffedMedia.contains(url)) return;
    if (_sniffedMedia.length >= 40) return;
    _sniffedMedia.add(url);
    _updateMediaView();
  }

  void _onPageUrl(String url) {
    if (!mounted || url == _currentUrl) return;
    setState(() {
      _currentUrl = url;
      _mediaBannerDismissed = false;
      if (!_focusNode.hasFocus) _urlController.text = url;
    });
    final youtubeUrl = canonicalYouTubeUrl(url);
    if (youtubeUrl != null) {
      setState(() => _detectedVideoUrl = youtubeUrl);
      _maybeAutoPrompt(youtubeUrl);
    } else if (_detectedVideoUrl != null) {
      setState(() => _detectedVideoUrl = null);
    }
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // --- Área de transferência ------------------------------------------------

  Future<void> _checkClipboard() async {
    if (!mounted || _dialogOpen) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty || text == _lastClipboardPrompt) return;
      if (text == _currentUrl) return;
      final canonical = canonicalYouTubeUrl(text);
      final direct = canonical == null && looksLikeMedia(text);
      if (canonical == null && !direct) return;

      _lastClipboardPrompt = text;
      SettingsStore.lastClipboard = text;
      SettingsStore.save();
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.content_paste_search),
          title: const Text('Link copiado detectado'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Deseja baixar o vídeo a partir do link copiado?'),
              const SizedBox(height: 12),
              Text(
                text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Agora não'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.download),
              label: const Text('Baixar'),
            ),
          ],
        ),
      );

      if (accepted != true || !mounted) return;
      if (canonical != null) {
        await _openDownloadDialog(canonical);
      } else {
        _startMediaDownload(url: text, isAudio: isAudioUrl(text));
      }
    } catch (_) {
      // Área de transferência indisponível.
    }
  }

  // --- URL / pesquisa -------------------------------------------------------

  String _resolveUrl(String input) {
    final value = input.trim();
    if (value.isEmpty) return kHomeUrl;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.contains('.') && !value.contains(' ')) return 'https://$value';
    return 'https://www.google.com/search?q=${Uri.encodeComponent(value)}';
  }

  void _submitUrl() {
    _focusNode.unfocus();
    _loadUrl(_resolveUrl(_urlController.text));
  }

  void _loadUrl(String url) {
    _focusNode.unfocus();
    _urlController.text = url;
    final controller = _controller;
    if (controller == null) {
      _pendingIntentUrl = url;
      return;
    }
    controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _maybeAutoPrompt(String url) {
    // No iOS usamos o banner "Vídeo detectado" (menos intrusivo e sem
    // diálogo surgindo por cima da página a cada navegação).
    if (Platform.isIOS) return;
    if (_dialogOpen) return;
    if (_autoPrompted.contains(url)) return;
    _autoPrompted.add(url);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      _openDownloadDialog(url);
    });
  }

  // --- Menu -----------------------------------------------------------------

  void _onMenuSelected(String value) {
    switch (value) {
      case 'download':
        final url = _detectedVideoUrl;
        if (url != null) _openDownloadDialog(url);
        break;
      case 'media':
        _showMediaPicker();
        break;
      case 'safari':
        _openInSafari();
        break;
      case 'history':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => HistoryScreen(
              onOpen: (url) {
                Navigator.of(context).pop();
                _loadUrl(url);
              },
            ),
          ),
        );
        break;
      case 'downloads':
        _openDownloads();
        break;
      case 'settings':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SettingsScreen(
              mode: widget.themeMode,
              seed: widget.seed,
              onChanged: widget.onThemeChanged,
            ),
          ),
        );
        break;
      case 'home':
        _loadUrl(kHomeUrl);
        break;
      case 'about':
        _showAbout();
        break;
    }
  }

  void _openDownloads() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const DownloadsScreen()));
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'TubeFetch',
      applicationVersion: kAppVersion,
      applicationLegalese: '© SysArchX',
      children: const [
        SizedBox(height: 12),
        Text(
          'Navegador completo com download de vídeos, músicas e qualquer '
          'arquivo. Vídeos e músicas vão para subpastas em Download/TubeFetch; '
          'os demais arquivos ficam na pasta principal.',
        ),
      ],
    );
  }

  // --- Download -------------------------------------------------------------

  void _startFileDownload({
    required String url,
    String? fileName,
    String? contentDisposition,
    String? mimeType,
    int? contentLength,
    String? referer,
    String? userAgent,
  }) {
    if (url.isEmpty) return;
    final now = DateTime.now();
    _recentDownloads.removeWhere(
      (_, time) => now.difference(time).inSeconds > 15,
    );
    if (_recentDownloads.containsKey(url) ||
        DownloadManager.instance.activeForUrl(url) != null) {
      _openDownloads();
      return;
    }
    _recentDownloads[url] = now;
    DownloadManager.instance.enqueueFile(
      url: url,
      fileName: fileName,
      contentDisposition: contentDisposition,
      mimeType: mimeType,
      contentLength: contentLength,
      referer: referer ?? _currentUrl,
      userAgent: userAgent,
    );
    _openDownloads();
  }

  void _startMediaDownload({
    required String url,
    String? fileName,
    String? mimeType,
    String? referer,
    String? userAgent,
    bool? isAudio,
    String? title,
  }) {
    if (url.isEmpty) return;
    final now = DateTime.now();
    _recentDownloads.removeWhere(
      (_, time) => now.difference(time).inSeconds > 15,
    );
    if (_recentDownloads.containsKey(url) ||
        DownloadManager.instance.activeForUrl(url) != null) {
      _openDownloads();
      return;
    }
    _recentDownloads[url] = now;
    DownloadManager.instance.enqueueMedia(
      url: url,
      fileName: fileName,
      mimeType: mimeType,
      referer: referer ?? _currentUrl,
      userAgent: userAgent,
      isAudio: isAudio,
      title: title,
    );
    _openDownloads();
  }

  void _handleDownloadRequest(DownloadStartRequest request) {
    final url = request.url.toString();
    if (url.startsWith('blob:')) {
      final name = request.suggestedFilename ?? '';
      _controller?.evaluateJavascript(
        source:
            'window.__tfDownloadBlob && window.__tfDownloadBlob('
            '${jsonEncode(url)}, ${jsonEncode(name)});',
      );
      return;
    }

    final name = request.suggestedFilename ?? '';
    final mime = request.mimeType;
    final probe = name.trim().isEmpty ? url : name;
    final audio = isAudioMime(mime) || isAudioUrl(probe);
    final video =
        isVideoMime(mime) ||
        isVideoUrl(probe) ||
        isStreamingMediaUrl(url) ||
        isStreamingMediaMime(mime);

    if (audio || video) {
      _startMediaDownload(
        url: url,
        fileName: name,
        mimeType: mime,
        referer: _currentUrl,
        userAgent: request.userAgent,
        isAudio: audio && !video,
      );
      return;
    }

    _startFileDownload(
      url: url,
      fileName: name,
      contentDisposition: request.contentDisposition,
      mimeType: mime,
      contentLength: request.contentLength > 0 ? request.contentLength : null,
      referer: _currentUrl,
      userAgent: request.userAgent,
    );
  }

  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    NavigationAction action,
  ) async {
    final url = action.request.url?.toString() ?? '';
    if (url.isEmpty || !action.isForMainFrame) {
      return NavigationActionPolicy.ALLOW;
    }
    if (url.startsWith('blob:')) {
      _controller?.evaluateJavascript(
        source:
            'window.__tfDownloadBlob && window.__tfDownloadBlob('
            '${jsonEncode(url)}, "");',
      );
      return NavigationActionPolicy.CANCEL;
    }
    if (url.startsWith('data:')) {
      _startFileDownload(url: url, referer: _currentUrl);
      return NavigationActionPolicy.CANCEL;
    }
    if (isMediaUrl(url)) {
      _startMediaDownload(url: url, referer: _currentUrl);
      return NavigationActionPolicy.CANCEL;
    }
    if (looksLikeDownloadUrl(url)) {
      _startFileDownload(url: url, referer: _currentUrl);
      return NavigationActionPolicy.CANCEL;
    }
    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _openDownloadDialog(String url) async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    final request = await showDialog<DownloadRequest>(
      context: context,
      builder: (_) => DownloadOptionsDialog(videoUrl: url),
    );
    _dialogOpen = false;
    if (request == null || !mounted) return;

    if (canonicalYouTubeUrl(request.url) != null) {
      DownloadManager.instance.enqueue(
        url: request.url,
        isAudio: request.isAudio,
        height: request.height,
      );
    } else {
      DownloadManager.instance.enqueueMedia(
        url: request.url,
        isAudio: request.isAudio,
      );
    }
    _openDownloads();
  }

  Future<void> _showMediaPicker() async {
    final media = _pageMedia;
    if (media.isEmpty) {
      _snack('Nenhuma mídia detectada nesta página.');
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Mídia detectada'),
        children: [
          for (final url in media.take(12))
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(url),
              child: Row(
                children: [
                  const Icon(Icons.play_circle_outline, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      shortNameOf(url),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null && mounted) {
      _startMediaDownload(
        url: selected,
        fileName: shortNameOf(selected),
        isAudio: isAudioUrl(selected),
      );
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // --- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (Platform.isIOS) return _buildIosScaffold(scheme);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildToolbar(),
            if (_isLoading)
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 2.5,
                color: scheme.primary,
                backgroundColor: scheme.primary.withValues(alpha: 0.15),
              ),
            if (_showMediaBanner) _buildMediaBanner(scheme),
            Expanded(child: _buildWebView()),
          ],
        ),
      ),
    );
  }

  /// WebView compartilhada pelos layouts Android e iOS.
  Widget _buildWebView() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_pendingIntentUrl ?? kHomeUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        cacheEnabled: true,
        useShouldOverrideUrlLoading: true,
        useOnDownloadStart: true,
        mediaPlaybackRequiresUserGesture: false,
        supportMultipleWindows: false,
        allowFileAccess: true,
        allowContentAccess: true,
        thirdPartyCookiesEnabled: true,
        sharedCookiesEnabled: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'TubeFetchBridge',
          callback: (args) {
            _onBridgeMessage(args);
            return null;
          },
        );
        final pending = _pendingIntentUrl;
        if (pending != null && pending.isNotEmpty) {
          _pendingIntentUrl = null;
          controller.loadUrl(urlRequest: URLRequest(url: WebUri(pending)));
        }
      },
      onLoadStart: (controller, url) {
        if (!mounted) return;
        final newUrl = url?.toString() ?? '';
        if (newUrl.isNotEmpty) {
          final newHost = Uri.tryParse(newUrl)?.host ?? '';
          final oldHost = Uri.tryParse(_currentUrl)?.host ?? '';
          if (newHost != oldHost) {
            _sniffedMedia.clear();
            _jsMedia = const [];
            _pageMedia = const [];
          }
          _mediaBannerDismissed = false;
        }
        setState(() {
          _isLoading = true;
          _progress = 0;
          if (url != null) {
            _currentUrl = url.toString();
            if (!_focusNode.hasFocus) {
              _urlController.text = _currentUrl;
            }
          }
        });
      },
      onLoadStop: (controller, url) async {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          if (url != null) {
            _currentUrl = url.toString();
            if (!_focusNode.hasFocus) {
              _urlController.text = _currentUrl;
            }
          }
        });
        await _syncNavState();
        await _injectBridge();
      },
      onProgressChanged: (controller, progress) {
        if (mounted) setState(() => _progress = progress / 100);
      },
      onUpdateVisitedHistory: (controller, url, isReload) {
        if (url != null) _onPageUrl(url.toString());
        _syncNavState();
      },
      shouldOverrideUrlLoading: (controller, action) =>
          _shouldOverrideUrlLoading(action),
      shouldInterceptRequest: (controller, request) async {
        _maybeSniffMedia(request.url.toString());
        return null;
      },
      onDownloadStartRequest: (controller, request) =>
          _handleDownloadRequest(request),
      // NÃO registrar onReceivedServerTrustAuthRequest aqui.
      // No WKWebView esse callback intercepta o desafio TLS de *qualquer*
      // host: devolver CANCEL para hosts públicos cancela todo HTTPS e a
      // página nunca carrega. Sem o callback, o WKWebView usa a validação
      // padrão do sistema (a mesma do Safari).
    );
  }

  // --- Aviso de mídia detectada (iOS e Android) -----------------------------

  bool get _showMediaBanner =>
      !_mediaBannerDismissed &&
      (_detectedVideoUrl != null || _pageMedia.isNotEmpty);

  Widget _buildMediaBanner(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isYoutube = _detectedVideoUrl != null;
    final count = _pageMedia.length;
    final label = isYoutube
        ? 'Vídeo do YouTube detectado'
        : count == 1
        ? 'Vídeo detectado nesta página'
        : '$count mídias detectadas nesta página';
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: isDark ? 0.20 : 0.10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.28),
            width: 0.6,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isYoutube ? Icons.ondemand_video : Icons.movie_outlined,
              size: 18,
              color: scheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: scheme.onSurface),
              ),
            ),
            TextButton(
              onPressed: _downloadDetectedMedia,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Baixar'),
            ),
            IconButton(
              onPressed: () => setState(() => _mediaBannerDismissed = true),
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
              tooltip: 'Fechar',
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  void _downloadDetectedMedia() {
    final youtubeUrl = _detectedVideoUrl;
    if (youtubeUrl != null) {
      _openDownloadDialog(youtubeUrl);
    } else {
      _showMediaPicker();
    }
  }

  // --- Chrome estilo Safari / Liquid Glass (iOS) ----------------------------

  Widget _buildIosScaffold(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF000000)
          : const Color(0xFFFFFFFF),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 2,
              child: _isLoading
                  ? LinearProgressIndicator(
                      value: _progress > 0 && _progress < 1 ? _progress : null,
                      minHeight: 2,
                      color: scheme.primary,
                      backgroundColor: Colors.transparent,
                    )
                  : null,
            ),
            Expanded(child: _buildWebView()),
            if (_showMediaBanner) _buildMediaBanner(scheme),
            SafeArea(top: false, child: _buildIosChrome(scheme, isDark)),
          ],
        ),
      ),
    );
  }

  /// Barra inferior flutuante no estilo Safari (iOS 26 "Liquid Glass"):
  /// cápsula de vidro com blur real, borda hairline, brilho no topo e sombra.
  Widget _buildIosChrome(ColorScheme scheme, bool isDark) {
    final top = (isDark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF))
        .withValues(alpha: isDark ? 0.78 : 0.88);
    final bottom = (isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7))
        .withValues(alpha: isDark ? 0.72 : 0.76);
    final hairline = (isDark ? Colors.white : Colors.black).withValues(
      alpha: 0.14,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [top, bottom],
              ),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: hairline, width: 0.6),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.50 : 0.14),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                _iosBarButton(
                  icon: CupertinoIcons.chevron_back,
                  tooltip: 'Voltar',
                  onTap: _canGoBack ? () => _controller?.goBack() : null,
                ),
                _iosBarButton(
                  icon: CupertinoIcons.chevron_forward,
                  tooltip: 'Avançar',
                  onTap: _canGoForward ? () => _controller?.goForward() : null,
                ),
                Expanded(child: _buildIosAddressPill(scheme, isDark)),
                ListenableBuilder(
                  listenable: DownloadManager.instance,
                  builder: (_, _) {
                    final tasks = DownloadManager.instance.tasks;
                    return Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        _iosBarButton(
                          icon: CupertinoIcons.tray_arrow_down,
                          tooltip: 'Downloads',
                          onTap: () => _onMenuSelected('downloads'),
                        ),
                        if (tasks.isNotEmpty)
                          Positioned(
                            right: 7,
                            top: 8,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: DownloadManager.instance.hasActive
                                    ? const Color(0xFFFF3B30)
                                    : scheme.primary,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                _iosBarButton(
                  icon: CupertinoIcons.ellipsis_circle,
                  tooltip: 'Menu',
                  onTap: _showIosMenu,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIosAddressPill(ColorScheme scheme, bool isDark) {
    final secure = _currentUrl.startsWith('https://');
    final showClear = _urlController.text.isNotEmpty && _focusNode.hasFocus;
    return Container(
      height: 38,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.only(left: 11, right: 4),
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(
          alpha: isDark ? 0.10 : 0.06,
        ),
        borderRadius: BorderRadius.circular(19),
      ),
      child: Row(
        children: [
          Icon(
            secure ? CupertinoIcons.lock : CupertinoIcons.search,
            size: 13,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: CupertinoTextField(
              controller: _urlController,
              focusNode: _focusNode,
              placeholder: 'Pesquisar ou digitar endereço',
              placeholderStyle: TextStyle(
                fontSize: 14.5,
                color: scheme.onSurfaceVariant,
              ),
              style: const TextStyle(fontSize: 14.5),
              padding: EdgeInsets.zero,
              decoration: null,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              enableSuggestions: false,
              onTap: () {
                _urlController.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: _urlController.text.length,
                );
              },
              onSubmitted: (_) => _submitUrl(),
              onChanged: (_) => setState(() {}),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: showClear
                ? () {
                    _urlController.clear();
                    setState(() {});
                  }
                : () {
                    if (_isLoading) {
                      _controller?.stopLoading();
                    } else {
                      _controller?.reload();
                    }
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Icon(
                showClear
                    ? CupertinoIcons.xmark_circle_fill
                    : (_isLoading
                          ? CupertinoIcons.xmark
                          : CupertinoIcons.arrow_clockwise),
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iosBarButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      label: tooltip,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(0, 0),
        pressedOpacity: 0.35,
        onPressed: onTap,
        child: SizedBox(
          width: 38,
          height: 42,
          child: Icon(
            icon,
            size: 21,
            color: enabled ? null : CupertinoColors.inactiveGray,
          ),
        ),
      ),
    );
  }

  Future<void> _openInSafari() async {
    final url = _currentUrl.isEmpty ? kHomeUrl : _currentUrl;
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir no Safari.')),
      );
    }
  }

  Future<void> _showIosMenu() async {
    final entries = <MapEntry<String, String>>[
      if (_detectedVideoUrl != null) const MapEntry('download', 'Baixar vídeo'),
      if (_pageMedia.isNotEmpty) const MapEntry('media', 'Mídia da página'),
      const MapEntry('safari', 'Abrir no Safari'),
      const MapEntry('history', 'Histórico'),
      const MapEntry('downloads', 'Downloads'),
      const MapEntry('settings', 'Configurações'),
      const MapEntry('home', 'Página inicial'),
      const MapEntry('about', 'Sobre'),
    ];
    final host = Uri.tryParse(_currentUrl)?.host ?? '';
    final selected = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(
          host.isEmpty ? 'TubeFetch' : host,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          for (final entry in entries)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop(entry.key),
              child: Text(entry.value),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: const Text('Cancelar'),
        ),
      ),
    );
    if (selected != null && mounted) _onMenuSelected(selected);
  }

  Widget _buildToolbar() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Voltar',
              visualDensity: VisualDensity.compact,
              onPressed: _canGoBack ? () => _controller?.goBack() : null,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              tooltip: 'Avançar',
              visualDensity: VisualDensity.compact,
              onPressed: _canGoForward ? () => _controller?.goForward() : null,
            ),
            Expanded(child: _buildAddressBar(scheme)),
            IconButton(
              icon: Icon(_isLoading ? Icons.close : Icons.refresh),
              tooltip: _isLoading ? 'Parar' : 'Recarregar',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                if (_isLoading) {
                  _controller?.stopLoading();
                } else {
                  _controller?.reload();
                }
              },
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'Menu',
              onSelected: _onMenuSelected,
              itemBuilder: (_) => [
                if (_detectedVideoUrl != null)
                  _menuItem('download', Icons.download, 'Baixar vídeo'),
                if (_pageMedia.isNotEmpty)
                  _menuItem(
                    'media',
                    Icons.play_circle_outline,
                    'Mídia da página',
                  ),
                _menuItem('history', Icons.history, 'Histórico'),
                _menuItem('downloads', Icons.download_done, 'Downloads'),
                _menuItem('settings', Icons.settings_outlined, 'Configurações'),
                const PopupMenuDivider(),
                _menuItem('home', Icons.home_outlined, 'Página inicial'),
                _menuItem('about', Icons.info_outline, 'Sobre'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  Widget _buildAddressBar(ColorScheme scheme) {
    final secure = _currentUrl.startsWith('https://');
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(
              secure ? Icons.lock_outline : Icons.search,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _urlController,
                focusNode: _focusNode,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Pesquisar ou digitar URL',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                textInputAction: TextInputAction.go,
                onTap: () {
                  _urlController.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: _urlController.text.length,
                  );
                },
                onSubmitted: (_) => _submitUrl(),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (_urlController.text.isNotEmpty && _focusNode.hasFocus)
              GestureDetector(
                onTap: () {
                  _urlController.clear();
                  setState(() {});
                },
                child: Icon(
                  Icons.close,
                  size: 17,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Diálogo instantâneo de opções de download
// ---------------------------------------------------------------------------

class DownloadRequest {
  final String url;
  final bool isAudio;
  final int? height;

  const DownloadRequest({
    required this.url,
    required this.isAudio,
    this.height,
  });
}

class DownloadOptionsDialog extends StatelessWidget {
  final String videoUrl;

  const DownloadOptionsDialog({super.key, required this.videoUrl});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Baixar vídeo'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Escolha o formato:'),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.music_note),
              title: const Text('MP3 (192 kbps)'),
              subtitle: const Text('Somente áudio'),
              onTap: () =>
                  Navigator.of(context)
                      .pop(DownloadRequest(url: videoUrl, isAudio: true)),
            ),
            const Divider(),
            const Text(
              'Vídeo (MP4)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final height in const [360, 480, 720, 1080, 1440, 2160])
                  ActionChip(
                    avatar: const Icon(Icons.movie_outlined, size: 16),
                    label: Text('${height}p'),
                    onPressed: () => Navigator.of(context).pop(
                      DownloadRequest(
                        url: videoUrl,
                        isAudio: false,
                        height: height,
                      ),
                    ),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Melhor'),
                  onPressed: () =>
                      Navigator.of(context)
                          .pop(DownloadRequest(url: videoUrl, isAudio: false)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'A análise e o download continuam na tela Downloads.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tela de Histórico
// ---------------------------------------------------------------------------

class HistoryScreen extends StatefulWidget {
  final void Function(String url) onOpen;
  const HistoryScreen({super.key, required this.onOpen});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<HistoryEntry> get _entries => HistoryStore.instance.entries;

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Limpar histórico?'),
        content: const Text('Todo o histórico de navegação será removido.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Limpar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await HistoryStore.instance.clear();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Histórico'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Limpar histórico',
            onPressed: entries.isEmpty ? null : _confirmClear,
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(child: Text('Nenhuma página visitada ainda.'))
          : ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  leading: const Icon(Icons.public),
                  title: Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${entry.url}\n${_formatTime(entry.time)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remover',
                    onPressed: () {
                      HistoryStore.instance.remove(entry.url);
                      setState(() {});
                    },
                  ),
                  onTap: () => widget.onOpen(entry.url),
                );
              },
            ),
    );
  }

  static String _formatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(time.year, time.month, time.day);
    final hm =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    if (day == today) return 'Hoje, $hm';
    if (day == today.subtract(const Duration(days: 1))) return 'Ontem, $hm';
    return '${time.day.toString().padLeft(2, '0')}/'
        '${time.month.toString().padLeft(2, '0')}/${time.year} $hm';
  }
}

// ---------------------------------------------------------------------------
// Tela de Downloads (progresso em tempo real, estilo Snaptube)
// ---------------------------------------------------------------------------

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<FileSystemEntity> _files = [];
  bool _loadingFiles = true;
  int _activeCount = 0;
  int _finishedCount = 0;

  @override
  void initState() {
    super.initState();
    DownloadManager.instance.addListener(_onManagerChanged);
    final tasks = DownloadManager.instance.tasks;
    _activeCount = tasks.where((t) => t.isActive).length;
    _finishedCount = tasks.where((t) => t.isFinished).length;
    _refreshFiles();
  }

  @override
  void dispose() {
    DownloadManager.instance.removeListener(_onManagerChanged);
    super.dispose();
  }

  void _onManagerChanged() {
    final tasks = DownloadManager.instance.tasks;
    final active = tasks.where((t) => t.isActive).length;
    final finished = tasks.where((t) => t.isFinished).length;
    if ((active == 0 && _activeCount > 0) || finished != _finishedCount) {
      _refreshFiles();
    }
    _activeCount = active;
    _finishedCount = finished;
  }

  Future<void> _refreshFiles() async {
    await AppPaths.ensureFolders();
    final files = <FileSystemEntity>[];
    for (final path in [AppPaths.base, AppPaths.videos, AppPaths.music]) {
      try {
        final dir = Directory(path);
        if (await dir.exists()) {
          await for (final entity in dir.list()) {
            if (entity is! File) continue;
            final name = entity.uri.pathSegments.last;
            if (name.startsWith('.')) continue;
            files.add(entity);
          }
        }
      } catch (_) {
        // Sem permissão de leitura.
      }
    }
    files.sort((a, b) {
      try {
        return b.statSync().modified.compareTo(a.statSync().modified);
      } catch (_) {
        return 0;
      }
    });
    if (!mounted) return;
    setState(() {
      _files = files;
      _loadingFiles = false;
    });
  }

  Future<void> _openFile(String path) async {
    final uri = Uri.file(path);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nenhum app abriu este arquivo.')),
        );
      }
    }
  }

  String _sizeOf(FileSystemEntity file) {
    try {
      return formatBytes((file as File).lengthSync());
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Atualizar arquivos',
            onPressed: _refreshFiles,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Limpar concluídos',
            onPressed: () => DownloadManager.instance.clearFinished(),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: DownloadManager.instance,
        builder: (context, _) {
          final tasks = DownloadManager.instance.tasks;
          final active = tasks.where((t) => t.isActive).toList();
          final finished = tasks.where((t) => t.isFinished).toList();

          if (_loadingFiles) {
            return const Center(child: CircularProgressIndicator());
          }
          if (active.isEmpty && finished.isEmpty && _files.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.download_done, size: 56),
                    SizedBox(height: 16),
                    Text(
                      'Nenhum download ainda.\n'
                      'Navegue e toque em um link para baixar qualquer arquivo.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          final scheme = Theme.of(context).colorScheme;
          return RefreshIndicator(
            onRefresh: _refreshFiles,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 18,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Outros arquivos: ${AppPaths.base}\n'
                          'Vídeos: ${AppPaths.videos}\n'
                          'Músicas: ${AppPaths.music}',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (active.isNotEmpty) ...[
                  _sectionTitle('Em andamento'),
                  for (final task in active) _activeTile(task),
                  const SizedBox(height: 8),
                ],
                if (finished.isNotEmpty) ...[
                  _sectionTitle('Concluídos'),
                  for (final task in finished) _finishedTile(task),
                  const SizedBox(height: 8),
                ],
                if (_files.isNotEmpty) ...[
                  _sectionTitle('Arquivos no dispositivo'),
                  for (final file in _files) _fileTile(file),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _activeTile(DownloadTask task) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              height: 46,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: task.progress,
                    strokeWidth: 3,
                  ),
                  Icon(
                    task.isDirect
                        ? iconForFile(task.fileName ?? task.title)
                        : (task.isAudio
                              ? Icons.music_note
                              : Icons.movie_outlined),
                    size: 20,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    task.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (task.progress != null) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: task.progress,
                        minHeight: 5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancelar',
              onPressed: () => DownloadManager.instance.cancel(task.id),
            ),
          ],
        ),
      ),
    );
  }

  Widget _finishedTile(DownloadTask task) {
    final scheme = Theme.of(context).colorScheme;
    final ok = task.phase == DownloadPhase.completed;
    final canceled = task.phase == DownloadPhase.canceled;
    final icon = canceled
        ? Icons.cancel_outlined
        : ok
        ? (task.isDirect
              ? iconForFile(task.fileName ?? task.title)
              : (task.isAudio ? Icons.music_note : Icons.movie_outlined))
        : Icons.error_outline;
    final subtitle = ok
        ? (task.outputPath ?? 'Concluído')
        : canceled
        ? 'Cancelado'
        : (task.error ?? 'Falhou');

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: ListTile(
        leading: Icon(icon, color: ok ? scheme.primary : scheme.error),
        title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ok && task.outputPath != null)
              IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: 'Abrir',
                onPressed: () => _openFile(task.outputPath!),
              ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Remover da lista',
              onPressed: () => DownloadManager.instance.remove(task.id),
            ),
          ],
        ),
      ),
    );
  }

  String _folderLabel(String path) {
    if (path.startsWith(AppPaths.videos)) return 'Vídeos';
    if (path.startsWith(AppPaths.music)) return 'Músicas';
    return 'Outros';
  }

  Widget _fileTile(FileSystemEntity file) {
    final scheme = Theme.of(context).colorScheme;
    final name = file.uri.pathSegments.last;
    final size = _sizeOf(file);
    final folder = _folderLabel(file.path);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: ListTile(
        leading: Icon(iconForFile(name), color: scheme.primary),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(size.isEmpty ? folder : '$folder • $size'),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () => _openFile(file.path),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tela de Configurações
// ---------------------------------------------------------------------------

class SettingsScreen extends StatefulWidget {
  final ThemeMode mode;
  final Color seed;
  final void Function(ThemeMode, Color) onChanged;

  const SettingsScreen({
    super.key,
    required this.mode,
    required this.seed,
    required this.onChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ThemeMode _mode;
  late Color _seed;

  static const List<Color> _colors = [
    Color(0xFFE53935), // vermelho
    Color(0xFFD81B60), // rosa
    Color(0xFF8E24AA), // roxo
    Color(0xFF5E35B1), // violeta
    Color(0xFF3949AB), // índigo
    Color(0xFF1E88E5), // azul
    Color(0xFF039BE5), // azul-claro
    Color(0xFF00ACC1), // ciano
    Color(0xFF00897B), // verde-azulado
    Color(0xFF43A047), // verde
    Color(0xFF7CB342), // verde-claro
    Color(0xFFC0CA33), // limão
    Color(0xFFFDD835), // amarelo
    Color(0xFFFFB300), // âmbar
    Color(0xFFFB8C00), // laranja
    Color(0xFFF4511E), // laranja-escuro
    Color(0xFF6D4C41), // marrom
    Color(0xFF546E7A), // cinza-azulado
  ];

  @override
  void initState() {
    super.initState();
    _mode = widget.mode;
    _seed = widget.seed;
  }

  void _apply() {
    widget.onChanged(_mode, _seed);
    SettingsStore.mode = _mode;
    SettingsStore.seed = _seed;
    SettingsStore.save();
  }

  Future<void> _openGitHub() async {
    final ok = await launchUrl(
      Uri.parse(kGitHubUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir o link.')),
      );
    }
  }

  Future<void> _setDefaultBrowser() async {
    try {
      await kIntentChannel.invokeMethod('openDefaultBrowserSettings');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível abrir os ajustes do Android.'),
          ),
        );
      }
    }
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Limpar histórico?'),
        content: const Text('Todo o histórico de navegação será removido.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Limpar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await HistoryStore.instance.clear();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Histórico limpo.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Configurações')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const _SectionTitle('Tema'),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.light,
                label: Text('Claro'),
                icon: Icon(Icons.light_mode_outlined),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                label: Text('Escuro'),
                icon: Icon(Icons.dark_mode_outlined),
              ),
              ButtonSegment(
                value: ThemeMode.system,
                label: Text('Sistema'),
                icon: Icon(Icons.brightness_auto_outlined),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (selection) {
              setState(() => _mode = selection.first);
              _apply();
            },
          ),
          const SizedBox(height: 24),
          const _SectionTitle('Cor do navegador'),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final color in _colors)
                GestureDetector(
                  onTap: () {
                    setState(() => _seed = color);
                    _apply();
                  },
                  child: CircleAvatar(
                    backgroundColor: color,
                    radius: 22,
                    child: _seed.toARGB32() == color.toARGB32()
                        ? const Icon(Icons.check, color: Colors.white)
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 28),
          const _SectionTitle('Dados'),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            child: ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('Limpar histórico'),
              subtitle: const Text('Remove todas as páginas visitadas'),
              onTap: _clearHistory,
            ),
          ),
          const SizedBox(height: 28),
          const _SectionTitle('Navegador'),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            child: Column(
              children: [
                if (Platform.isAndroid) ...[
                  ListTile(
                    leading: const Icon(Icons.public),
                    title: const Text('Definir como navegador padrão'),
                    subtitle: const Text(
                      'Abra os ajustes do Android e escolha o TubeFetch',
                    ),
                    trailing: const Icon(Icons.open_in_new, size: 18),
                    onTap: _setDefaultBrowser,
                  ),
                  const Divider(height: 1),
                ],
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('Pastas de downloads'),
                  subtitle: Text(
                    Platform.isIOS
                        ? 'Arquivos → No meu iPhone → TubeFetch'
                        : 'Outros: ${AppPaths.base}\n'
                              'Vídeos: ${AppPaths.videos}\n'
                              'Músicas: ${AppPaths.music}',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const _SectionTitle('Sobre'),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Versão'),
                  subtitle: Text(
                    '$kAppVersion (${Platform.isIOS ? 'iOS' : 'Android'})',
                  ),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.person_outline),
                  title: Text('Desenvolvido por'),
                  subtitle: Text('SysArchX'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('Repositório oficial'),
                  subtitle: const Text('github.com/SysArchX/tubefetch'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: _openGitHub,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    );
  }
}
