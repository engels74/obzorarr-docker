# AGENTS.md

This file provides guidance to AI coding agents when working with code in this
repository.

## Scope

Packaging-only repository for the `obzorarr` Docker image. No application source lives here — both
Dockerfiles fetch `https://github.com/engels74/obzorarr/archive/${VERSION}.tar.gz` at build time.
Application behaviour changes belong in `engels74/obzorarr`; this repo owns only the image, its s6
services, and its build metadata.

## Branches are release channels

`release` is the default branch; `nightly` and `pr` are separate channels, each with its own
`meta.json`. There is no `master` branch (the `blob/master/...` links in `README.md` are stale).

| Branch    | `version` resolves to                                | `latest` |
|-----------|------------------------------------------------------|----------|
| `release` | newest tag of `engels74/obzorarr`                    | `true`   |
| `nightly` | HEAD commit SHA of upstream `main`                   | `false`  |
| `pr`      | upstream PR head SHA; adds `branch`/`version_branch` | `false`  |

A Dockerfile or s6 fix lands only on the branch you commit it to — port it to the other channels
explicitly. Do not merge branches wholesale: `README.md`, `renovate.json` (release only), and
`meta.json` legitimately differ, and `pr` carries an extra `update-versions.sh`.

## Commands

This repo has no test suite, linter, or typechecker. Validation is the image build plus an HTTP
smoke test.

```sh
./build.sh amd64     # -> local image "obzorarr-docker-amd64"; needs docker + jq + a git checkout
./build.sh arm64
jq -r 'to_entries[]|[(.key|ascii_upcase),.value]|join("=")' < meta.json  # build args build.sh sends
eval "$(jq -r '.version__command' < meta.json)"                         # re-run a version probe
```

Reproduce CI's smoke test: `docker run --rm --network host obzorarr-docker-amd64`, then
`curl -fsSL http://localhost:3000` (the `test_url` from `meta.json`).

`build.sh` names the image after the repo directory and passes `--secret id=GIT_AUTH_TOKEN,env=TOKEN`,
which no Dockerfile mounts. CI additionally injects `IMAGE_STATS` and `PACKAGE_VERSION`.

## meta.json is the build contract

- Every key becomes an uppercase `--build-arg`. Only `VERSION`, `UPSTREAM_IMAGE`,
  `UPSTREAM_TAG_SHA`, and `IMAGE_STATS` are consumed by the Dockerfiles; CI reads the rest itself.
- `*__command` values are shell snippets `eval`'d hourly by the update workflow, which writes the
  result back to the same key minus the suffix. To change how a version is discovered, edit the
  `__command` value — the resolved value is overwritten on the next run.
- `version`, `upstream_tag_sha`, and `packages_hash` are bot-maintained; hand edits are lost.
- `latest: true` publishes `:latest`; `test_amd64`/`test_arm64`/`test_url` gate the smoke test;
  `hide: true` keeps the tag off the tags website.

`packages.txt` is bot-generated and empty here by design — CI strips every package already present
in the base image's `packages.txt`. Never hand-edit it.

## CI lives in another repository

`.github/workflows/call-build.yml` and `call-update.yml` are thin callers into
`engels74/base-image/.github/workflows/{build-on-call,update-on-call}.yml@workflows`. All build,
publish, manifest, tagging, and notification logic is there — change that repo, not this one.

Any push to any branch other than `workflows` triggers a full build and publish. The `packages.txt`
commit CI makes is marked `[skip ci]`; the hourly `meta.json` commit is not, so an upstream version
bump auto-triggers a rebuild.

## Container runtime contract

`APP_DIR=/app`, `CONFIG_DIR=/config`, the `XDG_*` vars, `UMASK`, and the `hotio` user (uid/gid 1000)
are defined by `ghcr.io/engels74/base-image:alpinevpn`. Use the variables; do not redefine them or
hardcode `/app` / `/config`.

- Shared bash helpers: `source /etc/s6-overlay/scripts/bash-functions` (`log_inf`, `mask`, ...).
- `init-setup` and `init-wireguard` are base-image services this image orders itself against.
- Services drop privileges: `exec s6-setuidgid hotio bun start`.
- Persistent state lives under `CONFIG_DIR`. The Dockerfile replaces `${APP_DIR}/data` with a
  symlink to `${CONFIG_DIR}/data`, and `init-setup-app/run` chowns it to `hotio`.

## Adding or changing an s6 service

1. `root/etc/s6-overlay/s6-rc.d/<name>/type` containing `oneshot` or `longrun`.
2. `run` starting with `#!/command/with-contenv bash`; for `oneshot` also add `up` holding the
   absolute in-container path of that `run` (see `init-setup-app/up`).
3. Ordering: an empty marker file at `<name>/dependencies.d/<dependency>`.
4. Enable it with an empty marker at `root/etc/s6-overlay/user-bundles.d/user/contents.d/<name>` —
   not `s6-rc.d/user/contents.d/`, which stopped working at s6-overlay 3.2.3.1 and makes the service
   silently never start (commit `b8a1b6c`).
5. No `chmod` needed; both Dockerfiles end with
   `find /etc/s6-overlay/s6-rc.d -name "run*" -execdir chmod +x {} +`.

Marker files under `dependencies.d/` and `contents.d/` are empty on purpose — create them with
`touch`; content is not how s6 reads them.

## Gotchas

- **Edit both Dockerfiles together.** `linux-amd64.Dockerfile` and `linux-arm64.Dockerfile` are
  identical except that arm64's builder stage also installs `build-base python3`. CI builds each on
  its own runner, so a divergence ships one broken architecture.
- **Keep both header lines.** `# check=skip=InvalidDefaultArgInFrom` suppresses the BuildKit check
  that `FROM ${UPSTREAM_IMAGE}:${UPSTREAM_TAG_SHA}` would otherwise fail.
- **Changing the port touches four places:** `ENV PORT=`/`WEBUI_PORTS=` in both Dockerfiles, the
  `!= "3000"` guard in `init-setup-app/run` that rewrites `WEBUI_PORTS` into
  `/var/run/s6/container_environment/`, `test_url` in `meta.json`, and the compose example in
  `README.md`. Miss `test_url` and the smoke test fails the build.
- Human commits use Conventional Commits. `Modified: <files>` commits are the bot's — don't imitate
  that format.

## Reference

- `README.md` — user-facing compose example. Update it whenever you change the exposed port, volume
  layout, or environment variables. It is branch-specific.
- `engels74/base-image` branch `alpinevpn` — what the base layer already provides (env vars, users,
  existing s6 services). Read before adding something that may already exist.
- `engels74/base-image` branch `workflows` — read before changing how the image is built, tagged, or
  published.
