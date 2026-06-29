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
      --hardware HW           Hardware name, e.g. RTXPRO5000, H20, 800I_A3
      --model MODEL           Model name, e.g. glm5.2, deepseekv4flash
      --arch ARCH             Architecture: amd64 or aarch64 (default: auto-detect)
      --output-dir DIR        Output directory (default: /nfs1/images_official)
      --prefix PREFIX         Filename prefix (default: Wings)

Output filename format:
  {prefix}_{engine}_{version}_{hardware}_{model}_{arch}.tar

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
  # With patches
  ./build-zeroday-image.sh \
    -b vllm/vllm-openai:v0.22.0 \
    -e vllm \
    -v v0.22.0 \
    --hardware H20 \
    --model deepseekv4flash

  # Without patches (engine-requirements only)
  ./build-zeroday-image.sh \
    -b vllm/vllm-openai:v0.23.0 \
    -e vllm \
    --hardware RTXPRO5000 \
    --model glm5.2
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
    x86_64)  printf 'amd64' ;;
    aarch64) printf 'aarch64' ;;
    *)       die "Unsupported architecture: ${arch}" ;;
  esac
}

validate_arch() {
  local file="$1"
  local current
  current="$(detect_arch)"

  if [[ "$file" == *"amd64"* && "$current" != "amd64" ]]; then
    die "Output file name contains 'amd64' but current arch is '${current}'."
  fi
  if [[ "$file" == *"aarch64"* && "$current" != "aarch64" ]]; then
    die "Output file name contains 'aarch64' but current arch is '${current}'."
  fi
}

default_target_image() {
  local image="$1"
  local suffix="$2"
  local timestamp="$3"

  if [[ "$image" == *@sha256:* ]]; then
    die "Cannot derive a target tag from digest image '${image}'. Please pass --target-image."
  fi

  # Extract image_name:tag from the full reference
  # e.g. vllm/vllm-openai:v0.23.0 -> vllm-openai:v0.23.0
  local last_part="${image##*/}"
  local image_name="${last_part%%:*}"
  local tag="${last_part##*:}"

  if [[ "$tag" == "$image_name" ]]; then
    die "Cannot extract tag from image '${image}'."
  fi

  if [[ -n "$suffix" ]]; then
    printf 'wings-%s:%s-%s-%s' "$image_name" "$tag" "$suffix" "$timestamp"
  else
    printf 'wings-%s:%s-%s' "$image_name" "$tag" "$timestamp"
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

  local engine_name="${engine//-/_}"
  if [[ -n "$hardware" && -n "$model" ]]; then
    printf '%s/%s_%s_%s_%s_%s_%s.tar' \
      "$output_dir" "$prefix" "$engine_name" "$version" "$hardware" "$model" "$arch"
  else
    printf '%s/%s_%s_%s_%s.tar' \
      "$output_dir" "$prefix" "$engine_name" "$version" "$arch"
  fi
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
output_dir="/nfs1/images_official"
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
      hardware="$2"
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
        amd64|aarch64) arch="$2" ;;
        *) die "Invalid arch '$2'. Supported: amd64, aarch64" ;;
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
# Auto-generate output filename
# ──────────────────────────────────────────────

if [[ -z "$save_file" ]]; then
  version="$(extract_image_tag "$base_image")"
  [[ -z "$arch" ]] && arch="$(detect_arch)"
  mkdir -p "$output_dir"
  save_file="$(generate_output_name "$prefix" "$engine" "$version" "$hardware" "$model" "$arch" "$output_dir")"
  echo "Auto-generated output: ${save_file}"
fi

if [[ -n "$save_file" ]]; then
  validate_arch "$save_file"
fi

# ──────────────────────────────────────────────
# Target image tag
# ──────────────────────────────────────────────

if [[ -z "$target_image" ]]; then
  target_image="$(default_target_image "$base_image" "$suffix" "$(date +%Y%m%d%H%M%S)")"
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

echo "Building ${target_image} from ${base_image}"
"$container_cli" "${build_args[@]}"

if [[ -n "$save_file" ]]; then
  echo "Saving ${target_image} to ${save_file}"
  "$container_cli" save -o "$save_file" "$target_image"

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
