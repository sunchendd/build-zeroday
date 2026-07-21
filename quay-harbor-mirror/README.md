# quay-harbor-mirror

Mirrors release images from the public registries into the local Harbor on
`70.189.16.9`, so the (offline) build hosts can pull them locally.

| Source | Mirrored into | Floor (init) |
|---|---|---|
| `quay.io/ascend/vllm-ascend` (+rc, -a3/-310p/-openeuler flavors) | `70.189.16.9/ascend/vllm-ascend` | `v0.21.0` |
| `vllm/vllm-openai` (Docker Hub, GA releases) | `70.189.16.9/vllm/vllm-openai` | `v0.21.0` |

Each tag is a **multi-arch manifest** (amd64 + aarch64): `docker pull
70.189.16.9/ascend/vllm-ascend:<tag>` resolves to the right arch on each host
(or use `--platform`). New releases are mirrored automatically and announced to a
Feishu group; the one-time init does **not** announce.

## Why the orchestrator runs on 16.9 (not the DMZ)

The DMZ (`172.24.194.3`, aarch64) has internet; `70.189.16.9` has Harbor but no
internet. The firewall between them is **one-way**: `16.9 → DMZ` SSH works, but
the DMZ cannot open any TCP connection to 16.9 (so it cannot push to Harbor).
Therefore the loop runs on 16.9, which reaches both the DMZ (to pull) and Harbor
(to push). Internet downloads always happen on the DMZ; notifications too (16.9
is offline, so the Feishu webhook is posted from the DMZ).

```
 16.9 (orchestrator, Harbor, offline)
   │  (1) discover tags  (2) docker pull --platform + docker save -> .tar
   ├──────────────────────────────────────────────────────────► DMZ (aarch64, online) ──► quay.io / GitHub / Docker Hub mirror
   │  (3) rsync .tar back                                           (amd64 cross-saved, arm64 native)
   │  (4) skopeo copy docker-archive:.tar -> Harbor (per arch, tags -amd64/-aarch64)
   │  (5) curl PUT a manifest list -> the multi-arch tag
   ▼
 Harbor (localhost)                       Feishu ◄── notify (via DMZ, cron runs only)
```

Environment-specific gotchas baked into the design:
- **`docker push`/`docker manifest` on 16.9 are unusable**: the docker daemon has
  `HTTP_PROXY=90.90.99.124:3128` (dead) and no `NO_PROXY`, so it proxies all registry
  traffic and pushes to local Harbor never arrive. So the push uses **skopeo** (reads the
  docker-save `.tar` directly and uploads from the shell — no daemon, no proxy) and the
  multi-arch manifest list is PUT via **curl** (`docker manifest` forces HTTPS:443, refused).
  skopeo is installed on 16.9 from an rpm fetched via the DMZ.
- **Docker Hub's catalog API is blocked on the DMZ**, but `docker pull` works through
  the daemon's registry-mirrors. So vllm release tags are discovered from the
  **GitHub releases API** and pulled through the mirror (`docker.m.daocloud.io`).
- The DMZ helper redirects every `docker` command's stdout to stderr, so the
  orchestrator captures only the saved `.tar` path (docker pull progress would
  otherwise corrupt it).

## Files & locations

On **16.9** (`/usr/local/...`):
- `bin/quay-harbor-mirror.sh` — orchestrator.
- `etc/quay-harbor-mirror/config.sh` — sources, filters, floors, webhook. **Edit this to change scope.**
- `var/lib/quay-harbor-mirror/state.json` — which tags are already mirrored.
- `var/log/quay-harbor-mirror.log` — cron log.
- `/etc/cron.d/quay-harbor-mirror` — the schedule (every 30 min, flock-guarded).
- `/AI/images/0DAY/quay-mirror/stage/` — transient staging for `.tar`s (big disk).
- `/usr/bin/skopeo` — pushes images to Harbor without the docker daemon (installed from an rpm fetched via the DMZ from `repo.xfusion.com`).

On the **DMZ** (`172.24.194.3`):
- `/usr/local/bin/dmz-mirror-helper.sh` — `discover` / `pull` / `notify`.
- `/Maas/docker_space/quay-mirror/` — transient `.tar`s (cleaned after each tag).

In this repo (`quay-harbor-mirror/`): `config.sh`, `quay-harbor-mirror.sh`,
`dmz-mirror-helper.sh`, `quay-harbor-mirror.cron`, `README.md`.

## Managing the job

### Commands (run on 16.9)
```bash
quay-harbor-mirror.sh discover                          # dry-run: what would be mirrored now
quay-harbor-mirror.sh backfill                          # one-shot init: mirror all >= floor (NO notify)
quay-harbor-mirror.sh run                               # same as cron: mirror all >= floor (NOTIFIES new)
quay-harbor-mirror.sh mirror <srcref> <tag>             # ad-hoc single tag (no floor, no notify)
```
`<srcref>` is the pull ref without tag, e.g. `quay.io/ascend/vllm-ascend` or `vllm/vllm-openai`.

### Start / stop the automatic schedule
```bash
# enable (every 30 min; skips a cycle if the previous run is still busy)
install -m 0644 quay-harbor-mirror.cron /etc/cron.d/quay-harbor-mirror
# disable
rm /etc/cron.d/quay-harbor-mirror
# run one cycle manually right now (same as a cron tick, with notification)
quay-harbor-mirror.sh run
```

### Where to look
- **Log:** `tail -f /var/log/quay-harbor-mirror.log`
- **State:** `cat /var/lib/quay-harbor-mirror/state.json` (keys = `srcref:tag` already mirrored)
- **In-flight:** `pgrep -af quay-harbor-mirror` on 16.9; `pgrep -af dmz-mirror-helper` on the DMZ.
- **flock:** a run in progress holds `/var/lock/quay-harbor-mirror.lock`; the next tick skips until it's free.

### Changing what is mirrored
Edit `/usr/local/etc/quay-harbor-mirror/config.sh` on 16.9, then the next cron tick picks it up:
- **Add/remove a source or change the tag filter / floor:** edit `SOURCES` (each line is
  `name~srcref~project~reponame~filter~discover~min`; `~` is the field separator so `|` is free inside the regex).
- **Re-mirror a tag** that is already in state: `jq 'del(.mirrored["<srcref>:<tag>"])' state.json > t && mv t state.json`,
  then `quay-harbor-mirror.sh mirror <srcref> <tag>` (or wait for the next tick).
- **Mirror an old version below the floor:** `quay-harbor-mirror.sh mirror <srcref> <tag>` (ignores the floor).
- **Notifications:** set `FEISHU_WEBHOOK` (empty = off). Only `run` notifies; `backfill` and `mirror` do not.

### Deploy / update the scripts
```bash
# from a machine with sshpass + access to 16.9
scp config.sh quay-harbor-mirror.sh root@70.189.16.9:/tmp/
ssh root@70.189.16.9 'install -m 0644 /tmp/config.sh /usr/local/etc/quay-harbor-mirror/config.sh
                      install -m 0755 /tmp/quay-harbor-mirror.sh /usr/local/bin/quay-harbor-mirror.sh'
scp dmz-mirror-helper.sh root@70.189.16.9:/tmp/   # then from 16.9:
ssh root@70.189.16.9 'scp /tmp/dmz-mirror-helper.sh root@172.24.194.3:/usr/local/bin/ && chmod +x'   # push to DMZ
```

## Verify (on 16.9)
```bash
quay-harbor-mirror.sh discover                                    # what run would mirror
# multi-arch manifest in Harbor (docker manifest inspect hits the dead proxy; use skopeo or the API):
skopeo --insecure-policy inspect --tls-verify=false \
  docker://70.189.16.9/ascend/vllm-ascend:v0.18.0 | jq '.Manifests[].Platform'
curl -s -u admin:admin@123123 -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
  http://70.189.16.9/v2/ascend/vllm-ascend/manifests/v0.18.0 | jq '.manifests[].platform'
```
> **Pulling from Harbor on a build host:** `docker pull`/`docker manifest` on a host whose
> docker daemon uses the dead proxy (16.9) will fail the same way pushes do. Either pull with
> `skopeo copy docker://70.189.16.9/... oci-archive:out.tar --src-tls-verify=false` then `docker load`,
> or add `70.189.16.9` to that host's docker daemon `NO_PROXY` (needs a docker restart).

## Rollback
```bash
rm /etc/cron.d/quay-harbor-mirror                                            # stop the cron
rm /usr/local/bin/quay-harbor-mirror.sh /usr/local/etc/quay-harbor-mirror/config.sh
ssh root@172.24.194.3 rm -f /usr/local/bin/dmz-mirror-helper.sh
# mirrored images stay in Harbor; remove via Harbor UI/API if desired.
```

## Troubleshooting
- **A tag keeps failing:** check the log; the DMZ may have run out of disk
  (`df -h /Maas/docker_space`) — these images are 15–18 GB each. It is retried every cycle until it succeeds.
- **`discover` empty for a source:** the DMZ could not reach quay/GitHub that cycle; it retries next tick.
- **No Feishu notification:** the DMZ must reach `open.feishu.cn`; check
  `ssh root@172.24.194.3 'curl -s -o /dev/null -w %{http_code} https://open.feishu.cn/'`.
- **Push fails on 16.9:** Harbor creds live in `/root/.docker/config.json` and `70.189.16.9`
  must be in `/etc/docker/daemon.json` `insecure-registries` (both already set). Do **not** restart docker on 16.9 (it takes down Harbor).
