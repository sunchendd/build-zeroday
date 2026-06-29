# build-zeroday

Patch and package vLLM / vLLM Ascend Docker images with engine-level deps.

## Invocation

```
./build-zeroday-image.sh -b IMAGE -e ENGINE [--hardware HW] [--model MODEL] [flags]
```

### Required

| Arg | Values |
|-----|--------|
| `-b, --base-image` | any Docker image with a tag |
| `-e, --engine` | `vllm` or `vllm-ascend` |

### Naming

| Arg | Default |
|-----|---------|
| `--hardware` | — `cu130`, `A3`, `H20`, `RTXPRO5000` |
| `--model` | — model-specific image (`glm5.2`, `deepseekv4flash`) |
| `--arch` | auto (`uname -m` → `x86_64` / `aarch64`) |
| `--prefix` | `Wings` |
| `--output-dir` | `/nfs1/images_official` |
| `-o` | override auto-naming |

**Naming rules:**

| Mode | Image tag | Tar file |
|------|-----------|----------|
| Model-specific `--model`+`--hardware` | `wings_{engine}:{model}-{hw}-{ts}` | `Wings_{engine}_{model}_{hw}_{ts}_{arch}.tar` |
| GPU release `--hardware`, engine=vllm | `wings_{engine}:{ver}-{hw}-{ts}` | `Wings_{engine}_{ver}_{hw}_{ts}_{arch}.tar` |
| Ascend release `--hardware`, engine=vllm-ascend | `wings_{engine}:{ver}-{hw}-{ts}` | `Wings_{engine}_{ver}_{ts}_{arch}.tar` |
| Generic | `wings_{engine}:{ver}-{ts}` | `Wings_{engine}_{ver}_{ts}_{arch}.tar` |

### Patch

| Arg | Effect |
|-----|--------|
| `-v, --patch-version` | version dir under `vllm-zeroday/` or `vllm-ascend-zeroday/` |
| `--skip-patch` | skip patches, install engine-requirements only |
| `--patch-script` | script name (default `apply-patch.sh`) |

### Other

| Arg | Effect |
|-----|--------|
| `-t, --target-image` | override image tag |
| `-s, --suffix` | tag suffix (default: none) |
| `--push` | push after build |
| `--no-cache` | `docker build --no-cache` |

## Output files

| File | Content |
|------|---------|
| `{name}.tar` | Docker image archive |
| `{name}.tar.manifest.json` | Metadata: base image, engine, patches, deps, image ID, md5, build time |
| `{output_dir}/md5_checksums.txt` | Cumulative md5 records |

## Examples

```bash
# Model-specific (ascend)
./build-zeroday-image.sh -b quay.io/ascend/vllm-ascend:v0.21.0rc1 -e vllm-ascend \
  --hardware a3 --model glm5.2

# GPU general release
./build-zeroday-image.sh -b vllm/vllm-openai:v0.23.0 -e vllm --hardware cu130

# Ascend general release
./build-zeroday-image.sh -b quay.io/ascend/vllm-ascend:v0.21.0rc1 -e vllm-ascend --hardware A3

# Generic
./build-zeroday-image.sh -b vllm/vllm-openai:v0.23.0 -e vllm

# With patches
./build-zeroday-image.sh -b vllm/vllm-openai:v0.22.0 -e vllm -v v0.22.0 \
  --hardware H20 --model deepseekv4flash
```

## engine-requirements

| File | Engine |
|------|--------|
| `engine-requirements/vllm-zeroday.txt` | `-e vllm` |
| `engine-requirements/vllm-ascend-zeroday.txt` | `-e vllm-ascend` |

## Submodules

```bash
git submodule update --init --recursive
git submodule update --remote --merge vllm-ascend-zeroday vllm-zeroday
```
