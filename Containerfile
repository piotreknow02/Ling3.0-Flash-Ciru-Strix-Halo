# Ling 3.0 Flash CIRU INT4 (gfx1151 / Strix Halo) — self-contained vLLM runtime.
#
# Builds the vendor installer's output into the image: uv-managed Python 3.12,
# pinned ROCm 7.15 nightly wheels (torch/triton/rocm), the CIRU vLLM fork
# compiled for gfx1151, and the host-GCC ROCr idle-fix + LD_PRELOAD wiring.
# The 77 GB checkpoint is NOT in the image — bind-mount it at /models (ro).
#
# Do NOT add a system ROCm to this base: the wheels are self-contained
# (_rocm_sdk_devel inside the venv) and the vendor docs forbid mixing.
FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
# Mirrors the Debian/Ubuntu dep set of the package's scripts/install-host-deps.sh
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates pkg-config \
      libnuma-dev libdrm-dev libelf-dev xxd python3-dev \
    && rm -rf /var/lib/apt/lists/*
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH=/root/.local/bin:$PATH

ARG RELEASE_URL=https://huggingface.co/jcbtc/Ling-3.0-Flash-CIRU-int4-Strix-native/resolve/main
ARG RELEASE_SHA256=c4c88fb110c892da8069c59b370c2994f59ce968ce2baf8632b18b0aee9bdb2f
RUN mkdir -p /opt/ling3 && cd /opt/ling3 \
    && curl -fLO "${RELEASE_URL}/Ling-3.0-Flash-CIRU-int4-Strix-native.tar.gz" \
    && echo "${RELEASE_SHA256}  Ling-3.0-Flash-CIRU-int4-Strix-native.tar.gz" | sha256sum -c - \
    && tar -xzf Ling-3.0-Flash-CIRU-int4-Strix-native.tar.gz \
    && rm Ling-3.0-Flash-CIRU-int4-Strix-native.tar.gz \
    && cd Ling-3.0-Flash-CIRU-int4-Strix-native && sha256sum --check SHA256SUMS

# Runs the vendor installer: uv-managed Python 3.12, pinned ROCm/Torch/Triton wheels,
# CIRU vLLM fork build for gfx1151, host-GCC ROCr idle-fix rebuild + LD_PRELOAD wiring.
# No --download-model: weights are bind-mounted at runtime (install.sh tolerates the
# missing checkpoint and completes "without weights").
ENV MAX_JOBS=16
RUN bash /opt/ling3/Ling-3.0-Flash-CIRU-int4-Strix-native/install.sh \
      --install-root /opt/ling3/runtime

ENV VENV=/opt/ling3/runtime/.venv \
    MODEL_PATH=/models \
    HOST=0.0.0.0 \
    PORT=18081 \
    CACHE_ROOT=/cache
EXPOSE 18081
HEALTHCHECK --interval=30s --timeout=10s --start-period=30m --retries=3 \
  CMD curl -fsS http://127.0.0.1:18081/health || exit 1
CMD ["bash", "/opt/ling3/Ling-3.0-Flash-CIRU-int4-Strix-native/scripts/run-256k.sh"]
