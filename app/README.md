# FastSearchX — app Flutter (Android/iOS)

Código-fonte do aplicativo móvel do **FastSearchX**: navegador completo com
detecção de mídia e downloader (MP3/MP4) usando FFmpeg e yt-dlp via API.

- Android: navegador + downloads em `Download/FastSearchX/`, pode ser definido
  como navegador padrão (`http`/`https`).
- iOS: WKWebView com detecção de vídeo/áudio e downloader; veja
  [`IOS.md`](IOS.md) para gerar o `.ipa` sem assinatura.

## Desenvolvimento

```bash
flutter pub get
flutter run
```

## Build Android (assinado)

Coloque o keystore em `android/keystore/` e crie `android/key.properties`
(ambos ignorados pelo git):

```properties
storePassword=...
keyPassword=...
keyAlias=tubefetch
storeFile=keystore/fastsearchx-release.jks
```

```bash
flutter build apk --release --split-per-abi   # APKs por arquitetura
flutter build apk --release                   # APK universal
```

O `android/app/build.gradle.kts` empacota as bibliotecas nativas **sem
compressão** (`useLegacyPackaging = false`). Isso é proposital: com as `.so`
comprimidas o instalador precisa extrair centenas de MB e muitos aparelhos
mostram *“houve um problema ao analisar o pacote”*.

## iOS

```bash
flutter build ios --release --no-codesign
```

O workflow do GitHub Actions em `.github/workflows/ios-ipa.yml` gera o `.ipa`
sem assinatura.
