#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/../common/apply-patch-lib.sh"

apply_patch /vllm-workspace/vllm-ascend \
  "$script_dir/vllm_ascend_mtp_prefix_cache_zeroer_20260611.patch"
