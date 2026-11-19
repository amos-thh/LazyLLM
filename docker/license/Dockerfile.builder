# 许可模块编译用 builder: python:3.10-slim-bookworm + gcc(已预装, 无需再 apt)
# 用法:
#   amd64:  docker build -t license-builder:bookworm-gcc            -f Dockerfile.builder .
#   arm64:  docker buildx build --platform linux/arm64 --load \
#             --build-arg BASE_IMAGE=docker.1ms.run/library/python:3.10-slim-bookworm \
#             -t license-builder:bookworm-gcc-arm64 -f Dockerfile.builder .
# (arm64 变体也基于文档镜像, 因为本机 Docker Hub 不通; 直连通的话 BASE_IMAGE 用官方名)
ARG BASE_IMAGE=python:3.10-slim-bookworm
FROM ${BASE_IMAGE}
# 预装 gcc + libc 头; bookworm 在支持期内, 国内用清华源加速 (仅 main 组件够用)
RUN printf 'deb https://mirrors.tuna.tsinghua.edu.cn/debian bookworm main\n' > /etc/apt/sources.list \
 && apt-get -o Acquire::ForceIPv4=true update \
 && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /license