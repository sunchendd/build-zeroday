# build-zeroday

Patch and package vLLM / vLLM Ascend Docker images with engine-level deps.

## Invocation

```
./build-zeroday-image.sh -b IMAGE -e ENGINE [-v VER] [--hardware HW] [--model MODEL] [flags]
```

### Required

| Arg | Values |
|-----|--------|
| `-b, --base-image` | any Docker image with a tag, e.g. `vllm/vllm-openai:v0.23.0` |
| `-e, --engine` | `vllm` or `vllm-ascend` |

### Patch control

| Arg | Default | Effect |
|-----|---------|--------|
| `-v, --patch-version` | — | version dir under `vllm-zeroday/` or `vllm-ascend-zeroday/`; **required unless `--skip-patch`** |
| `--skip-patch` | false | skip `apply-patch.sh`, `apt-packages.txt`, `requirements.txt`; install only engine-requirements |
| `--patch-script` | `apply-patch.sh` | script name inside the patch version dir |

### Output naming

| Arg | Default | Effect |
|-----|---------|--------|
| `--hardware` | — | e.g. `RTXPRO5000`, `H20`, `800I_A3` |
| `--model` | — | e.g. `glm5.2`, `deepseekv4flash` |
| `--arch` | auto (`uname -m`) | `amd64` or `aarch64` |
| `--prefix` | `Wings` | filename prefix |
| `--output-dir` | `/nfs1/images_official` | output directory |
| `-o, --output-tar` | auto-generated | full path, overrides auto-naming |

**Auto-generated filename:**

- With `--hardware` + `--model`: `{prefix}_{engine}_{version}_{hardware}_{model}_{arch}.tar`
- Without: `{prefix}_{engine}_{version}_{arch}.tar`
- `engine`: hyphens replaced with underscores (`vllm-ascend` → `vllm_ascend`)
- `version`: extracted from the base image tag (everything after last `:`)

### Other

| Arg | Effect |
|-----|--------|
| `-t, --target-image` | Docker tag (default: `BASE_IMAGE-zeroday-TIMESTAMP`) |
| `-s, --suffix` | tag suffix (default: `zeroday`) |
| `-f, --dockerfile` | path (default: `./Dockerfile`) |
| `--push` | push after build |
| `--no-cache` | `docker build --no-cache` |

## Common patterns

```bash
# Generic image (engine-requirements only, no patch)
./build-zeroday-image.sh -b vllm/vllm-openai:v0.23.0 -e vllm

# With hardware/model naming
./build-zeroday-image.sh -b vllm/vllm-openai:v0.23.0 -e vllm \
  --hardware RTXPRO5000 --model glm5.2

# With patches applied
./build-zeroday-image.sh -b vllm/vllm-openai:v0.22.0 -e vllm -v v0.22.0 \
  --hardware H20 --model deepseekv4flash

# vllm-ascend with patches
./build-zeroday-image.sh -b quay.io/ascend/vllm-ascend:v0.19.1rc1 -e vllm-ascend \
  -v 0.19.1rc1 --hardware 800I_A3 --model glm5.1

# Explicit output path
./build-zeroday-image.sh -b vllm/vllm-openai:v0.23.0 -e vllm \
  -o /nfs1/images_official/Wings_vllm_v0.23.0_amd64.tar
```

## engine-requirements

| File | Engine |
|------|--------|
| `engine-requirements/vllm-zeroday.txt` | `-e vllm` |
| `engine-requirements/vllm-ascend-zeroday.txt` | `-e vllm-ascend` |

Dockerfile selects the correct file via the `ENGINE` build arg. Always installed regardless of patch mode.

## Submodules

```bash
git submodule update --init --recursive
git submodule update --remote --merge vllm-ascend-zeroday vllm-zeroday
```

Directories:

| Dir | Engine |
|-----|--------|
| `vllm-zeroday/` | `-e vllm` |
| `vllm-ascend-zeroday/` | `-e vllm-ascend` |
