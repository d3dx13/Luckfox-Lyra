# syntax=docker/dockerfile:1
#
# Базовый образ luckfox_lyra: Ubuntu 22.04 + распакованное Luckfox Lyra SDK.
# Архив SDK монтируется только на время распаковки (bind-mount) и не попадает
# ни в один слой образа. .repo удаляется после восстановления рабочего дерева.

ARG UBUNTU_VERSION=22.04

# --- Стадия распаковки -------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS unpack

ARG SDK_ARCHIVE=Luckfox_Lyra_SDK_250815.tar.gz
ENV DEBIAN_FRONTEND=noninteractive

# Комплектный repo из бандла — времён Python 2. Системный repo 2.x не подходит:
# его лаунчер всё равно re-exec'ит древний .repo/repo/main.py из бандла.
# Поэтому ставим python2 и запускаем бандловый repo под ним — родной инструмент
# для этого бандла, всё офлайн.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        python2 git ca-certificates gzip \
 && rm -rf /var/lib/apt/lists/*

# repo sync требует настроенную git-идентичность
RUN git config --global user.name sdk-unpack \
 && git config --global user.email sdk-unpack@local

# Архив — это repo-бандл: внутри только .repo/ (bare-репозитории + манифест).
# Рабочее дерево восстанавливается офлайн через repo sync (в манифесте fetch=".").
RUN --mount=type=bind,source=${SDK_ARCHIVE},target=/tmp/sdk.tar.gz \
    mkdir -p /opt/luckfox-lyra-sdk \
 && tar -xzf /tmp/sdk.tar.gz -C /opt/luckfox-lyra-sdk \
 && cd /opt/luckfox-lyra-sdk \
 && python2 .repo/repo/repo sync -c -l --no-repo-verify -j"$(nproc)" \
 && rm -rf .repo

# --- Финальный образ ---------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION}

LABEL org.opencontainers.image.title="luckfox_lyra" \
      org.opencontainers.image.description="Unpacked Luckfox Lyra SDK (RK3506, Linux 6.1, SDK 250815) on Ubuntu 22.04"

COPY --from=unpack /opt/luckfox-lyra-sdk /opt/luckfox-lyra-sdk

WORKDIR /opt/luckfox-lyra-sdk
CMD ["/bin/bash"]
