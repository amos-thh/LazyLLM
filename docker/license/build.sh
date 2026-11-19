#!/usr/bin/env bash
# =============================================================================
# 编译许可守护模块 _launcher.so (在容器内编译, 无需宿主机装 gcc)
#
# 用法 (在本目录 back/LazyLLM/docker/license 下):
#     ./build.sh 90              # 授权 90 天
#     ./build.sh 30 30 5         # 授权 30 天, 巡检 30s, 容差 ±5s
#
# 产物: 本目录下 _launcher<EXT_SUFFIX>  (例如 _launcher.cpython-310-aarch64-linux-gnu.so)
# 之后覆盖到部署机 docker/license/_launcher*.so, 由 docker-compose 以单文件只读挂载
# 进容器 /opt/llm-service/, 再 docker compose restart 即可 —— 无需重建镜像。
# launcher.c / build_license.py 由 .dockerignore 排除, 不进镜像层。
#
# 注意: 目标机若是 aarch64, 请在 aarch64 宿主机上运行本脚本, 或加 PLATFORM=linux/arm64。
#
# 默认 builder 用 python:3.10-slim-bookworm (Debian 12, 仍在支持期): 镜像自带
# python3.10 头文件, 只需在容器内 apt 装 gcc+libc6-dev 即可编译. 不要用
# python:3.10-slim-bullseye: Debian 11 已 EOL (2024-08-31), 上游与镜像源对
# bullseye 的 glibc 版本参差, apt 装不了 gcc (不是网络/换源能解决的)。
# 想换其它带 gcc 的镜像, 用 BUILDER_IMAGE 覆盖。
# =============================================================================
set -euo pipefail

DAYS="${1:-90}"
INTERVAL="${2:-30}"
TOLERANCE="${3:-5}"
# apt 安装 gcc 用的 Debian 镜像源 (仅作兜底用; 正常走预焙 builder 镜像不会触发)
APT_MIRROR="${APT_MIRROR:-https://mirrors.aliyun.com/debian}"
# Git-Bash/MSYS on Windows mangles docker 路径参数
export MSYS_NO_PATHCONV=1
PLATFORM="${PLATFORM:-}"
# 预焙好的 builder 镜像 (python:3.10-slim-bookworm + gcc 已装, 无需 apt):
#   构建方法见 Dockerfile.builder 头注释。按目标架构自动选, 也可用 BUILDER_IMAGE 覆盖。
if [[ -z "${BUILDER_IMAGE:-}" ]]; then
  if [[ "${PLATFORM}" == *arm64* ]] || [[ "${PLATFORM}" == *aarch64* ]]; then
    BUILDER_IMAGE="license-builder:bookworm-gcc-arm64"
  else
    BUILDER_IMAGE="license-builder:bookworm-gcc"
  fi
fi
DIR="$(cd "$(dirname "$0")" && pwd)"

PLATFORM_ARG=()
if [[ -n "${PLATFORM}" ]]; then
  PLATFORM_ARG=(--platform "${PLATFORM}")
fi

if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
  echo "[build.sh] 本地缺少 builder 镜像 ${BUILDER_IMAGE#docker.io/}, 尝试 docker pull ..." >&2
  docker pull "${BUILDER_IMAGE}"
fi

docker run --rm -i "${PLATFORM_ARG[@]}" \
  -v "${DIR}:/license" \
  -w /license \
  "${BUILDER_IMAGE}" \
  bash -s "${DAYS}" "${INTERVAL}" "${TOLERANCE}" "${APT_MIRROR}" <<'INNER'
set -euo pipefail
DAYS="$1"; INTERVAL="$2"; TOLERANCE="$3"; APT_MIRROR="$4"

if ! command -v gcc >/dev/null 2>&1; then
  echo '[build.sh] 镜像内无 gcc, 用 APT_MIRROR 安装 gcc/libc6-dev ...'
  CODENAME="$(. /etc/os-release; echo "$VERSION_CODENAME")"
  echo "[build.sh] apt 源: ${APT_MIRROR} (${CODENAME}, main)  (30s 硬超时, 不再无限挂)"
  printf 'deb %s %s main\n' "$APT_MIRROR" "$CODENAME" > /etc/apt/sources.list
  APTOPT='-o Acquire::ForceIPv4=true -o Acquire::http::Timeout=30 -o Acquire::Retries=1'
  if ! ( apt-get $APTOPT update -qq >/dev/null \
         && DEBIAN_FRONTEND=noninteractive apt-get $APTOPT install -y --no-install-recommends gcc libc6-dev >/dev/null ); then
    echo 'ERROR: apt 安装 gcc 失败 (超时/网络/镜像不可达)。若在国内, 换镜像源重试:'
    echo "         APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian  ./build.sh ${DAYS}"
    echo "         APT_MIRROR=https://mirrors.ustc.edu.cn/debian          ./build.sh ${DAYS}"
    echo '   或直接换已内置 gcc 的镜像:'
    echo "         BUILDER_IMAGE=<带 gcc+python3.10 的镜像> ./build.sh ${DAYS}"
    exit 1
  fi
fi

python build_license.py --days "$DAYS" --check-interval "$INTERVAL" --tolerance "$TOLERANCE" --output-dir /license
ls -l /license/_launcher*
INNER