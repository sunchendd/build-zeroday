# shellcheck shell=bash
# Configuration for the release-image saver. Sourced by quay-harbor-mirror.sh.
# Edit filters / sources here without touching the orchestrator logic.
#
# Runs on day0-3 (single host: has internet + docker + /os_nfs). No DMZ, no Harbor:
# images are docker-pulled directly and saved as .tgz (pigz) under OUTDIR, organised
# by engine then arch.

# ---- Output layout ----
# OUTDIR/<group>/<arch>/<reponame>-<tag>-<arch>.tgz
OUTDIR="/os_nfs/06_images/openimages"

# ---- State / log ----
STATEDIR="/var/lib/quay-harbor-mirror"
STATEFILE="${STATEDIR}/state.json"
LOGFILE="/var/log/quay-harbor-mirror.log"

# ---- Sources to save ----
# Format: name~srcref~group~reponame~filter~discover~min
#   name     : label for logs
#   srcref   : pull ref without tag (what `docker pull` uses), e.g. quay.io/ascend/vllm-ascend or vllm/vllm-openai
#   group    : top-level dir under OUTDIR (vllm | vllm-ascend)
#   reponame : image name used in the .tgz filename (镜像名字), e.g. vllm-ascend / vllm-openai
#   filter   : extended regex applied locally; tag saved only if it matches. nightly/branch excluded.
#   discover : how to list tags: quay:<repo>  or  github:<github-repo>
#   min      : floor — only releases with base version >= min are saved (backfill AND cron).
#              Empty = no floor (save everything matching the filter).
# NB: Docker Hub's catalog API is blocked, but `docker pull` works through the daemon
#     mirror (docker.m.daocloud.io), so vllm release tags are discovered via the GitHub
#     releases API and pulled through the mirror.
FILTER_ASCEND='^v[0-9]+\.[0-9]+\.[0-9]+(rc[0-9]+)?((-a3|-310p|-openeuler))*$'
FILTER_VLLM='^v[0-9]+\.[0-9]+\.[0-9]+$'
SOURCES=(
  "ascend~quay.io/ascend/vllm-ascend~vllm-ascend~vllm-ascend~${FILTER_ASCEND}~quay:ascend/vllm-ascend~v0.21.0"
  "vllm~vllm/vllm-openai~vllm~vllm-openai~${FILTER_VLLM}~github:vllm-project/vllm~v0.21.0"
)

# ---- Architectures to save per tag ----
ARCHES=(amd64 aarch64)

# ---- Pull retries ----
# quay.io occasionally drops the TLS connection at the auth step (transient EOF).
# Each arch pull is attempted this many times (with backoff) before giving up.
PULL_RETRIES=3

# ---- Concurrency ----
# Worker pool size: how many tags to process in parallel within a source.
# Each tag pulls one arch at a time, so this is also the max concurrent download
# count. Raises transient /data usage to ~(<this> × image size); 2 is a safe default.
MAX_CONCURRENT=2

# ---- Local image retention on day0-3 ----
# After saving each .tgz, what to do with the just-pulled image on day0-3:
#   0  (default) remove it — free /data/docker. The .tgz on /os_nfs is the artifact.
#   1  keep it locally, retagged <srcref>:<tag>-<arch> (bare tag removed), so the
#      amd64/aarch64 copies coexist as a local cache. WARNING: each image is ~16 GB;
#      this fills /data/docker fast — only enable if day0-3 has the space.
KEEP_LOCAL=0

# ---- Notifications ----
# Feishu group bot. day0-3 has internet, so this is a direct POST. Leave empty to disable.
# Only cron `run` notifies (new images); `backfill` (the one-time init) does NOT notify.
FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/d0e73483-a7ba-48aa-8462-bea5d1cc2eb4"
