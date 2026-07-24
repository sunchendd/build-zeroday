#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build-zeroday-image.sh -b BASE_IMAGE -e ENGINE [options]

Required:
  -b, --base-image IMAGE     Input/base image, e.g. vllm/vllm-openai:v0.23.0
  -e, --engine ENGINE        Engine: vllm or vllm-ascend

Patch mode (optional):
  -v, --patch-version VER    Patch version directory, e.g. v0.22.0
                              Required unless --skip-patch is set.

Naming (auto-generates output filename):
      --hardware HW           机型 or CUDA token (auto-lowercased):
                               NPU (vllm-ascend): a2 | a3
                               GPU (vllm): rtx-pro5000 | h20 | cuXXX
                               GPU without --model auto-detects CUDA if omitted
      --model MODEL           Model name: glm5.2, deepseekv4flash (model-specific image)
      --arch ARCH             Architecture: x86_64 or aarch64 (default: auto-detect)
      --output-dir DIR        Output directory (default: /os_nfs/06_images)
      --prefix PREFIX         Filename prefix (default: Wings)

Output naming (tag = all lowercase; filename = first letter capitalized, rest lowercase;
hyphens -> underscores; saved as .tgz via pigz):
  Model-specific (--model + --hardware):
    tag:  wings_{engine}:{model}-{hardware}-{ts}
    tgz:  Wings_{engine}_{model}_{hardware}_{ts}_{arch}.tgz
  Release        (--hardware, no --model):
    tag:  wings_{engine}:{version}-{hardware}-{ts}
    tgz:  Wings_{engine}_{version}_{hardware}_{ts}_{arch}.tgz
  Generic        (no --hardware, no --model):
    tag:  wings_{engine}:{version}-{ts}
    tgz:  Wings_{engine}_{version}_{ts}_{arch}.tgz

  --hardware (机型) allowlist:
    NPU (vllm-ascend): a2 | a3
    GPU (vllm):        rtx-pro5000 | h20  (model-specific); cuXXX for CUDA release

Other options:
  -o, --output-tar FILE      Save to explicit tar path (overrides auto-naming)
      --save FILE             Alias for --output-tar
  -t, --target-image IMAGE   Output image tag (default: auto-generated)
  -f, --dockerfile FILE      Dockerfile path (default: ./Dockerfile)
  -s, --suffix SUFFIX        Tag suffix (default: none)
      --patch-script FILE    Patch script name (default: apply-patch.sh)
      --skip-patch           Skip applying patches; only install engine-requirements
      --push                 Push the built image
      --no-cache             Build without cache
  -h, --help                 Show this help

Examples:
  # Model-specific
  ./build-zeroday-image.sh \
    -b quay.io/ascend/vllm-ascend:v0.21.0rc1 \
    -e vllm-ascend \
    --hardware a3 --model glm5.2

  # GPU general release
  ./build-zeroday-image.sh \
    -b vllm/vllm-openai:v0.23.0 \
    -e vllm \
    --hardware cu130

  # Ascend general release
  ./build-zeroday-image.sh \
    -b quay.io/ascend/vllm-ascend:v0.21.0rc1 \
    -e vllm-ascend \
    --hardware A3

  # With patches
  ./build-zeroday-image.sh \
    -b vllm/vllm-openai:v0.22.0 \
    -e vllm \
    -v v0.22.0 \
    --hardware H20 --model deepseekv4flash
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

normalize_image() {
  local image="$1"
  printf '%s' "${image//：/:}"
}

extract_image_tag() {
  local image="$1"
  local tag="${image##*:}"
  if [[ "$tag" == *@* || "$tag" == "$image" ]]; then
    die "Cannot extract tag from image '${image}'. Please provide an image with a tag."
  fi
  printf '%s' "$tag"
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  printf 'x86_64' ;;
    aarch64) printf 'aarch64' ;;
    *)       die "Unsupported architecture: ${arch}" ;;
  esac
}

detect_cuda_version() {
  local image="$1"
  local cuda_ver

  # Try CUDA_VERSION or NV_CUDA_VERSION env vars from image metadata (no container start)
  cuda_ver="$("$container_cli" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" 2>/dev/null | grep -i '^CUDA_VERSION=' | head -1 | cut -d= -f2)"
  if [[ -z "$cuda_ver" ]]; then
    cuda_ver="$("$container_cli" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" 2>/dev/null | grep -i '^NV_CUDA_VERSION=' | head -1 | cut -d= -f2)"
  fi

  if [[ -n "$cuda_ver" ]]; then
    # "13.0.123" -> "cu130"
    local major_minor
    major_minor="$(echo "$cuda_ver" | cut -d. -f1-2 | tr -d '.')"
    printf 'cu%s' "$major_minor"
  else
    die "Cannot detect CUDA version from image '${image}'. Specify --hardware manually."
  fi
}

validate_arch() {
  local file="$1"
  local current
  current="$(detect_arch)"

  if [[ "$file" == *"x86_64"* && "$current" != "x86_64" ]]; then
    die "Output file name contains 'x86_64' but current arch is '${current}'."
  fi
  if [[ "$file" == *"aarch64"* && "$current" != "aarch64" ]]; then
    die "Output file name contains 'aarch64' but current arch is '${current}'."
  fi
}

validate_hardware() {
  # 机型 (machine type) allowlist. CUDA release tokens (cu129/cu130/...) are open-ended.
  local engine="$1" hardware="$2"
  [[ -z "$hardware" ]] && return 0
  [[ "$hardware" =~ ^cu[0-9]+$ ]] && return 0

  case "$engine" in
    vllm-ascend|ascend)
      [[ "$hardware" == "a2" || "$hardware" == "a3" ]] \
        || die "Invalid NPU 机型 '${hardware}'. Allowed: a2, a3"
      ;;
    vllm)
      [[ "$hardware" == "rtx-pro5000" || "$hardware" == "h20" ]] \
        || die "Invalid GPU 机型 '${hardware}'. Allowed: rtx-pro5000, h20 (or cuXXX CUDA token)"
      ;;
  esac
}

default_target_image() {
  local image="$1"
  local engine="$2"
  local version="$3"
  local model="$4"
  local hardware="$5"
  local suffix="$6"
  local timestamp="$7"

  if [[ "$image" == *@sha256:* ]]; then
    die "Cannot derive a target tag from digest image '${image}'. Please pass --target-image."
  fi

  local engine_tag="${engine//-/_}"   # vllm-ascend -> vllm_ascend
  local model_l="${model,,}"          # tag rule: all lowercase
  local version_l="${version,,}"
  local hardware_l="${hardware,,}"

  if [[ -n "$model_l" && -n "$hardware_l" ]]; then
    # Model-specific: wings_{engine}:{model}-{hardware}-{timestamp}
    printf 'wings_%s:%s-%s-%s' "$engine_tag" "$model_l" "$hardware_l" "$timestamp"
  elif [[ -n "$hardware_l" ]]; then
    # General release: wings_{engine}:{version}-{hardware}-{timestamp}
    printf 'wings_%s:%s-%s-%s' "$engine_tag" "$version_l" "$hardware_l" "$timestamp"
  else
    # Generic: wings_{engine}:{version}-{timestamp}
    printf 'wings_%s:%s-%s' "$engine_tag" "$version_l" "$timestamp"
  fi
}

generate_output_name() {
  local prefix="$1"
  local engine="$2"
  local version="$3"
  local hardware="$4"
  local model="$5"
  local arch="$6"
  local output_dir="$7"
  local timestamp="$8"

  local engine_name="${engine//-/_}"
  local name
  if [[ -n "$model" && -n "$hardware" ]]; then
    # Model-specific: Wings_{engine}_{model}_{hardware}_{timestamp}_{arch}.tgz
    name="${prefix}_${engine_name}_${model}_${hardware}_${timestamp}_${arch}"
  elif [[ -n "$hardware" ]]; then
    # General release with hardware: Wings_{engine}_{version}_{hardware}_{timestamp}_{arch}.tgz
    name="${prefix}_${engine_name}_${version}_${hardware}_${timestamp}_${arch}"
  else
    # Generic: Wings_{engine}_{version}_{timestamp}_{arch}.tgz
    name="${prefix}_${engine_name}_${version}_${timestamp}_${arch}"
  fi
  name="${name//-/_}"   # hyphens -> underscores
  # Filename rule: first letter capitalized, everything else lowercase
  local first="${name:0:1}"
  name="${name,,}"
  name="${first^^}${name:1}"
  printf '%s/%s.tgz' "$output_dir" "$name"
}

resolve_engine_dir() {
  local engine="$1"

  case "$engine" in
    vllm)
      printf '%s' "vllm-zeroday"
      ;;
    ascend|vllm-ascend)
      printf '%s' "vllm-ascend-zeroday"
      ;;
    *)
      die "Unsupported engine '${engine}'. Supported engines: vllm, vllm-ascend"
      ;;
  esac
}

# ──────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base_image=""
target_image=""
engine=""
patch_version=""
patch_dir=""
patch_script="apply-patch.sh"
dockerfile="${repo_root}/Dockerfile"
suffix=""
save_file=""
push_image=0
no_cache=0
skip_patch=0
hardware=""
model=""
arch=""
output_dir="/os_nfs/06_images"
prefix="Wings"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--base-image)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      base_image="$(normalize_image "$2")"
      shift 2
      ;;
    -t|--target-image)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      target_image="$(normalize_image "$2")"
      shift 2
      ;;
    -e|--engine)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      engine="$2"
      shift 2
      ;;
    -v|--patch-version)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      patch_version="${2#/}"
      shift 2
      ;;
    --patch-script)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      patch_script="$2"
      shift 2
      ;;
    -f|--dockerfile)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      dockerfile="$2"
      shift 2
      ;;
    -s|--suffix)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      suffix="$2"
      shift 2
      ;;
    -o|--output-tar|--save)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      save_file="$2"
      shift 2
      ;;
    --hardware)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      hardware="${2,,}"
      shift 2
      ;;
    --model)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      model="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      case "$2" in
        x86_64|aarch64) arch="$2" ;;
        *) die "Invalid arch '$2'. Supported: x86_64, aarch64" ;;
      esac
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      output_dir="$2"
      shift 2
      ;;
    --prefix)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      prefix="$2"
      shift 2
      ;;
    --push)
      push_image=1
      shift
      ;;
    --no-cache)
      no_cache=1
      shift
      ;;
    --skip-patch)
      skip_patch=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

# ──────────────────────────────────────────────
# Validation
# ──────────────────────────────────────────────

[[ -n "$base_image" ]] || die "Missing --base-image"
[[ -n "$engine" ]] || die "Missing --engine"
[[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"

# When --skip-patch, patch directory is not strictly needed
# But if -v IS given, use it for the build context (some deps may still be installed)
engine_dir="$(resolve_engine_dir "$engine")"
if [[ "$skip_patch" -eq 1 ]]; then
  # --skip-patch: -v is optional. If not given, use a dummy value (PATCH_DIR in
  # Dockerfile is only used inside the non-SKIP_PATCH branch anyway).
  if [[ -z "$patch_version" ]]; then
    patch_version="_skip"
    patch_dir="${engine_dir}/_skip"
  else
    patch_dir="${engine_dir}/${patch_version}"
  fi
else
  # Patch mode: -v is required and must point to a valid directory with a patch script
  [[ -n "$patch_version" ]] || die "Missing --patch-version (required unless --skip-patch)"
  [[ "$patch_version" != *"/"* && "$patch_version" != *".."* ]] || \
    die "Patch version must be a version directory name, not a path: $patch_version"
  [[ -d "${repo_root}/${engine_dir}" ]] || \
    die "Patch engine directory not found: ${repo_root}/${engine_dir}"
  patch_dir="${engine_dir}/${patch_version}"
  [[ -d "${repo_root}/${patch_dir}" ]] || \
    die "Patch version directory not found: ${repo_root}/${patch_dir}"
  [[ -f "${repo_root}/${patch_dir}/${patch_script}" ]] || \
    die "Patch script not found: ${repo_root}/${patch_dir}/${patch_script}"
fi

# ──────────────────────────────────────────────
# Container CLI
# ──────────────────────────────────────────────

container_cli="${CONTAINER_CLI:-}"
if [[ -z "$container_cli" ]]; then
  if command -v docker >/dev/null 2>&1; then
    container_cli="docker"
  elif command -v podman >/dev/null 2>&1; then
    container_cli="podman"
  else
    die "Neither docker nor podman is available. Set CONTAINER_CLI to your container CLI."
  fi
fi

# ──────────────────────────────────────────────
# Auto-detect CUDA for GPU images
# ──────────────────────────────────────────────

if [[ "$engine" == "vllm" && -z "$hardware" && -z "$model" ]]; then
  hardware="$(detect_cuda_version "$base_image")"
  echo "Auto-detected CUDA: ${hardware}"
fi

# Validate 机型 / CUDA token
validate_hardware "$engine" "$hardware"

# ──────────────────────────────────────────────
# Extract version & timestamp (used by naming)
# ──────────────────────────────────────────────

version="$(extract_image_tag "$base_image")"
build_ts="$(date +%Y%m%d%H%M%S)"

# ──────────────────────────────────────────────
# Auto-generate output filename
# ──────────────────────────────────────────────

if [[ -z "$save_file" ]]; then
  [[ -z "$arch" ]] && arch="$(detect_arch)"
  mkdir -p "$output_dir"
  save_file="$(generate_output_name "$prefix" "$engine" "$version" "$hardware" "$model" "$arch" "$output_dir" "$build_ts")"
  echo "Auto-generated output: ${save_file}"
fi

if [[ -n "$save_file" ]]; then
  validate_arch "$save_file"
fi

# ──────────────────────────────────────────────
# Target image tag
# ──────────────────────────────────────────────

if [[ -z "$target_image" ]]; then
  target_image="$(default_target_image "$base_image" "$engine" "$version" "$model" "$hardware" "$suffix" "$build_ts")"
fi

# ──────────────────────────────────────────────
# Build
# ──────────────────────────────────────────────

build_args=(
  build
  -f "$dockerfile"
  --build-arg "BASE_IMAGE=$base_image"
  --build-arg "ENGINE=$engine_dir"
  --build-arg "PATCH_DIR=$patch_dir"
  --build-arg "PATCH_SCRIPT=$patch_script"
  -t "$target_image"
)

if [[ "$no_cache" -eq 1 ]]; then
  build_args+=(--no-cache)
fi

if [[ "$skip_patch" -eq 1 ]]; then
  build_args+=(--build-arg SKIP_PATCH=true)
fi

# ── Image labels ──
build_args+=(--label "ai.wings.base-image=${base_image}")
build_args+=(--label "ai.wings.engine=${engine}")
build_args+=(--label "ai.wings.patch-version=${patch_version}")
build_args+=(--label "ai.wings.skip-patch=$([[ "$skip_patch" -eq 1 ]] && echo 'true' || echo 'false')")
build_args+=(--label "ai.wings.build-time=$(date -u +%Y-%m-%dT%H:%M:%SZ)")

build_args+=("$repo_root")

# Allow overriding the pip mirror per-host (e.g. isolated hosts using an internal mirror)
if [[ -n "${PIP_INDEX_URL:-}" ]]; then
  build_args+=(--build-arg "PIP_INDEX_URL=${PIP_INDEX_URL}")
fi
if [[ -n "${PIP_TRUSTED_HOST:-}" ]]; then
  build_args+=(--build-arg "PIP_TRUSTED_HOST=${PIP_TRUSTED_HOST}")
fi

echo "Building ${target_image} from ${base_image}"
"$container_cli" "${build_args[@]}"

if [[ -n "$save_file" ]]; then
  echo "Saving ${target_image} to ${save_file}"
  if ! command -v pigz >/dev/null 2>&1; then
    echo "pigz not found, installing..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pigz || { echo "ERROR: failed to install pigz"; exit 1; }
  fi
  "$container_cli" save "$target_image" | pigz > "$save_file"

  # ── Metadata ──
  manifest_file="${save_file}.manifest.json"
  image_id="$("$container_cli" inspect --format='{{.Id}}' "$target_image")"
  build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  checksum="$(md5sum "$save_file" | awk '{print $1}')"

  # Collect patch info
  patches_json="[]"
  if [[ "$skip_patch" -ne 1 && -d "${repo_root}/${patch_dir}" ]]; then
    mapfile -t patch_files < <(find "${repo_root}/${patch_dir}" -maxdepth 1 \( -name '*.patch' -o -name '*.diff' \) -printf '%f\n' 2>/dev/null | sort)
    if [[ ${#patch_files[@]} -gt 0 ]]; then
      patches_json="["
      for p in "${patch_files[@]}"; do
        patches_json+="\"$p\","
      done
      patches_json="${patches_json%,}]"
    fi
  fi

  # Collect engine-requirements content
  engine_req_file="${repo_root}/engine-requirements/${engine_dir}.txt"
  engine_req_content=""
  if [[ -f "$engine_req_file" ]]; then
    engine_req_content="$(grep -v '^#' "$engine_req_file" | grep -v '^[[:space:]]*$' | tr '\n' ' ' | sed 's/ *$//')"
  fi

  cat > "$manifest_file" <<MANIFEST
{
  "output": "${save_file##*/}",
  "image_id": "${image_id}",
  "base_image": "${base_image}",
  "engine": "${engine}",
  "patch_version": "${patch_version}",
  "patches": ${patches_json},
  "skip_patch": $([[ "$skip_patch" -eq 1 ]] && echo "true" || echo "false"),
  "engine_requirements": "${engine_req_content}",
  "build_time": "${build_time}",
  "md5": "${checksum}"
}
MANIFEST
  echo "Metadata written to ${manifest_file}"

  # ── Checksum record ──
  checksum_file="${output_dir}/md5_checksums.txt"
  echo "${checksum}  ${save_file##*/}" >> "$checksum_file"
  echo "Checksum appended to ${checksum_file}"
fi

if [[ "$push_image" -eq 1 ]]; then
  echo "Pushing ${target_image}"
  "$container_cli" push "$target_image"
fi

echo "Done: ${target_image}"
