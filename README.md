# obzorarr-docker (engels74)

## For full documentation

Detailed information and documentation available on the [master branch README](https://github.com/edbfi/obzorarr-docker/tree/master).


## Building and publishing

The nightly image pins the reviewed application revision and archive checksum in
`meta.json`, along with both native base-image digests. Bun 1.4.2 is pinned to the
same image digest for build and runtime. Dependency lockfiles and Hotio's s6/data
layout are retained.

CI builds on native amd64 and arm64 runners without publishing. Each image must
pass HTTP/version, database migration, configured UID/port, persistence across
restart/replacement, and clean shutdown checks. Evidence includes package inventory
and disposable database backups; tests do not connect to Plex.

On a channel checkout, `./build.sh amd64` or `./build.sh arm64` runs the same local
validation. Metadata is parsed as data, never evaluated as shell commands.

Publication is manual from the matching channel and requires successful final CI,
two tested architecture archives and unchanged workflow/branch/image revisions.
It does not depend on GitHub branch-protection settings. Source or base updates
must be reviewed with fresh checksums and native CI before publication.

This migration updates nightly first. Stable 0.1.11 and the historical PR channel
are retained separately. Their legacy workflows remain disabled pending migration;
do not merge channel branches wholesale or relabel nightly as stable.
