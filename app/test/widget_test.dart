// Smoke tests do TubeFetch: validam constantes e utilitários de download
// sem instanciar o WebView (que exige plataforma nativa).

import 'package:flutter_test/flutter_test.dart';
import 'package:tubefetch_app/main.dart';

void main() {
  test('TubeFetch: pastas de download e créditos', () {
    expect(AppPaths.base, '/storage/emulated/0/Download/TubeFetch');
    expect(AppPaths.videos, '${AppPaths.base}/TubeFetch_videos');
    expect(AppPaths.music, '${AppPaths.base}/TubeFetch_music');
    expect(kGitHubUrl, 'https://github.com/SysArchX/tubefetch');
    expect(kHomeUrl, 'https://www.google.com');
    expect(kAppVersion, '1.3.0');
  });

  test('separa vídeo, áudio e arquivos comuns em pastas diferentes', () {
    expect(AppPaths.folderFor(isVideo: true, isAudio: false), AppPaths.videos);
    expect(AppPaths.folderFor(isVideo: false, isAudio: true), AppPaths.music);
    expect(AppPaths.folderFor(isVideo: false, isAudio: false), AppPaths.base);
    expect(AppPaths.folderForName('filme.mp4'), AppPaths.videos);
    expect(AppPaths.folderForName('musica.mp3'), AppPaths.music);
    expect(AppPaths.folderForName('documento.pdf'), AppPaths.base);
  });

  test('reconhece mídia e transmissões HLS/DASH', () {
    expect(isMediaUrl('https://exemplo.com/video.mp4'), isTrue);
    expect(isMediaUrl('https://exemplo.com/musica.mp3'), isTrue);
    expect(isMediaUrl('https://exemplo.com/playlist.m3u8'), isTrue);
    expect(isMediaUrl('https://exemplo.com/manifest.mpd'), isTrue);
    expect(isMediaUrl('https://exemplo.com/arquivo.zip'), isFalse);
    expect(isStreamingMediaUrl('https://exemplo.com/live.m3u8'), isTrue);
    expect(isStreamingMediaUrl('https://exemplo.com/video.mp4'), isFalse);
  });

  test('detecta links que devem ser baixados', () {
    expect(looksLikeDownloadUrl('https://exemplo.com/arquivo.zip'), isTrue);
    expect(looksLikeDownloadUrl('https://exemplo.com/foto.JPG'), isTrue);
    expect(looksLikeDownloadUrl('https://youtube.com/watch?v=abc123'), isFalse);
    expect(looksLikeDownloadUrl('https://exemplo.com/pagina'), isFalse);
  });

  test('extrai nome do arquivo do Content-Disposition', () {
    expect(
      fileNameFromDisposition('attachment; filename="foto.jpg"'),
      'foto.jpg',
    );
    expect(
      fileNameFromDisposition("attachment; filename*=UTF-8''meu%20video.mp4"),
      'meu video.mp4',
    );
    expect(fileNameFromDisposition(null), isNull);
  });

  test('infere extensão pelo tipo MIME', () {
    expect(extensionForMime('video/mp4'), 'mp4');
    expect(extensionForMime('audio/mpeg; charset=binary'), 'mp3');
    expect(extensionForMime('application/pdf'), 'pdf');
    expect(extensionForMime('desconhecido/x'), isNull);
  });

  test('sanitiza e formata nomes', () {
    expect(sanitizeFileName('a/b:c*?.zip'), 'a_b_c__.zip');
    expect(sanitizeFileName('   '), 'arquivo');
    expect(formatBytes(1024), '1.0 KB');
  });
}
