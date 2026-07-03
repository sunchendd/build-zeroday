---
name: build-zeroday
description: Use when the user asks to build, package, or create Docker images based on vllm/vllm-openai or ascend/vllm-ascend base images. Handles building zeroday images with engine-requirements and optional patches, then exporting as tar files to /os_nfs/06_images/.
---

# Build Zeroday Image

Build Docker images based on vLLM / vLLM Ascend base images, install engine-level
dependencies, optionally apply patches, and export as tar files.

## Quick reference

```bash
# Generic image (no patches, engine-requirements only)
./build-zeroday-image.sh \
  -b vllm/vllm-openai:v0.23.0 \
  -e vllm

# With hardware/model naming
./build-zeroday-image.sh \
  -b vllm/vllm-openai:v0.23.0 \
  -e vllm \
  --hardware RTXPRO5000 \
  --model glm5.2

# With patches
./build-zeroday-image.sh \
  -b vllm/vllm-openai:v0.22.0 \
  -e vllm \
  -v v0.22.0 \
  --hardware H20 \
  --model deepseekv4flash
```

## How it works

The script runs `build-zeroday-image.sh` from `/home/scd/build-zeroday/`.

### Required arguments

| Arg | Description |
|-----|-------------|
| `-b, --base-image` | Base image, e.g. `vllm/vllm-openai:v0.23.0` |
| `-e, --engine` | Engine: `vllm` or `vllm-ascend` |

### Patch mode

| Arg | Description |
|-----|-------------|
| `-v, --patch-version` | Patch version directory under engine dir (required when applying patches) |
| `--skip-patch` | Skip patches, only install engine-requirements (makes `-v` optional) |

### Naming (auto-generates output filename)

| Arg | Description |
|-----|-------------|
| `--hardware` | Hardware name, e.g. `RTXPRO5000`, `H20`, `800I_A3` |
| `--model` | Model name, e.g. `glm5.2`, `deepseekv4flash` |
| `--arch` | Architecture: `x86_64` or `aarch64` (default: auto-detect from `uname -m`) |
| `--output-dir` | Output directory (default: `/os_nfs/06_images`) |
| `--prefix` | Filename prefix (default: `Wings`) |

### Output naming convention

With hardware + model: `{prefix}_{engine}_{version}_{hardware}_{model}_{arch}.tar`

Generic (no hardware/model): `{prefix}_{engine}_{version}_{arch}.tar`

Examples:
- `Wings_vllm_v0.23.0_RTXPRO5000_glm5.2_x86_64.tar`
- `Wings_vllm_v0.23.0_x86_64.tar`
- `Wings_vllm_ascend_v0.19.1rc1_800I_A3_glm5.1_aarch64.tar`

Use `-o` to override the auto-generated path.

### Other options

| Arg | Description |
|-----|-------------|
| `-o, --output-tar` | Explicit output path (overrides auto-naming) |
| `-t, --target-image` | Docker image tag (default: auto-generated with timestamp) |
| `--push` | Push image after build |
| `--no-cache` | Build without Docker cache |

## Output files

Each build produces:

| File | Content |
|------|---------|
| `{name}.tar` | Docker image archive |
| `{name}.tar.manifest.json` | Metadata: base image, engine, patches, deps, image ID, md5, build time |
| `{output_dir}/md5_checksums.txt` | Cumulative md5 records for all builds in the directory |

## Engine-requirements

Engine-level pip dependencies are stored in `engine-requirements/`:

- `vllm-zeroday.txt` for `-e vllm`
- `vllm-ascend-zeroday.txt` for `-e vllm-ascend`

These are always installed regardless of patch mode.

## Patch submodules

`vllm-zeroday/` and `vllm-ascend-zeroday/` are git submodules containing
version-specific patches. Sync them with:

```bash
git submodule update --init --recursive
git submodule update --remote --merge vllm-ascend-zeroday vllm-zeroday
```
