# luckfox_lyra — базовый Docker-образ с распакованным Luckfox Lyra SDK

Образ `ubuntu:22.04` + полное дерево исходников Luckfox Lyra SDK (RK3506, Linux 6.1,
SDK версии 250815) в `/opt/luckfox-lyra-sdk`. Без архива и без `.repo` — только
распакованное SDK как отправная точка для сборки собственной прошивки.

## Зачем

Заводская прошивка Luckfox Lyra (128 МБ):

- резервирует часть памяти под камеру/ISP и прочие нужды — поэтому в `htop`
  видно только ~87 МБ из 128 МБ;
- собрана без V4L/UVC — `uvcvideo.ko` со сторонних форумов даёт битый JPEG
  и не даёт управлять настройками камеры, потому что ядро и модуль не согласованы.

Правильный путь — собрать образ самостоятельно из официального SDK.
По инструкции Luckfox для сборки требуется Ubuntu 22.04, поэтому сборка ведётся в Docker.

## Требования

- Docker с BuildKit (docker 20.10+; проверено на 29.x).
  На Ubuntu пакет `docker.io` идёт без BuildKit — нужен пакет `docker-buildx`:
  `sudo apt install docker-buildx`.
  Если после установки `docker buildx version` не работает, добавьте симлинк:
  `mkdir -p ~/.docker/cli-plugins && ln -s /usr/libexec/docker/cli-plugins/docker-buildx ~/.docker/cli-plugins/`
- ~20 ГБ свободного места (контекст 3 ГБ + распаковка + checkout + слои образа).
- Архив SDK `Luckfox_Lyra_SDK_250815.tar.gz` (официальный Google Drive Luckfox).
  sha256: `7d4ec6750d88635d7accc0f69ea9eb0f3c233f979c1cedb32b91709734fadecf`

## Как это работает

Архив SDK — это repo-бандл: внутри только `.repo/` (bare-репозитории всех
проектов + манифест `luckfox_linux6.1_rk3506_release_v1.4_20250620.xml`).
Рабочего дерева исходников в архиве нет — оно восстанавливается **офлайн**
командой `repo sync` (в манифесте `fetch="."`, сеть не нужна).

Нюанс: `repo` в бандле времён Python 2 и не запускается на Python 3.10 из
Ubuntu 22.04 (`No module named 'formatter'`), а системный `repo` 2.x всё равно
re-exec'ит бандловый. Поэтому в стадии `unpack` ставится `python2`, и бандловый
`repo` запускается под ним — родной инструмент для этого бандла.

`Dockerfile` двухстадийный:

1. `unpack`: монтирует архив через bind-mount (архив не попадает ни в один
   слой), распаковывает, выполняет `python2 .repo/repo/repo sync -c -l`,
   удаляет `.repo`.
2. финал: `ubuntu:22.04` + `COPY` готового дерева в `/opt/luckfox-lyra-sdk`.

`.dockerignore` ограничивает build-контекст одним архивом.

## Сборка

Положить архив рядом с Dockerfile (можно хардлинком, чтобы не копировать 3 ГБ):

```bash
ln ~/Downloads/Luckfox_Lyra_SDK_250815.tar.gz .
```

Собрать образ:

```bash
docker build -t <dockerhub_user>/luckfox_lyra:250815 \
             -t <dockerhub_user>/luckfox_lyra:latest \
             .
```

Сборка занимает порядка 10–30 минут в зависимости от машины.

## Проверка

```bash
# дерево проектов на месте, .repo отсутствует
docker run --rm <dockerhub_user>/luckfox_lyra:latest ls -A /opt/luckfox-lyra-sdk
# ожидаются: kernel-6.1, u-boot, buildroot, rkbin, device, external, prebuilts, ...

# в истории слоёв нет архива (слои финального образа — только ubuntu + COPY дерева)
docker history <dockerhub_user>/luckfox_lyra:latest
```

## Публикация в Docker Hub

```bash
docker login
docker push <dockerhub_user>/luckfox_lyra:250815
docker push <dockerhub_user>/luckfox_lyra:latest
```

## Использование

```bash
docker run --rm -it <dockerhub_user>/luckfox_lyra:latest bash
# внутри: /opt/luckfox-lyra-sdk — готовое дерево, ./build.sh и т.д.
```

Зависимости для сборки прошивки (build-essential и прочее по вики Luckfox)
в этот образ намеренно не установлены — это минимальная отправная точка.
Сборочный образ с зависимостями создаётся автоматически рецептом `just setup`
(см. ниже).

## Сборка прошивки (justfile)

`justfile` автоматизирует сборку прошивки из образа. Требуется `just`
(https://just.systems) и доступ к docker (группа `docker`).

Что делает `just build`:

- плата `luckfox_lyra_buildroot_sdmmc_defconfig` (базовая Lyra, microSD, buildroot);
- **включает драйвер USB UVC-камеры**: фрагмент `rk3506-usb-host.config`
  (USB переводится из `=m` в `=y`, DWC2 host, PHY) + новый фрагмент
  `kernel-6.1/arch/arm/configs/rk3506-uvc-camera.config`
  (`CONFIG_MEDIA_USB_SUPPORT`, `CONFIG_VIDEO_DEV`, `CONFIG_VIDEO_V4L2`,
  `CONFIG_USB_VIDEO_CLASS` и пр.);
- **выключает DSI (дисплей)**: добавляется фрагмент
  `kernel-6.1/arch/arm/configs/rk3506-no-display.config`
  (`# CONFIG_DRM is not set`) — DRM включается базовым defconfig, поэтому
  простого удаления `rk3506-display.config` из `RK_KERNEL_CFG_FRAGMENTS`
  недостаточно; плюс ноды `&dsi`, `&dsi_dphy`, `&dsi_in_vop`, `&route_dsi`,
  `&vop` в `kernel-6.1/arch/arm/boot/dts/rk3506g-luckfox-lyra-sd.dts`
  переводятся в `disabled` (display-ноды после этого вообще выпадают из
  итогового dtb как нессылаемые).

Команды:

- `just` — список команд (запуск без аргументов ничего не собирает);
- `just build` — полная сборка (идёт с `nice 19`, чтобы не душить систему);
  итоговые файлы (`update.img`, `boot.img`,
  `rootfs.img`, `MiniLoaderAll.bin`, `parameter.txt`, …) кладутся в текущую
  папку **с заменой**;
- `just setup` — собрать сборочный образ `luckfox_lyra-build:250815`
  (зависимости поверх базового; вызывается из `just build` автоматически);
- `just shell` — интерактивный шелл в сборочном окружении (для отладки);
- `just reset` — удалить volume `luckfox_lyra_sdk` (SDK вернётся к состоянию
  чистого образа, следующая сборка — с нуля).

Нюансы:

- SDK внутри сборки живёт в named volume `luckfox_lyra_sdk`. Это необходимо,
  потому что `check-sdk.sh` отказывается работать на overlayfs (требует
  ext4/f2fs/btrfs), и заодно даёт инкрементальные пересборки и кэш скачанных
  пакетов buildroot. При первом запуске в volume копируется содержимое образа
  (~8 ГБ) — первый старт занимает несколько минут.
- Первая полная сборка — порядка 30–80 минут (buildroot скачивает и собирает
  пакеты). Повторные — значительно быстрее за счёт инкрементальности.
- Модификации (фрагмент камеры, dts) идемпотентны: повторный `just build`
  не дублирует правки.

## Замечания

- `.repo` удалён осознанно: `repo` внутри образа работать не будет
  (для сборки прошивки он не нужен).
- SDK — собственность Rockchip/Luckfox; публикация образа в Docker Hub —
  на ваше усмотрение и под вашу ответственность.
