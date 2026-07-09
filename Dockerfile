ARG BASE_IMAGE
ARG ENGINE
FROM ${BASE_IMAGE}

ARG ENGINE
ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ARG PIP_TRUSTED_HOST=
ARG PATCH_DIR
ARG PATCH_SCRIPT=apply-patch.sh
ARG SKIP_PATCH

ENV PIP_INDEX_URL=${PIP_INDEX_URL}
ENV PIP_TRUSTED_HOST=${PIP_TRUSTED_HOST}

COPY vllm-ascend-zeroday /root/build-zeroday/vllm-ascend-zeroday
COPY vllm-zeroday /root/build-zeroday/vllm-zeroday
COPY engine-requirements /root/build-zeroday/engine-requirements

RUN set -eux; \
    engine_req="/root/build-zeroday/engine-requirements/${ENGINE}.txt"; \
    if [ -f "${engine_req}" ]; then \
      if ! command -v python3 >/dev/null 2>&1; then \
        echo "Engine requirements file exists but python3 is not available" >&2; \
        exit 1; \
      fi; \
      echo "Installing engine requirements from ${engine_req}"; \
      python3 -m pip install --no-cache-dir -r "${engine_req}"; \
    fi; \
    if [ "${SKIP_PATCH:-}" = "true" ]; then \
      echo "SKIP_PATCH is set, skipping patch operations."; \
    else \
      patch_dir="/root/build-zeroday/${PATCH_DIR}"; \
      if [ ! -d "${patch_dir}" ]; then \
        echo "Patch directory not found: ${patch_dir}" >&2; \
        exit 1; \
      fi; \
      if [ -f "${patch_dir}/apt-packages.txt" ]; then \
        if ! command -v apt-get >/dev/null 2>&1; then \
          echo "apt-packages.txt exists but apt-get is not available" >&2; \
          exit 1; \
        fi; \
        apt-get update; \
        xargs -r apt-get install -y --no-install-recommends < "${patch_dir}/apt-packages.txt"; \
        rm -rf /var/lib/apt/lists/*; \
      fi; \
      if [ -f "${patch_dir}/requirements.txt" ]; then \
        if ! command -v python3 >/dev/null 2>&1; then \
          echo "requirements.txt exists but python3 is not available" >&2; \
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
        echo "git is required to apply patches but is not available" >&2; \
        exit 1; \
      fi; \
      if ! command -v bash >/dev/null 2>&1; then \
        echo "bash is required to run patch scripts but is not available" >&2; \
        exit 1; \
      fi; \
      if [ ! -f "${patch_dir}/${PATCH_SCRIPT}" ]; then \
        echo "Patch script not found: ${patch_dir}/${PATCH_SCRIPT}" >&2; \
        exit 1; \
      fi; \
      chmod +x "${patch_dir}/${PATCH_SCRIPT}"; \
      cd "${patch_dir}"; \
      bash "./${PATCH_SCRIPT}"; \
    fi
