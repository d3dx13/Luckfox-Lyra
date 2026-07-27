# Сборка прошивки Luckfox Lyra (RK3506G, 128 МБ) в Docker.
# Базовый образ: d3dx13/luckfox_lyra (Ubuntu 22.04 + распакованное SDK 250815).
#
#   - плата: luckfox_lyra_buildroot_sdmmc_defconfig (базовая Lyra, microSD, buildroot)
#   - включается драйвер USB UVC-камеры (V4L2, uvcvideo)
#   - выключается DSI (дисплей): и в конфиге ядра, и в dts
#
# Итоговые файлы прошивки (update.img, boot.img, rootfs.img, ...) кладутся
# в текущую папку с заменой.
#
# Использование:
#   just         — список команд (по умолчанию)
#   just build   — полная сборка (первый раз долго: ~30–80 минут, nice 19)
#   just setup   — только собрать образ с зависимостями (вызовется из build сам)
#   just shell   — интерактивный шелл в сборочном окружении
#   just reset   — удалить volume с SDK (вернуться к состоянию чистого образа)
#
# SDK внутри сборки живёт в named volume luckfox_lyra_sdk: во-первых, check-sdk.sh
# требует ext4 (в образе — overlayfs), во-вторых, это даёт инкрементальные
# пересборки и кэш скачанных пакетов buildroot между запусками.

# Внимание: на Docker Hub опубликован только тег :latest (тега :250815 там нет).
base_image  := "d3dx13/luckfox_lyra:latest"
build_image := "luckfox_lyra-build:250815"
sdk_dir     := "/opt/luckfox-lyra-sdk"
sdk_volume  := "luckfox_lyra_sdk"
board       := "luckfox_lyra_buildroot_sdmmc_defconfig"
dts         := "rk3506g-luckfox-lyra-sd.dts"
# ssh-алиас платы (из ~/.ssh/config) — используется рецептом update
device      := "lyra"

# по умолчанию — список рецептов
default:
    @just --list --unsorted

# Образ с зависимостями для сборки (поверх базового SDK-образа)
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    sg docker -c 'docker build -t {{build_image}} -' <<'EOF'
    FROM {{base_image}}
    ENV DEBIAN_FRONTEND=noninteractive
    RUN apt-get update && apt-get install -y --no-install-recommends \
            build-essential git make expect gawk gperf texinfo flex bison \
            libncurses-dev zlib1g-dev libssl-dev bc device-tree-compiler \
            u-boot-tools lz4 genext2fs rsync unzip cpio wget curl file patch \
            perl python3 python-is-python3 python2 xz-utils kmod mtools parted \
            libudev-dev libusb-1.0-0-dev autoconf automake libtool intltool m4 swig \
            libgmp-dev libmpc-dev openssh-client fakeroot zstd bsdextrautils \
     && rm -rf /var/lib/apt/lists/*
    CMD ["/bin/bash"]
    EOF

# Полная сборка: модификации + build.sh + выгрузка результата в текущую папку
build: setup
    #!/usr/bin/env bash
    set -euo pipefail
    sg docker -c "docker run --rm -i \
        -v {{sdk_volume}}:{{sdk_dir}} \
        -v {{justfile_directory()}}:/out \
        -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
        {{build_image}} bash -s" <<'SDK_EOF'
    set -euo pipefail
    # Сборка с минимальным приоритетом CPU, чтобы не душить остальную систему
    renice -n 19 $$ >/dev/null 2>&1 || true
    cd {{sdk_dir}}

    BOARD_CFG=device/rockchip/rk3506/{{board}}
    BRCFG=buildroot/configs/rockchip_rk3506_luckfox_defconfig
    FRAG=kernel-6.1/arch/arm/configs/rk3506-uvc-camera.config
    FRAG_NODISP=kernel-6.1/arch/arm/configs/rk3506-no-display.config
    FRAG_DR=kernel-6.1/arch/arm/configs/rk3506-usb-dualrole.config
    DTS=kernel-6.1/arch/arm/boot/dts/{{dts}}

    # --- 1. Драйвер USB-камеры (UVC/V4L2) ---
    # В базовом defconfig CONFIG_USB=m, при котором MEDIA_USB_SUPPORT недоступен,
    # поэтому фрагмент rk3506-usb-host.config переводит USB в =y и добавляет
    # DWC2 host + PHY; наш фрагмент добавляет V4L2 и uvcvideo.
    cat > "$FRAG" <<'EOF'
    # USB camera (UVC) support for Luckfox Lyra
    CONFIG_MEDIA_USB_SUPPORT=y
    CONFIG_MEDIA_CAMERA_SUPPORT=y
    CONFIG_VIDEO_DEV=y
    CONFIG_VIDEO_V4L2=y
    CONFIG_USB_VIDEO_CLASS=y
    CONFIG_USB_VIDEO_CLASS_INPUT_EVDEV=y
    EOF

    # --- 1b. USB dual-role: гаджет (RNDIS+ADB) на USB-C и host для камеры ---
    # rk3506-usb-host.config ставит DWC2_HOST=y (host-only), из-за чего на
    # порту USB-C (otg0, dr_mode="peripheral") не работает USB-гаджет и плата
    # не появляется в lsusb/ncm/adb на ПК. На RK3506 оба порта — DWC2, поэтому
    # переводим драйвер в dual-role: otg0 (peripheral, USB-C) поднимает
    # RNDIS+ADB, otg1 (host, MX1.25 4P) обслуживает камеру. Гаджет собираем
    # встроенным (=y), чтобы не зависеть от загрузки модулей.
    cat > "$FRAG_DR" <<'EOF'
    # USB gadget (RNDIS+ADB) on USB-C + host for camera on second port
    CONFIG_USB_GADGET=y
    CONFIG_USB_DWC2_DUAL_ROLE=y
    CONFIG_USB_CONFIGFS=y
    CONFIG_USB_CONFIGFS_RNDIS=y
    CONFIG_USB_CONFIGFS_F_FS=y
    CONFIG_USB_F_RNDIS=y
    CONFIG_USB_F_FS=y
    EOF

    # --- 2. Выключение DSI (дисплея) ---
    # DRM включается базовым defconfig (а не только фрагментом rk3506-display.config),
    # поэтому отключаем его отдельным фрагментом — драйверов дисплея в ядре не будет.
    cat > "$FRAG_NODISP" <<'EOF'
    # No display/DSI on this board
    # CONFIG_DRM is not set
    EOF
    sed -i 's|^RK_KERNEL_CFG_FRAGMENTS=.*|RK_KERNEL_CFG_FRAGMENTS="rk3506-usb-host.config rk3506-usb-dualrole.config rk3506-uvc-camera.config rk3506-no-display.config"|' "$BOARD_CFG"
    # Плюс гасим display-ноды в dts (переопределение в конце файла перекрывает
    # ранние "okay") — надёжность на случай, если драйверы всё же окажутся в ядре.
    grep -q 'DSI disabled by justfile' "$DTS" || cat >> "$DTS" <<'EOF'

    /* DSI disabled by justfile */
    &dsi {
    	status = "disabled";
    };

    &dsi_dphy {
    	status = "disabled";
    };

    &dsi_in_vop {
    	status = "disabled";
    };

    &route_dsi {
    	status = "disabled";
    };
    EOF
    grep -q 'VOP disabled by justfile' "$DTS" || cat >> "$DTS" <<'EOF'

    /* VOP disabled by justfile */
    &vop {
    	status = "disabled";
    };
    EOF

    # --- 3. Сеть: отключение ложной проверки и замена зеркала GNU ---
    # check-network.sh шлёт HEAD на sources.buildroot.net и ждёт 1xx-3xx, но
    # Cloudflare отвечает 403; при этом реальное скачивание пакетов работает.
    grep -q 'RK_NETWORK_CHECK' "$BOARD_CFG" || \
      echo '# RK_NETWORK_CHECK is not set' >> "$BOARD_CFG"
    # USTC-зеркало GNU отдаёт 403 для wget; ftp.gnu.org работает нормально.
    sed -i 's|^BR2_GNU_MIRROR=.*|BR2_GNU_MIRROR="https://ftp.gnu.org/gnu"|' \
      buildroot/configs/rockchip/base/common.config

    # --- 3b. htop в rootfs ---
    grep -q '^BR2_PACKAGE_HTOP=y' "$BRCFG" || \
      echo 'BR2_PACKAGE_HTOP=y' >> "$BRCFG"

    # --- 3c. UART1 на пинах RM_IO30 (TX) / RM_IO31 (RX) через /etc/luckfox.cfg ---
    # При загрузке luckfox-config load (S99luckfoxconfigload) читает эти ключи
    # и накладывает runtime-dtbo: включает uart1 и роутит его на пины
    # GPIO1_D2 (TX) / GPIO1_D3 (RX). Upsert по ключам, другие настройки
    # в файле сохраняются.
    CFG_OVR=device/rockchip/common/overlays/rootfs/luckfox-lyra/etc/luckfox.cfg
    touch "$CFG_OVR"
    # TP/I2C2-ключи — слепок текущего /etc/luckfox.cfg с реальной платы,
    # чтобы прошивка не затирала эти настройки.
    for kv in UART1_STATUS=1 UART1_RX_RM_IO=31 UART1_TX_RM_IO=30 \
              TP_STATUS=1 I2C2_STATUS=1 I2C2_SCL_RM_IO=1 I2C2_SDA_RM_IO=0; do
      key="${kv%%=*}"
      if grep -q "^$key=" "$CFG_OVR"; then
        sed -i "s|^$key=.*|$kv|" "$CFG_OVR"
      else
        echo "$kv" >> "$CFG_OVR"
      fi
    done

    # --- 4. Сборка (выбор платы неинтерактивно, затем полная сборка) ---
    ./build.sh {{board}}
    ./build.sh

    # --- 5. Проверка результата и выгрузка в /out (текущая папка на хосте) ---
    # build.sh может вернуть 0 даже при провале этапа — проверяем update.img явно.
    SRC=rockdev
    [ -e rockdev ] || SRC=output/firmware
    [ -f "$SRC/update.img" ] || { echo "ERROR: update.img не собран — сборка провалилась, смотри лог выше"; exit 1; }
    cp -rfL "$SRC/." /out/
    chown -R "$HOST_UID:$HOST_GID" /out
    echo "=== Firmware files are ready: ==="
    ls -lh /out
    SDK_EOF

# Собрать прошивку и залить её на устройство: сначала выполняется build
# (все модификации + сборка), затем плата переводится в loader mode по ssh
# (кнопка BOOT не нужна) и свежий update.img шьётся через upgrade_tool.
update: build
    #!/usr/bin/env bash
    set -euo pipefail
    IMG={{justfile_directory()}}/update.img
    TOOL={{justfile_directory()}}/upgrade_tool
    [ -f "$IMG" ] || { echo "ERROR: $IMG не найден"; exit 1; }

    # --- 1. Перевод платы в download mode (если она ещё не там) ---
    # reboot(LINUX_REBOOT_CMD_RESTART2, "loader") — то же, что `reboot loader`
    # на Rockchip; busybox reboot так не умеет, поэтому syscall через python.
    if ! lsusb | grep -q '2207:350f'; then
      echo ">> Перевожу {{device}} в loader mode по ssh..."
      ssh -o BatchMode=yes -o ConnectTimeout=10 {{device}} \
        'python3 -c "import ctypes; libc=ctypes.CDLL(None,use_errno=True); libc.syscall(88, 0xfee1dead, 672274793, 0xa1b2c3d4, ctypes.c_char_p(b"loader"))"' \
        || echo ">> ssh недоступен; если плата не перейдёт в download mode — зажмите BOOT при подаче питания"
    fi

    # --- 2. Ожидание download-гаджета ---
    echo ">> Жду устройство в download mode (2207:350f)..."
    for i in $(seq 1 45); do
      lsusb | grep -q '2207:350f' && break
      sleep 1
    done
    lsusb | grep -q '2207:350f' \
      || { echo "ERROR: плата не появилась как 2207:350f — зажмите BOOT при подаче питания и повторите"; exit 1; }

    # --- 3. Прошивка ---
    # upgrade_tool — статический бинарник: при недоступном sudo -n шьётся
    # через privileged docker (root, доступ к /dev/bus/usb), пароль не нужен.
    if sudo -n true 2>/dev/null; then
      sudo -n "$TOOL" uf "$IMG"
    elif sg docker -c 'docker info' >/dev/null 2>&1; then
      echo ">> sudo без пароля недоступен — шью через privileged docker"
      sg docker -c "docker run --rm --privileged \
          -v /dev/bus/usb:/dev/bus/usb \
          -v {{justfile_directory()}}:/out \
          {{build_image}} /out/upgrade_tool uf /out/update.img"
    else
      sudo "$TOOL" uf "$IMG"
    fi
    echo ">> Прошивка завершена; плата перезагрузится сама."

# Интерактивный шелл в сборочном окружении (для отладки)
shell:
    sg docker -c 'docker run --rm -it -v {{sdk_volume}}:{{sdk_dir}} -v {{justfile_directory()}}:/out {{build_image}} bash'
# Удалить volume с SDK (следующая сборка начнётся с состояния чистого образа)
reset:
    sg docker -c 'docker volume rm {{sdk_volume}}'
