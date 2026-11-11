# TubeFetch — app Flutter (Android / iOS)

Fonte do aplicativo Flutter do TubeFetch.

- `android/` — configuração e assinatura do APK (a keystore **não** é versionada;
  ela fica em `android/keystore/` apenas na máquina de build).
- `ios/` — projeto iOS (build precisa de macOS + Xcode).
- `.github/workflows/ios-ipa.yml` — gera um `.ipa` **sem assinatura** num runner
  macOS do GitHub Actions (Actions → "iOS (.ipa sem assinatura)" → Run workflow).
- `third_party/flutter_inappwebview_android` — cópia local do plugin Android com
  o patch usado pelo app.

## Build Android

```bash
flutter build apk --release --split-per-abi
```

## Build iOS

Só em macOS com Xcode:

```bash
flutter build ipa --release
```
