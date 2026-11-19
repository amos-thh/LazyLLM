# ==========================================
# 基础镜像阶段 (Layers 1-72)
# 对应官方 nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04 镜像
# ==========================================
ARG RELEASE
ARG LAUNCHPAD_BUILD_ARCH
ARG TARGETARCH

FROM nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04

# ==========================================
# 应用构建阶段 (Layers 73-89)
# ==========================================

# 设置工作目录
WORKDIR /tmp

# 设置用户
USER root

# 设置系统环境变量
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV TZ=Asia/Shanghai

# 安装系统基础依赖 (Layer 78, 423MB)
# 推测安装了 git, wget, curl, redis-tools 等基础工具
RUN set -ex && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        wget \
        curl \
        vim \
        redis-tools \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# 安装 Redis Stack Server (Layer 79, 197MB)
# 根据 PATH 中的路径推测，安装了 redis-stack-server-7.2.0-v10
RUN set -ex && \
    wget -q https://packages.redis.io/redis-stack/redis-stack-server-7.2.0-v10.x86_64.rpm -O /tmp/redis.rpm && \
    # 这里只是推测，实际可能是解压 tar 包到 /usr/local/
    tar -xzf /tmp/redis-stack-server-7.2.0-v10.tar.gz -C /usr/local/ && \
    ln -s /usr/local/redis-stack-server-7.2.0-v10/bin/redis-stack-server /usr/local/bin/

# 更新 PATH 环境变量，加入 Miniconda 和 Redis
ENV PATH=/opt/miniconda3/bin:/usr/local/redis-stack-server-7.2.0-v10/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 复制 Python 依赖文件
COPY requirement* /tmp/

# 初始化 Conda (Layer 82)
RUN conda init

# 安装 PyTorch 和 CUDA 相关依赖 (Layer 83, 1.69GB)
# 这一层非常大，通常是安装 PyTorch + CUDA Toolkit
RUN bash -c "pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121"

# 安装 LazyLLM 及其 Python 依赖 (Layer 84, 3.08GB)
# 这一层最大，包含了 LazyLLM 框架及其庞大的 Python 依赖树
ARG LAZYLLM_VERSION=0.7.2
ENV LAZYLLM_VERSION=0.7.2

RUN bash -c "pip install lazyllm==${LAZYLLM_VERSION}"

# 设置入口点
ENTRYPOINT ["/bin/bash"]

# 设置最终工作目录
WORKDIR /root