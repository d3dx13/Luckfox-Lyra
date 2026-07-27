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
    FRAG=kernel-6.1/arch/arm/configs/rk3506-uvc-camera.config
    FRAG_NODISP=kernel-6.1/arch/arm/configs/rk3506-no-display.config
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

    # --- 2. Выключение DSI (дисплея) ---
    # DRM включается базовым defconfig (а не только фрагментом rk3506-display.config),
    # поэтому отключаем его отдельным фрагментом — драйверов дисплея в ядре не будет.
    cat > "$FRAG_NODISP" <<'EOF'
    # No display/DSI on this board
    # CONFIG_DRM is not set
    EOF
    sed -i 's|^RK_KERNEL_CFG_FRAGMENTS=.*|RK_KERNEL_CFG_FRAGMENTS="rk3506-usb-host.config rk3506-uvc-camera.config rk3506-no-display.config"|' "$BOARD_CFG"
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

# Интерактивный шелл в сборочном окружении (для отладки)
shell:
    sg docker -c 'docker run --rm -it -v {{sdk_volume}}:{{sdk_dir}} -v {{justfile_directory()}}:/out {{build_image}} bash'

# Удалить volume с SDK (следующая сборка начнётся с состояния чистого образа)
reset:
    sg docker -c 'docker volume rm {{sdk_volume}}'
