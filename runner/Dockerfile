# Pearl runner image — adds pearld + entrypoint + watchdog on top of the
# upstream vllm_miner image. Build context must be the Pearl monorepo root.
#
# Build:
#   cd /home/bean/pearl/build/pearl
#   docker buildx build \
#       --build-arg MAX_JOBS=1 \
#       --build-arg PEARL_TAG=pearl-wallet-v1.0.0 \
#       --build-arg PEARL_BIN_VER=v1.0.2 \
#       -f /home/bean/pearl/runner/Dockerfile \
#       -t ghcr.io/beaaan/pearl-runner:v1 \
#       --push \
#       .

ARG CUDA_VERSION=12.9.1

# ---- Stage 1: upstream vllm_miner (heavy: vLLM + CUTLASS kernels) --------
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS miner-builder
ARG MAX_JOBS=1
ENV MAX_JOBS=${MAX_JOBS}

COPY --from=docker.io/astral/uv:latest /uv /usr/local/bin/uv
COPY --from=rust:latest /usr/local/cargo /usr/local/cargo
COPY --from=rust:latest /usr/local/rustup /usr/local/rustup
ENV PATH="/usr/local/cargo/bin:${PATH}" \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    UV_PYTHON_INSTALL_DIR=/usr/local/uv-python \
    UV_PYTHON_BIN_DIR=/usr/local/bin \
    UV_PROJECT_ENVIRONMENT=/usr/local/venv \
    UV_LINK_MODE=copy \
    UV_TORCH_BACKEND=cu129 \
    UV_COMPILE_BYTECODE=true
RUN rustup self update && rustup default stable && uv python install 3.12 --default

WORKDIR /app
COPY pyproject.toml uv.lock ./
COPY miner/pearl-gemm/pyproject.toml miner/pearl-gemm/setup.py ./miner/pearl-gemm/
COPY miner/pearl-gemm-build-utils/pyproject.toml ./miner/pearl-gemm-build-utils/
COPY py-pearl-mining/pyproject.toml py-pearl-mining/Cargo.toml ./py-pearl-mining/
COPY miner/vllm-miner/pyproject.toml ./miner/vllm-miner/
COPY miner/miner-utils/pyproject.toml ./miner/miner-utils/
COPY miner/miner-base/pyproject.toml ./miner/miner-base/
COPY miner/pearl-gateway/pyproject.toml ./miner/pearl-gateway/

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    uv sync --package vllm-miner --no-editable --no-dev --no-install-workspace

COPY miner/pearl-gemm/ ./miner/pearl-gemm/
COPY miner/pearl-gemm-build-utils/ ./miner/pearl-gemm-build-utils/

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    uv sync --package pearl-gemm --no-editable --no-dev

COPY miner/miner-utils/ ./miner/miner-utils/
COPY miner/miner-base/ ./miner/miner-base/
COPY miner/pearl-gateway/ ./miner/pearl-gateway/
COPY miner/vllm-miner/src ./miner/vllm-miner/src
COPY pearl-blake3/ ./pearl-blake3/
COPY py-pearl-mining/ ./py-pearl-mining/
COPY zk-pow/ ./zk-pow/
COPY plonky2/ ./plonky2/

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    uv sync --package vllm-miner --no-install-package pearl-gemm --no-editable --no-dev --inexact

# ---- Stage 2: pearld binaries (use upstream's published release) ---------
FROM debian:bookworm-slim AS pearl-fetch
ARG PEARL_TAG=pearl-wallet-v1.0.0
ARG PEARL_BIN_VER=v1.0.2
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN set -e \
 && cd /tmp \
 && curl -fsSL -O "https://github.com/pearl-research-labs/pearl/releases/download/${PEARL_TAG}/go-binaries-linux-amd64-${PEARL_BIN_VER}.tar.gz" \
 && curl -fsSL -O "https://github.com/pearl-research-labs/pearl/releases/download/${PEARL_TAG}/checksums.txt" \
 && grep "go-binaries-linux-amd64-${PEARL_BIN_VER}.tar.gz" checksums.txt \
      | sed 's| \./.*/| |' \
      | sha256sum -c - \
 && mkdir -p /out \
 && tar -xzf "go-binaries-linux-amd64-${PEARL_BIN_VER}.tar.gz" -C /out \
 && ls -la /out

# ---- Stage 3: runtime image -----------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04 AS runtime

RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq gcc libc-dev procps tini

# vLLM + venv from miner builder
COPY --from=miner-builder /usr/local/uv-python /usr/local/uv-python
COPY --from=miner-builder /usr/local/venv /usr/local/venv

# pearld + prlctl + oyster from upstream release
COPY --from=pearl-fetch /out/pearld /out/prlctl /out/oyster /usr/local/bin/

ENV PATH="/usr/local/venv/bin:${PATH}" \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/venv/lib/python3.12/site-packages/torch/lib

# Runner-specific scripts
COPY runner/entrypoint.sh /usr/local/bin/pearl-runner-entrypoint
COPY runner/watchdog.sh   /usr/local/bin/pearl-watchdog
RUN chmod +x /usr/local/bin/pearl-runner-entrypoint /usr/local/bin/pearl-watchdog

# Default mainnet ports + miner port. Vast typically uses host networking,
# so EXPOSE is mostly documentation here.
EXPOSE 44107 44108 8000 8337 8339

VOLUME ["/var/lib/pearl"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/pearl-runner-entrypoint"]
