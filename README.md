# FastSearchX

**Navegador estilo Chrome + baixador de vídeos (MP4), músicas (MP3) e arquivos — no Android e no Linux.**

<p align="center">
  <img src="data/icons/fastsearchx-256.png" width="160" alt="Ícone do FastSearchX">
</p>

<p align="center">
  <a href="https://github.com/SysArchX/FastSearchX/releases/latest">
    <img alt="Última versão" src="https://img.shields.io/github/v/release/SysArchX/FastSearchX?label=release&color=e53935">
  </a>
  <a href="https://github.com/SysArchX/FastSearchX/releases">
    <img alt="Downloads" src="https://img.shields.io/github/downloads/SysArchX/FastSearchX/total?label=downloads&color=43a047">
  </a>
  <a href="LICENSE">
    <img alt="Licença MIT" src="https://img.shields.io/github/license/SysArchX/FastSearchX?label=licen%C3%A7a&color=blue">
  </a>
  <img alt="Android 7.0+" src="https://img.shields.io/badge/Android-7.0%2B-3ddc84?logo=android&logoColor=white">
  <img alt="Linux x86_64" src="https://img.shields.io/badge/Linux-x86__64-fcc624?logo=linux&logoColor=black">
</p>

O **FastSearchX** é um navegador livre com downloader integrado. Há duas versões:

- **Android** — navegador completo que pode ser definido como navegador padrão,
  baixa **qualquer arquivo** (inclusive links do LocalSend) e detecta vídeos e
  áudios de qualquer site, incluindo transmissões HLS/DASH.
- **Linux (GTK 3)** — navegador com **abas** no estilo Chrome (WebKit2GTK), com
  barra de endereço, pesquisa no Google, downloads e botão para baixar o
  vídeo/áudio da página usando o [yt-dlp](https://github.com/yt-dlp/yt-dlp)
  embutido. O baixador de links e playlists também está no menu.

## Novidades da 2.0.0

- **Novo nome e novo pacote:** o projeto agora é **FastSearchX**
  (`com.sysarchx.fastsearchx`). Desinstale o TubeFetch 1.4.x antes de instalar.
- **Android: corrigido o erro “houve um problema ao analisar o pacote”.**
  A 1.4.1 empacotava as bibliotecas nativas comprimidas e o instalador
  precisava extrair centenas de MB durante a instalação — o que falhava em
  muitos aparelhos. A 2.0.0 voltou ao empacotamento da 1.2.0 (`.so` sem
  compressão, `extractNativeLibs="false"`), que instala direto e ocupa apenas o
  tamanho do APK.
- **Linux agora é um navegador de verdade:** abas, barra de endereço com
  pesquisa, voltar/avançar, recarregar, favoritos de navegação, downloads com
  progresso e menu de contexto para baixar links e mídias.
- **APK universal com `versionCode` maior**, para poder instalá-lo por cima de
  um APK por arquitetura sem desinstalar.
- iOS: transições nativas, barra com efeito “Liquid Glass” e detecção de mídia.

## Downloads

| Plataforma | Versão | Arquivo | Requisitos |
| --- | :---: | --- | --- |
| **Android** | 2.0.0 | [`FastSearchX-2.0.0-arm64-v8a.apk`](https://github.com/SysArchX/FastSearchX/releases/download/v2.0.0/FastSearchX-2.0.0-arm64-v8a.apk) (48,5 MB) | Android 7.0 (API 24)+, celular 64 bits — **recomendado** |
| **Android** | 2.0.0 | [`FastSearchX-2.0.0-armeabi-v7a.apk`](https://github.com/SysArchX/FastSearchX/releases/download/v2.0.0/FastSearchX-2.0.0-armeabi-v7a.apk) (69,4 MB) | Android 7.0+, aparelho 32 bits |
| **Android** | 2.0.0 | [`FastSearchX-2.0.0-android.apk`](https://github.com/SysArchX/FastSearchX/releases/download/v2.0.0/FastSearchX-2.0.0-android.apk) (168 MB) | Android 7.0+, serve em qualquer aparelho |
| **Linux x86_64** | 2.0.0 | [`fastsearchx_2.0.0_amd64.deb`](https://github.com/SysArchX/FastSearchX/releases/download/v2.0.0/fastsearchx_2.0.0_amd64.deb) (2,9 MB) | Debian/Ubuntu com Python 3.11+, GTK 3, WebKit2GTK 4.1 e ffmpeg |
| **iOS** | 2.0.0 | [`FastSearchX-2.0.0-ios-unsigned.ipa`](https://github.com/SysArchX/FastSearchX/releases/download/v2.0.0/FastSearchX-2.0.0-ios-unsigned.ipa) (24 MB) | iOS/iPadOS 15+, **sem assinatura** (reassinar com seu Apple ID) |

Todas as versões ficam na página de **[Releases](../../releases)**.

> O `.ipa` do iOS é gerado pelo workflow do GitHub Actions
> (**Actions → “iOS (.ipa sem assinatura)”**); veja [`app/IOS.md`](app/IOS.md).

> Os três APKs são a **mesma versão 2.0.0**. Os arquivos por arquitetura
> (`arm64-v8a`, `armeabi-v7a`, `x86_64`) têm só as bibliotecas nativas do
> aparelho, então baixam mais rápido. Em dúvida, use o
> `FastSearchX-2.0.0-android.apk`.

### Verificação de integridade

A release atual inclui um arquivo `SHA256SUMS` com os hashes dos artefatos.
Para conferir os downloads:

```bash
wget https://github.com/SysArchX/FastSearchX/releases/download/v2.0.0/SHA256SUMS
sha256sum -c SHA256SUMS
```

## Instalação no Android

1. Baixe o APK no celular — prefira o `FastSearchX-2.0.0-arm64-v8a.apk`.
   Baixe pelo **Chrome** ou por um gerenciador de downloads: navegadores
   internos de apps de mensagem costumam cortar arquivos grandes.
2. Abra o arquivo e permita a instalação de **fontes desconhecidas** para o
   navegador ou gerenciador de arquivos usado.
3. No Android 11 ou superior, conceda a permissão de **acesso a arquivos**
   para que os downloads sejam salvos em `Download/FastSearchX/`.

Se aparecer **“houve um problema ao analisar o pacote”**:

- o download ficou incompleto — baixe de novo e confira o `SHA256SUMS`;
- o aparelho é Android 6.x ou anterior — o FastSearchX exige Android 7.0+;
- há uma versão antiga do TubeFetch instalada — desinstale-a antes (o pacote
  mudou de `com.sysarchx.tubefetch` para `com.sysarchx.fastsearchx`);
- o APK é de outra arquitetura — tente o `FastSearchX-2.0.0-android.apk`.

Também é possível instalar pelo ADB:

```bash
adb install FastSearchX-2.0.0-arm64-v8a.apk
```

O APK é assinado com a chave de release do projeto:

```
CN=SysArchX, OU=FastSearchX, O=SysArchX, C=BR
SHA-256 do certificado: c4ff9e0318a5d17a15ed67d3d2025f7752ea97e06da61201dde5ef44f42565d6
```

> **Atualizando de uma versão anterior:** a 2.0.0 mudou o ID do app para
> `com.sysarchx.fastsearchx`. Desinstale o **TubeFetch** (1.4.1 ou anterior)
> antes de instalar — o histórico e as preferências do app são perdidos, mas os
> arquivos já baixados continuam em `Download/TubeFetch`.
>
> Se você instalou um APK **por arquitetura** e depois quiser trocar para o
> **universal**, a instalação funciona por cima (o universal tem `versionCode`
> maior). O caminho contrário (universal → por arquitetura) exige desinstalar.

## iOS (.ipa)

O FastSearchX também é um app Flutter e roda no iOS: o `.ipa` é gerado por um
workflow do GitHub Actions em runner macOS
(**Actions → “iOS (.ipa sem assinatura)” → Run workflow**).

O arquivo sai **sem assinatura** e precisa ser reassinado com o seu Apple ID
(Sideloadly, AltStore ou Xcode). Passo a passo, limites de validade e diferenças
em relação ao Android: [`app/IOS.md`](app/IOS.md).

## Instalação no Linux (.deb)

Baixe o pacote `.deb` e instale com:

```bash
sudo apt install ./fastsearchx_2.0.0_amd64.deb
```

O `apt` resolve as dependências automaticamente (incluindo o WebKit2GTK).
Depois, procure por **FastSearchX** no menu de aplicativos ou execute:

```bash
fastsearchx
```

O aplicativo abre como navegador. O downloader de vídeos/músicas fica no botão
de download da barra de ferramentas, no menu e no botão direito sobre links e
mídias. Você também pode definir o FastSearchX como **navegador padrão** do
sistema (o `.desktop` registra `x-scheme-handler/http` e `https`).

Para remover:

```bash
sudo apt remove fastsearchx
```

> **Atualizando da versão antiga:** se você instalou o antigo `baixador-yt` ou
> o `tubefetch`, remova-o antes com `sudo apt remove baixador-yt tubefetch`.
> As preferências são migradas automaticamente na primeira execução.

## Recursos

### Android (2.0.0)

- Navegador completo com histórico, downloads e configurações no menu.
- Pode ser definido como **navegador padrão** do Android (links http/https).
- Download de **qualquer arquivo**: APK, ZIP, PDF, documentos, imagens e
  links do **LocalSend** (inclusive HTTPS com certificado local).
- Detecção automática de vídeos do YouTube e de mídia em qualquer site.
- Download em **MP3 (192 kbps)** ou **MP4 de 360p a 4K** no YouTube.
- Download de vídeo/áudio de **qualquer site**: MP4, WEBM, MKV, MP3, M4A,
  além de transmissões **HLS (`.m3u8`)** e **DASH (`.mpd`)** processadas
  pelo FFmpeg.
- Menu **Mídia da página** para escolher o vídeo ou áudio detectado.
- Tela de downloads com **progresso em tempo real**, tamanho, velocidade e
  cancelamento — sem ficar carregando para sempre.
- Pastas organizadas automaticamente:
  - `Download/FastSearchX` — outros arquivos;
  - `Download/FastSearchX/FastSearchX_videos` — vídeos;
  - `Download/FastSearchX/FastSearchX_music` — músicas e áudios.
- Detecção de link copiado na área de transferência.
- Temas claro, escuro ou do sistema, com várias cores de destaque.
- Histórico de navegação e de downloads.

### Linux — GTK 3 + WebKit2GTK (2.0.0)

- **Navegador com abas** estilo Chrome: barra de endereço, voltar/avançar,
  recarregar, página inicial, barra de progresso e atalhos
  (`Ctrl+T`, `Ctrl+W`, `Ctrl+L`, `Ctrl+R`, `Ctrl+J`, `Ctrl+Q`, `F5`,
  `Alt+←/→`, `Ctrl+ +/−/0`).
- Pesquisa no Google direto na barra de endereço.
- **Downloads integrados** com barra de progresso, cancelamento e notificação
  (salvos em `~/Downloads`).
- Menu de contexto (botão direito) para **abrir link em nova aba** e
  **baixar link/mídia/imagem com o FastSearchX**.
- Botão **Baixar vídeo/áudio desta página** para enviar a URL atual ao yt-dlp.
- Download de vídeo em MP4 ou áudio em MP3.
- Escolha de qualidade (melhor disponível, 1080p, 720p, 480p, 360p; ou
  320/192/128 kbps no MP3).
- Suporte a playlists completas ou apenas itens selecionados (ex.: `1-10, 15`).
- Barra de progresso com velocidade, tempo restante e item atual da playlist.
- Cancelamento do download.
- Escolha da pasta de destino e incorporação de metadados.
- yt-dlp **embutido em versão recente** e opção de atualizá-lo pelo menu.
- QuickJS-ng embutido para resolver os desafios JavaScript do YouTube.
- Notificação ao concluir.
- Preferências salvas entre execuções (migradas do TubeFetch).

## Requisitos (Linux)

- Python 3.11 ou superior
- PyGObject (`python3-gi`), GTK 3 (`gir1.2-gtk-3.0`) e
  WebKit2GTK 4.1 (`gir1.2-webkit2-4.1`)
- `ffmpeg` (para juntar vídeo + áudio e converter para MP3)

Em distribuições baseadas em Debian/Ubuntu:

```bash
sudo apt install python3 python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1 ffmpeg
```

## Executar sem instalar (Linux)

Basta ter as dependências do sistema instaladas. Na primeira execução, o
`run.sh` baixa automaticamente o yt-dlp e o QuickJS-ng para `vendor/` e
`data/bin/`:

```bash
git clone https://github.com/SysArchX/FastSearchX.git
cd FastSearchX
./run.sh
```

Se preferir baixar as dependências antes:

```bash
./packaging/fetch-deps.sh
```

## Construir o .deb

```bash
./packaging/build-deb.sh
```

O script:

1. baixa o yt-dlp e o QuickJS-ng, se ainda não estiverem presentes;
2. monta a estrutura do pacote e gera
   `dist/fastsearchx_<versão>_<arquitetura>.deb`.

## Estrutura

```
FastSearchX/
├── src/fastsearchx/
│   ├── browser.py        # navegador com abas (WebKit2GTK)
│   ├── downloader.py     # integração com o yt-dlp
│   ├── window.py         # janela do downloader (GTK3)
│   ├── ytdlp_loader.py   # seleção do yt-dlp/QuickJS
│   └── main.py           # ponto de entrada
├── data/
│   ├── com.lazlabs.FastSearchX.desktop
│   ├── fastsearchx.svg
│   ├── bin/qjs           # QuickJS-ng (baixado por fetch-deps.sh)
│   └── icons/
├── vendor/               # yt-dlp embutido (baixado por fetch-deps.sh)
├── packaging/
│   ├── build-deb.sh
│   ├── fetch-deps.sh
│   └── make_icons.py
├── run.sh
└── dist/                 # pacotes gerados (ignorado pelo git)
```

## Atualizar o yt-dlp

No menu do aplicativo Linux, escolha **Atualizar yt-dlp**. A versão nova é
instalada em `~/.local/share/fastsearchx/vendor` e passa a ter prioridade sobre
a versão embutida. Reinicie o aplicativo quando solicitado.

## Observações

- É necessário `ffmpeg` para juntar vídeo + áudio e para converter MP3 no
  aplicativo Linux. No Android, a conversão é feita pelo FFmpeg embutido.
- A primeira resolução de desafios do YouTube pode baixar um pequeno script
  auxiliar do projeto EJS, que fica em cache para as próximas execuções.
- O aplicativo não é afiliado ao YouTube. Respeite os termos de uso e os
  direitos autorais do conteúdo baixado.

## Licença

O código deste aplicativo é distribuído sob a licença [MIT](LICENSE). O yt-dlp
é distribuído sob a licença Unlicense e o QuickJS-ng sob a licença MIT.
