# FastSearchX no iOS (.ipa)

O `.ipa` é gerado num runner **macOS** do GitHub Actions, porque o build de iOS
só existe com Xcode (não há como compilar iOS no Linux nem "converter" o APK).

## Gerar o .ipa

1. Abra **Actions → “iOS (.ipa sem assinatura)” → Run workflow**.
2. Espere ~20–40 min (o pod do FFmpeg baixa ~49 MB de frameworks).
3. Baixe o artefato **`FastSearchX-ios-unsigned-ipa`** no fim da página da execução.

O artefato traz `FastSearchX-<versao>-ios-unsigned.ipa` e o `.sha256`.
Ele sai **sem assinatura** — a Apple só instala app assinado por um Apple ID.

## Instalar no iPhone

| Ferramenta | Onde roda | Conta | Validade do app |
| --- | --- | --- | --- |
| [Sideloadly](https://sideloadly.io) | Windows/macOS | Apple ID grátis | 7 dias (renovar) |
| [AltStore](https://altstore.io) + AltServer | Windows/macOS | Apple ID grátis | 7 dias (renova sozinho com o AltServer ligado) |
| Xcode → *Window → Devices and Simulators* → “+” | macOS | Apple ID grátis | 7 dias |
| TestFlight / Ad Hoc | macOS | Apple Developer **pago** (US$ 99/ano) | 90 dias / 1 ano |

Primeira instalação: no iPhone, **Ajustes → Geral → VPN e Gerenciamento de
Dispositivo → confiar no desenvolvedor**.

## Build local (se você tiver um Mac)

```bash
cd app
flutter pub get
cd ios && pod install && cd ..
flutter build ipa --release      # assinado, precisa de conta Apple
flutter build ios --release --no-codesign   # sem assinatura, para reassinar
```

## O que muda no iOS em relação ao Android

- **Downloads** vão para `Documents/FastSearchX` dentro do sandbox e aparecem no
  app **Arquivos** em *No meu iPhone → FastSearchX* (ligado por
  `UIFileSharingEnabled` no `Info.plist`).
- **Navegador padrão** não pode ser registrado por app no iOS; o item
  correspondente nas configurações só aparece no Android.
- As pastas `Download/FastSearchX*` da memória compartilhada do Android não
  existem no iOS (`MANAGE_EXTERNAL_STORAGE` é exclusivo do Android).
- HTTP simples é liberado por `NSAppTransportSecurity` (equivalente ao
  `usesCleartextTraffic` do Android).

## Limitações conhecidas do iOS

- App Store: um app que baixa vídeos de “qualquer site” provavelmente é
  rejeitado na revisão. Para uso pessoal, use sideload/TestFlight.
- Sem conta paga, o app expira a cada 7 dias e o limite é de 3 apps por Apple ID.
