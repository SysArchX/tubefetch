# TubeFetch

**Baixe vídeos (MP4) e músicas (MP3) do YouTube e de qualquer site, além de qualquer arquivo — no Android e no Linux.**

<p align="center">
  <img src="data/icons/tubefetch-256.png" width="160" alt="Ícone do TubeFetch">
</p>

<p align="center">
  <a href="https://github.com/SysArchX/tubefetch/releases/latest">
    <img alt="Última versão" src="https://img.shields.io/github/v/release/SysArchX/tubefetch?label=release&color=e53935">
  </a>
  <a href="https://github.com/SysArchX/tubefetch/releases">
    <img alt="Downloads" src="https://img.shields.io/github/downloads/SysArchX/tubefetch/total?label=downloads&color=43a047">
  </a>
  <a href="LICENSE">
    <img alt="Licença MIT" src="https://img.shields.io/github/license/SysArchX/tubefetch?label=licen%C3%A7a&color=blue">
  </a>
  <img alt="Android 7.0+" src="https://img.shields.io/badge/Android-7.0%2B-3ddc84?logo=android&logoColor=white">
  <img alt="Linux x86_64" src="https://img.shields.io/badge/Linux-x86__64-fcc624?logo=linux&logoColor=black">
</p>

O **TubeFetch** é um aplicativo livre para baixar vídeos, músicas e arquivos.
Há duas versões:

- **Android** — navegador completo que pode ser definido como navegador padrão,
  baixa **qualquer arquivo** (inclusive links do LocalSend) e detecta vídeos e
  áudios de qualquer site, incluindo transmissões HLS/DASH.
- **Linux (GTK 3)** — interface simples para baixar de links e playlists
  completas usando o [yt-dlp](https://github.com/yt-dlp/yt-dlp) embutido.

## Downloads

| Plataforma | Versão | Arquivo | Requisitos |
| --- | :---: | --- | --- |
| **Android** | 1.3.0 | [`TubeFetch-1.3.0-android.apk`](https://github.com/SysArchX/tubefetch/releases/download/v1.3.0/TubeFetch-1.3.0-android.apk) | Android 7.0 (API 24) ou superior |
| **Linux x86_64** | 1.1.0 | [`tubefetch_1.1.0_amd64.deb`](https://github.com/SysArchX/tubefetch/releases/download/v1.3.0/tubefetch_1.1.0_amd64.deb) | Debian/Ubuntu com Python 3.11+, GTK 3 e ffmpeg |

Todas as versões ficam na página de **[Releases](../../releases)**.

### Verificação de integridade

A release atual inclui um arquivo `SHA256SUMS` com os hashes dos artefatos.
Para conferir os downloads:

```bash
wget https://github.com/SysArchX/tubefetch/releases/download/v1.3.0/SHA256SUMS
sha256sum -c SHA256SUMS
```

## Instalação no Android

1. Baixe o `TubeFetch-1.3.0-android.apk` no celular.
2. Abra o arquivo e permita a instalação de **fontes desconhecidas** para o
   navegador ou gerenciador de arquivos usado.
3. No Android 11 ou superior, conceda a permissão de **acesso a arquivos**
   para que os downloads sejam salvos em `Download/TubeFetch/`.

Também é possível instalar pelo ADB:

```bash
adb install TubeFetch-1.3.0-android.apk
```

O APK é assinado com a chave de release do projeto:

```
CN=SysArchX, OU=TubeFetch, O=SysArchX, C=BR
SHA-256 do certificado: c4ff9e0318a5d17a15ed67d3d2025f7752ea97e06da61201dde5ef44f42565d6
```

> **Atualizando de uma versão anterior:** o APK 1.0.0 usava uma assinatura de
> depuração diferente. Se ele estiver instalado, desinstale-o antes de instalar
> esta versão. As versões 1.2.0 e 1.3.0 usam a mesma chave e podem ser
> atualizadas normalmente.


## Instalação no Linux (.deb)

Baixe o pacote `.deb` e instale com:

```bash
sudo apt install ./tubefetch_1.1.0_amd64.deb
```

O `apt` resolve as dependências automaticamente. Depois, procure por
**TubeFetch** no menu de aplicativos ou execute:

```bash
tubefetch
```

Para remover:

```bash
sudo apt remove tubefetch
```

> **Atualizando da versão antiga:** se você instalou o antigo `baixador-yt`,
> remova-o antes com `sudo apt remove baixador-yt`. As preferências são
> migradas automaticamente na primeira execução.

## Recursos

### Android (1.3.0)

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
  - `Download/TubeFetch` — outros arquivos;
  - `Download/TubeFetch/TubeFetch_videos` — vídeos;
  - `Download/TubeFetch/TubeFetch_music` — músicas e áudios.
- Detecção de link copiado na área de transferência.
- Temas claro, escuro ou do sistema, com várias cores de destaque.
- Histórico de navegação e de downloads.

### Linux — GTK 3 (1.1.0)

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
- Preferências salvas entre execuções.

## Requisitos (Linux)

- Python 3.11 ou superior
- PyGObject (`python3-gi`) e GTK 3 (`gir1.2-gtk-3.0`)
- `ffmpeg` (para juntar vídeo + áudio e converter para MP3)

Em distribuições baseadas em Debian/Ubuntu:

```bash
sudo apt install python3 python3-gi gir1.2-gtk-3.0 ffmpeg
```

## Executar sem instalar (Linux)

Basta ter as dependências do sistema instaladas. Na primeira execução, o
`run.sh` baixa automaticamente o yt-dlp e o QuickJS-ng para `vendor/` e
`data/bin/`:

```bash
git clone https://github.com/SysArchX/tubefetch.git
cd tubefetch
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
   `dist/tubefetch_<versão>_<arquitetura>.deb`.

## Estrutura

```
tubefetch/
├── src/tubefetch/
│   ├── downloader.py     # integração com o yt-dlp
│   ├── window.py         # interface GTK3
│   ├── ytdlp_loader.py   # seleção do yt-dlp/QuickJS
│   └── main.py           # ponto de entrada
├── data/
│   ├── com.lazlabs.TubeFetch.desktop
│   ├── tubefetch.svg
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
instalada em `~/.local/share/tubefetch/vendor` e passa a ter prioridade sobre
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
