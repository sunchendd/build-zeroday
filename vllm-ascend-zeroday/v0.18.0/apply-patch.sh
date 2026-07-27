#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/../common/apply-patch-lib.sh"

apply_patch /vllm-workspace/vllm \
  "$script_dir/vllm_indexcache_port_20260520.patch"

apply_patch /vllm-workspace/vllm-ascend \
  "$script_dir/vllm_ascend_indexcache_port_20260520.patch"
