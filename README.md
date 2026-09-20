# Ling 3.0 Flash CIRU INT4 — one-command Podman deploy (AMD Strix Halo 128 GB)

Serves [`jcbtc/Ling-3.0-Flash-CIRU-int4-Strix-native`](https://huggingface.co/jcbtc/Ling-3.0-Flash-CIRU-int4-Strix-native)
(vLLM / ROCm, gfx1151, 256K native context, MTP K1 speculative decoding) in a
rootless Podman container on an AMD Strix Halo (Ryzen AI Max 395) workstation.

One command brings it up; one command tears it down.

```bash
cp .env.sample .env   # optional — every var has a default
./start.sh            # build (cached) -> download model -> run -> wait healthy
./stop.sh
```

## What's here

| File | Role |
|---|---|
| `Containerfile` | Self-contained runtime: uv Python 3.12, pinned ROCm 7.15 nightly wheels, CIRU vLLM fork built for gfx1151, ROCr idle-fix + LD_PRELOAD. Checksum-pinned vendor archive. |
| `start.sh` | One-command entrypoint: preflight → build (cached) → download checkpoint (resumable) → run → health-poll. |
| `stop.sh` | Stops the container with a 60 s grace period; idempotent. |
| `.env.sample` | Optional overrides — copy to `.env`. |

The 77 GB checkpoint is **not** baked into the image; it is bind-mounted read-only
at `/models`. The image is ~30 GB (runtime + compiled vLLM).

## Requirements

- **Podman** (rootless) — `podman --version` ≥ 5.x
- **AMD GPU driver** present: `/dev/kfd` and `/dev/dri/renderD128` exist
- Current user in the **`render`** (and ideally `video`) group — check with `id -nG`
- **~120 GB free disk**: 77 GB weights + ~30 GB image + caches
- **128 GB unified RAM** (the 256K profile budgets ~92 GB for KV at util 0.72)
- `curl` on PATH; a HuggingFace downloader (`hf` or `uv`/`uvx`) for the first run

No root/sudo is required for the normal path. Podman runs rootless; GPU access
comes from `--group-add keep-groups` (carries your host `render` group into the
container) plus SELinux `:z` bind relabeling.

## Quick start

```bash
cp .env.sample .env      # optional
./start.sh
```

First run:
1. Builds the image (~20–40 min: multi-GB wheel download + vLLM C++ compile).
2. Downloads the 77 GB checkpoint to `./models` (resumable).
3. Starts the container and streams the engine log to `.ling3.log`.
4. Exits "ready" once `/health` returns 200.

Then:

```bash
curl -s http://127.0.0.1:8080/v1/models | jq -r '.data[0].id'
# -> Ling-3.0-Flash-CIRU-int4-Strix-native
```

Tear down:

```bash
./stop.sh
```

Re-running `./start.sh` after the first time skips the build and the download and
reaches ready materially faster (Triton/vLLM autotune caches live in `./.cache`).

## Configuration

Copy `.env.sample` to `.env` and edit. Precedence (highest first):
**exported shell env → `.env` → `start.sh` defaults.**

| Var | Default | Meaning |
|---|---|---|
| `PROFILE` | `256k` | `256k` (validated) or `1m-yarn` (experimental, 2 seqs) |
| `GPU_MEMORY_UTILIZATION` | *(profile default)* | Override the 0.72 / 0.82 fraction; lower to free RAM |
| `PORT` | `8080` | Host publish port (container always listens on 18081) |
| `MODEL_DIR` | `./models` | Where the checkpoint lives / downloads to |
| `CACHE_DIR` | `./.cache` | vLLM/Triton/HF caches (persist autotune across restarts) |
| `IMAGE` | `ling3-ciru-strix:latest` | Image tag |
| `CONTAINER_NAME` | `ling3-ciru-strix` | Container name |
| `HF_TOKEN` | *(unset)* | Optional HuggingFace token — higher download rate limits |

## Profiles

**`256k` (default, validated)** — `max_model_len 262144`, `max_num_seqs 6`,
`gpu_memory_utilization 0.72`, `max_num_batched_tokens 8192`, MTP K1. Six
requests run concurrently; extras queue in the vLLM scheduler (by design).

**`1m-yarn` (experimental)** — 1M context via YaRN rope scaling, 2 concurrent
sequences, util 0.82. Slower, higher memory, less tested.

```bash
PROFILE=1m-yarn ./start.sh
```

## Recommended sampling

From the model card:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Ling-3.0-Flash-CIRU-int4-Strix-native",
    "messages": [{"role": "user", "content": "Explain what a KV cache is, briefly."}],
    "temperature": 0.6,
    "top_p": 0.95,
    "top_k": 20,
    "max_tokens": 256,
    "chat_template_kwargs": {"enable_thinking": true}
  }' | jq -r '.choices[0].message'
```

## Troubleshooting

**Cold start prints `tl.make_block_ptr is deprecated`, `TypedStorage is deprecated`,
`AUTOTUNE mm(...)`** — NOT failures. Wait for `Application startup complete`,
then `/health` returns 200. A real failure is a traceback / `EngineCore failed` /
nonzero exit.

**`Cannot allocate memory` / HSA pin errors at startup** — the user session's
`memlock` limit is too low for ROCm memory pinning. `start.sh` only warns about
this (it does not block). If the engine actually fails to pin, raise it once
(needs sudo):

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nLimitMEMLOCK=infinity\n' | sudo tee /etc/systemd/system/user@.service.d/10-memlock.conf
sudo systemctl daemon-reload
# then log out and back in (or: sudo systemctl restart user@$(id -u).service — kills your session)
```

Many setups run fine without this; only apply it if you see the pin error.

**SELinux `Permission denied` on `/models`** — confirm the `:z` suffix on the bind
(start.sh sets it). If you relabeled the directory manually, `restorecon -R` it or
just re-run `./start.sh`.

**Host OOM under load** — close other apps or lower `GPU_MEMORY_UTILIZATION`
(0.72 × 128 GB ≈ 92 GB KV budget on a 128 GB box).

**Concurrency** — six requests max on the 256K profile; extras queue in the vLLM
scheduler (by design).

## Notes

- **No system ROCm in the image.** The wheels are self-contained
  (`_rocm_sdk_devel` inside the venv); the vendor docs forbid mixing a system
  ROCm. The container distro (Ubuntu 24.04) is independent of the host distro —
  only the kernel is shared.
- **`--ipc host` is load-bearing** — the GPU runtime dies at startup without it;
  no `shm_size` substitutes.
- **Docker instead of Podman** — the same `Containerfile` works under a rootful
  Docker daemon with `docker run --device /dev/kfd --device /dev/dri
  --group-add video,render --ipc host --ulimit memlock=-1:-1`. Swap the CLI in
  `start.sh` if you prefer Docker.
