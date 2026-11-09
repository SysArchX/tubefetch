# TubeFetch

Interface gráfica simples, em português, para baixar **vídeos (MP4)** e
**músicas (MP3)** de links e playlists do YouTube, usando
[yt-dlp](https://github.com/yt-dlp/yt-dlp).

<p align="center">
  <img src="data/icons/tubefetch-256.png" width="160" alt="Ícone do TubeFetch">
</p>

## Recursos

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

## Requisitos

- Python 3.11 ou superior
- PyGObject (`python3-gi`) e GTK 3 (`gir1.2-gtk-3.0`)
- `ffmpeg` (para juntar vídeo + áudio e converter para MP3)

Em distribuições baseadas em Debian/Ubuntu:

```bash
sudo apt install python3 python3-gi gir1.2-gtk-3.0 ffmpeg
```

## Instalação (.deb)

Baixe o pacote mais recente na página de
[releases](../../releases) e instale com:

```bash
sudo apt install ./tubefetch_1.1.0_amd64.deb
```

O `apt` instala automaticamente as dependências. Depois, procure por
**TubeFetch** no menu de aplicativos ou execute:

```bash
tubefetch
```

Para remover:

```bash
sudo apt remove tubefetch
```

> **Atualizando da versão antiga:** se você instalou o antigo
> `baixador-yt`, remova-o antes com `sudo apt remove baixador-yt`.

## Downloads

Baixe os artefatos construídos para este projeto.

### Android

O APK do aplicativo Android está disponível na página de
[releases](../../releases):

- [TubeFetch-1.0.0-android.apk](../../releases/download/v1.1.0/TubeFetch-1.0.0-android.apk)

Ele pode ser instalado em dispositivos Android com:

```bash
adb install TubeFetch-1.0.0-android.apk
```

ou transferido diretamente para o celular e aberto como APK desconhecido.

### Linux

O pacote `.deb` para Linux x86_64 está em:

- [tubefetch_1.1.0_amd64.deb](../../releases/download/v1.1.0/tubefetch_1.1.0_amd64.deb)

## Executar sem instalar

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

No menu do aplicativo, escolha **Atualizar yt-dlp**. A versão nova é instalada
em `~/.local/share/tubefetch/vendor` e passa a ter prioridade sobre a versão
embutida. Reinicie o aplicativo quando solicitado.

## Observações

- É necessário `ffmpeg` para juntar vídeo e áudio e para converter MP3.
- A primeira resolução de desafios do YouTube pode baixar um pequeno script
  auxiliar do projeto EJS, que fica em cache para as próximas execuções.
- O aplicativo não é afiliado ao YouTube. Respeite os termos de uso e os
  direitos autorais do conteúdo baixado.

## Licença

O código deste aplicativo é distribuído sob a licença [MIT](LICENSE). O yt-dlp
é distribuído sob a licença Unlicense e o QuickJS-ng sob a licença MIT.
