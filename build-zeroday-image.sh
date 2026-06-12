#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build-zeroday-image.sh -b BASE_IMAGE -e ENGINE -v PATCH_VERSION [-t TARGET_IMAGE] [-o OUTPUT_TAR] [options]

Required:
  -b, --base-image IMAGE     Input/base image to patch, for example quay.io/ascend/vllm-ascend:v0.19.1rc1
  -e, --engine ENGINE        Patch engine: vllm or vllm-ascend
  -v, --patch-version VER    Patch version directory, for example 0.19.1rc1

Options:
  -t, --target-image IMAGE   Output image tag after patching. Defaults to BASE_IMAGE with "-zeroday-YYYYmmddHHMMSS" appended to its tag.
  -o, --output-tar FILE      Save the built image to a tar file
  -f, --dockerfile FILE      Dockerfile path. Defaults to ./Dockerfile
  -s, --suffix SUFFIX        Suffix used when TARGET_IMAGE is omitted. Defaults to zeroday
      --patch-script FILE    Patch script name inside the resolved patch directory. Defaults to apply-patch.sh
      --save FILE            Alias for --output-tar
      --push                 Push the built image after successful build
      --no-cache             Build without cache
  -h, --help                 Show this help

Examples:
  ./build-zeroday-image.sh \
    -b quay.io/ascend/vllm-ascend:v0.19.1rc1 \
    -e vllm-ascend \
    -v 0.19.1rc1 \
    -t quay.io/ascend/vllm-ascend:v0.19.1rc1-a3

  ./build-zeroday-image.sh \
    -b swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/vllm/vllm-openai:v0.22.0 \
    -e vllm \
    -v 0.22.0 \
    -o vllm-openai-v0.22.0-zeroday.tar
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

validate_arch() {
  local file="$1"
  local arch
  arch="$(uname -m)"

  if [[ "$file" == *"amd64"* && "$arch" != "x86_64" ]]; then
    die "Output file name contains 'amd64' but current architecture is '${arch}' (expected x86_64)."
  fi

  if [[ "$file" == *"aarch64"* && "$arch" != "aarch64" ]]; then
    die "Output file name contains 'aarch64' but current architecture is '${arch}' (expected aarch64)."
  fi
}

default_target_image() {
  local image="$1"
  local suffix="$2"
  local timestamp="$3"

  if [[ "$image" == *@sha256:* ]]; then
    die "Cannot derive a target tag from digest image '${image}'. Please pass --target-image."
  fi

  local last_part="${image##*/}"
  if [[ "$last_part" == *:* ]]; then
    printf '%s-%s-%s' "$image" "$suffix" "$timestamp"
  else
    printf '%s:%s-%s' "$image" "$suffix" "$timestamp"
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

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base_image=""
target_image=""
engine=""
patch_version=""
patch_dir=""
patch_script="apply-patch.sh"
dockerfile="${repo_root}/Dockerfile"
suffix="zeroday"
save_file=""
push_image=0
no_cache=0

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
    --push)
      push_image=1
      shift
      ;;
    --no-cache)
      no_cache=1
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

[[ -n "$base_image" ]] || die "Missing --base-image"
[[ -n "$engine" ]] || die "Missing --engine"
[[ -n "$patch_version" ]] || die "Missing --patch-version"
[[ "$patch_version" != *"/"* && "$patch_version" != *".."* ]] || die "Patch version must be a version directory name, not a path: $patch_version"
[[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"

engine_dir="$(resolve_engine_dir "$engine")"
[[ -d "${repo_root}/${engine_dir}" ]] || die "Patch engine directory not found: ${repo_root}/${engine_dir}"

patch_dir="${engine_dir}/${patch_version}"
[[ -d "${repo_root}/${patch_dir}" ]] || die "Patch version directory not found: ${repo_root}/${patch_dir}"
[[ -f "${repo_root}/${patch_dir}/${patch_script}" ]] || die "Patch script not found: ${repo_root}/${patch_dir}/${patch_script}"

if [[ -z "$target_image" ]]; then
  target_image="$(default_target_image "$base_image" "$suffix" "$(date +%Y%m%d%H%M%S)")"
fi

if [[ -n "$save_file" ]]; then
  validate_arch "$save_file"
fi

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

build_args=(
  build
  -f "$dockerfile"
  --build-arg "BASE_IMAGE=$base_image"
  --build-arg "PATCH_DIR=$patch_dir"
  --build-arg "PATCH_SCRIPT=$patch_script"
  -t "$target_image"
)

if [[ "$no_cache" -eq 1 ]]; then
  build_args+=(--no-cache)
fi

build_args+=("$repo_root")

echo "Building ${target_image} from ${base_image} with ${patch_dir}/${patch_script}"
"$container_cli" "${build_args[@]}"

if [[ -n "$save_file" ]]; then
  echo "Saving ${target_image} to ${save_file}"
  "$container_cli" save -o "$save_file" "$target_image"
fi

if [[ "$push_image" -eq 1 ]]; then
  echo "Pushing ${target_image}"
  "$container_cli" push "$target_image"
fi

echo "Done: ${target_image}"
