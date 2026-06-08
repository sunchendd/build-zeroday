ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ARG PATCH_DIR
ARG PATCH_SCRIPT=apply-patch.sh

ENV PIP_INDEX_URL=${PIP_INDEX_URL}

COPY vllm-ascend-zeroday /root/build-zeroday/vllm-ascend-zeroday
COPY vllm-zeroday /root/build-zeroday/vllm-zeroday

RUN set -eux; \
    patch_dir="/root/build-zeroday/${PATCH_DIR}"; \
    if [ ! -d "${patch_dir}" ]; then \
      echo "Patch directory not found: ${patch_dir}" >&2; \
      exit 1; \
    fi; \
    if [ -f "${patch_dir}/apt-packages.txt" ]; then \
      if ! command -v apt-get >/dev/null 2>&1; then \
        echo "apt-packages.txt exists but apt-get is not available in the base image" >&2; \
        exit 1; \
      fi; \
      apt-get update; \
      xargs -r apt-get install -y --no-install-recommends < "${patch_dir}/apt-packages.txt"; \
      rm -rf /var/lib/apt/lists/*; \
    fi; \
    if [ -f "${patch_dir}/requirements.txt" ]; then \
      if ! command -v python3 >/dev/null 2>&1; then \
        echo "requirements.txt exists but python3 is not available in the base image" >&2; \
        exit 1; \
      fi; \
      python3 -m pip install --no-cache-dir -r "${patch_dir}/requirements.txt"; \
    fi; \
    runner="sh"; \
    if command -v bash >/dev/null 2>&1; then runner="bash"; fi; \
    if [ -f "${patch_dir}/install-deps.sh" ]; then \
      chmod +x "${patch_dir}/install-deps.sh"; \
      cd "${patch_dir}"; \
      "${runner}" "./install-deps.sh"; \
    fi; \
    if ! command -v git >/dev/null 2>&1; then \
      echo "git is required to apply patches but is not available in the base image" >&2; \
      exit 1; \
    fi; \
    if ! command -v bash >/dev/null 2>&1; then \
      echo "bash is required to run patch scripts but is not available in the base image" >&2; \
      exit 1; \
    fi; \
    if [ ! -f "${patch_dir}/${PATCH_SCRIPT}" ]; then \
      echo "Patch script not found: ${patch_dir}/${PATCH_SCRIPT}" >&2; \
      exit 1; \
    fi; \
    chmod +x "${patch_dir}/${PATCH_SCRIPT}"; \
    cd "${patch_dir}"; \
    bash "./${PATCH_SCRIPT}"
