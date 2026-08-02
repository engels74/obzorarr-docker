# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

Packaging-only repository for the `obzorarr` Docker image. **No application source lives here.** The app is fetched as a tarball from `github.com/engels74/obzorarr` during the build (`curl .../archive/${VERSION}.tar.gz`). Application behaviour changes belong upstream; this repo controls only the image, its s6 runtime services, and its build/release metadata.

## Branches Are Release Channels

`release` is the default branch. Every branch except `workflows` is built and published as its own image tag, each carrying its own `meta.json`:

| Branch    | `version` resolved from                         | `latest` |
|-----------|-------------------------------------------------|----------|
| `release` | newest git tag of `engels74/obzorarr`            | `true`   |
| `nightly` | HEAD commit SHA of upstream `main`               | `false`  |
| `pr`      | PR head SHA; adds `branch` / `version_branch`    | `false`  |

Consequences:

- A Dockerfile or s6 fix applies **only to the branch you commit it to**. Port it to the other channels deliberately.
- Do not merge channels wholesale. `README.md`, `renovate.json`, `build.sh`, and `meta.json` legitimately differ per branch (`renovate.json` exists only on `release`; `nightly` has a stub README).

## Essential Commands

There is no unit-test suite, linter, or type-checker. CI validation is the multi-arch image build plus an HTTP smoke test.

```sh
./build.sh amd64        # local build -> image tag "obzorarr-docker-amd64"
./build.sh arm64
```

`build.sh` requires `docker`, `jq`, and a git checkout (the image name is the repo directory basename). On `release` it passes `--secret id=GIT_AUTH_TOKEN,env=TOKEN`, so export `TOKEN` if the build needs an authenticated fetch. It does **not** set `IMAGE_STATS`/`PACKAGE_VERSION`, which CI injects.

```sh
jq -r 'to_entries[] | [(.key|ascii_upcase),.value] | join("=")' < meta.json   # preview build args
eval "$(jq -r '.version__command' < meta.json)"                              # re-run a version probe
docker run --rm --network host obzorarr-docker-amd64                         # then: curl -fsSL http://localhost:3000
```

That last pair reproduces the CI smoke test, which curls `meta.json`'s `test_url` with retries and fails the build if it never answers.

## meta.json Drives Everything

- Every key becomes an uppercase `--build-arg`. Only `VERSION`, `UPSTREAM_IMAGE`, `UPSTREAM_TAG_SHA`, and `IMAGE_STATS` are consumed by the Dockerfiles; CI reads the rest directly.
- `latest` publishes `:latest`; `test_amd64` / `test_arm64` / `test_url` gate the smoke test; `description` is shown on the tags website.
- `*__command` keys are shell snippets `eval`'d hourly by the update workflow; the result is written back to the same key minus the suffix. **To change how a version is discovered, edit the `__command` value, not the resolved value** — the resolved value is overwritten on the next run.
- `version`, `upstream_tag_sha`, `packages_hash`, and `packages.txt` are bot-maintained. Hand edits are lost. `packages.txt` is empty here by design: the workflow strips every package already present in the upstream base image's `packages.txt`.

## CI Is Not In This Repository

`.github/workflows/call-build.yml` and `call-update.yml` are thin callers into `engels74/base-image/.github/workflows/{build-on-call,update-on-call}.yml@workflows`. All build, publish, manifest, tagging, and notification logic lives there. Do not add build steps to this repo — change the shared workflow in `base-image` instead.

Any push to any branch other than `workflows` triggers a full build and publish. The `packages.txt` commit made by a build is marked `[skip ci]`; the hourly `meta.json` update commit is not, so an upstream version bump auto-triggers a rebuild.

## Container Runtime Contract (base-image:alpinevpn)

`APP_DIR=/app`, `CONFIG_DIR=/config`, the `XDG_*` vars, and the `hotio` user (uid/gid 1000) are defined by `ghcr.io/engels74/base-image:alpinevpn`. Use the variables; do not redefine them or hardcode `/app` / `/config`.

- Source shared helpers with `source /etc/s6-overlay/scripts/bash-functions`.
- `init-setup` and `init-wireguard` are upstream services this image orders itself against.
- The app must drop privileges: `exec s6-setuidgid hotio bun start`.
- Persist state under `CONFIG_DIR`. The Dockerfile replaces `${APP_DIR}/data` with a symlink to `${CONFIG_DIR}/data`, and `init-setup-app/run` chowns it to `hotio`.

## Adding or Changing an s6 Service

1. Create `root/etc/s6-overlay/s6-rc.d/<name>/type` containing `oneshot` or `longrun`.
2. Add `run` starting with `#!/command/with-contenv bash`. For `oneshot`, also add `up` containing the absolute in-container path to that `run` (see `init-setup-app/up`).
3. Declare ordering with empty marker files at `<name>/dependencies.d/<dependency>`.
4. Enable the service with an empty marker at `root/etc/s6-overlay/user-bundles.d/user/contents.d/<name>`. **Not** `s6-rc.d/user/contents.d/` — that location stopped working at s6-overlay 3.2.3.1 (commit `b8a1b6c`) and the service silently never starts.
5. No `chmod` needed; both Dockerfiles end with `find /etc/s6-overlay/s6-rc.d -name "run*" -execdir chmod +x {} +`.

## Critical Gotchas

- **The two Dockerfiles must be edited together.** `linux-amd64.Dockerfile` and `linux-arm64.Dockerfile` are near-identical; the only intended difference is arm64's builder installing `build-base python3` for native module compilation. CI builds each on its own runner and a divergence ships a broken arch.
- **Keep the header lines** `# syntax=docker/dockerfile:1` and `# check=skip=InvalidDefaultArgInFrom`. The second suppresses the BuildKit check that `FROM ${UPSTREAM_IMAGE}:${UPSTREAM_TAG_SHA}` would otherwise fail.
- **Changing the default port touches four places**: the Dockerfile `ENV PORT=.../WEBUI_PORTS=...`, the `!= "3000"` guard in `init-setup-app/run` that rewrites `WEBUI_PORTS` into `/var/run/s6/container_environment/`, `test_url` in `meta.json`, and the compose example in `README.md`. Miss `test_url` and the smoke test fails the build.
- **s6 marker files are empty on purpose** (`dependencies.d/*`, `user-bundles.d/.../contents.d/*`). Create them with `touch`; adding content is not how s6 reads them.

## Conventions

- Conventional Commits for human commits (`fix:`, `chore(renovate):`). Bot commits use `Modified: <files>` — do not imitate that format.
- `.gitattributes` forces `eol=lf`; shell scripts must stay LF-only.
- New run scripts keep the `# shellcheck shell=bash` and `# shellcheck source=/dev/null` directives used by the existing ones.

## Additional Documentation

- `README.md` — user-facing compose example. Read and update whenever you change the exposed port, volume layout, or environment variables. Note it is branch-specific.
- `engels74/base-image` branch `alpinevpn` — read when you need to know what the base layer already provides (env vars, users, existing s6 services) before adding it here.
- `engels74/base-image` branch `workflows` — read before changing anything about how the image is built, tagged, or published.
