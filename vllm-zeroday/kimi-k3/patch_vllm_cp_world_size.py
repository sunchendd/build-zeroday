#!/usr/bin/env python3
"""
Patch vLLM to fix the `cp_world_size must be positive` bug
that prevents Kimi-K3 from serving on Hopper GPUs (H20/H100/H200
with SM90, only FLASH_ATTN_MLA backend supported) using the V2
Model Runner / dummy profile.

Root cause
-----------
`MLACommonImpl.__init__` in
    vllm/model_executor/layers/attention/mla_attention.py
initializes `self.dcp_world_size: int = -1`.

The MRv1 forward path repairs that lazily at
    mla_attention.py line ~736
        if self.impl.dcp_world_size == -1:
            self.impl.dcp_world_size = get_dcp_group().world_size
but the MRv2 path (Kimi-K3 + dummy mode / `VLLM_USE_V2_MODEL_RUNNER=1`)
never hits that code path, so `self.dcp_world_size` stays -1 and is
forwarded unchanged to FA3's `torch.ops._vllm_fa3_C.fwd` as
`cp_world_size=-1`. The CUDA kernel checks `cp_world_size > 0` and
throws:

    RuntimeError: cp_world_size must be positive, required by
    downstream unified code path. Use 1 if CP is not enabled.

Fix
---
Clamp `self.dcp_world_size` to >=1 at the only two call sites in
    vllm/v1/attention/backends/mla/flashattn_mla.py

    line ~184:  num_heads_q=self.num_heads * self.dcp_world_size,
                -> num_heads_q=self.num_heads * max(self.dcp_world_size, 1),
    line ~362:  cp_world_size=self.dcp_world_size,
                -> cp_world_size=max(self.dcp_world_size, 1),

Both changes are no-ops whenever DCP is actually enabled (size > 1),
and they are no-ops on the MRv1 path (where line 736 already turns
-1 into the real world_size). They only affect the MRv2 path where
-1 was leaking through.

A backup of the original file is written as `<file>.py.bak`.

Usage
-----
    python3 patch_vllm_cp_world_size.py         # patch
    python3 patch_vllm_cp_world_size.py --revert # restore backup

Exit codes: 0 success, 1 already patched / backup missing, 2 write error.
"""

from __future__ import annotations

import pathlib
import sys

TARGET = pathlib.Path(
    "/usr/local/lib/python3.12/dist-packages/vllm/v1/attention/"
    "backends/mla/flashattn_mla.py"
)
BAK = TARGET.with_suffix(".py.bak")

OLD1 = "num_heads_q=self.num_heads * self.dcp_world_size,"
NEW1 = "num_heads_q=self.num_heads * max(self.dcp_world_size, 1),"

OLD2 = "cp_world_size=self.dcp_world_size,"
NEW2 = "cp_world_size=max(self.dcp_world_size, 1),"

NEEDLE = "max(self.dcp_world_size, 1)"  # detection signature


def revert() -> int:
    if not BAK.exists():
        print(f"[patch] no backup found at {BAK}, cannot revert")
        return 1
    TARGET.write_text(BAK.read_text())
    print(f"[patch] reverted {TARGET} from backup")
    return 0


def patch() -> int:
    src = TARGET.read_text()
    if NEEDLE in src:
        print(f"[patch] {TARGET.name} already patched, skipping")
        return 1

    # Backup original (only first time)
    if not BAK.exists():
        BAK.write_text(src)
        print(f"[patch] backup saved to {BAK}")

    assert OLD1 in src, f"signature 1 not found:\n  {OLD1}"
    assert OLD2 in src, f"signature 2 not found:\n  {OLD2}"

    src = src.replace(OLD1, NEW1)
    src = src.replace(OLD2, NEW2)

    if NEEDLE not in src:
        print("[patch] post-condition check failed, refusing to write")
        return 2

    TARGET.write_text(src)
    print(f"[patch] patched {TARGET}")
    print(f"        {OLD1}\n     -> {NEW1}")
    print(f"        {OLD2}\n     -> {NEW2}")
    return 0


def main() -> int:
    if "--revert" in sys.argv[1:]:
        return revert()
    return patch()


if __name__ == "__main__":
    sys.exit(main())
