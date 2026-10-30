# silo-qualify

Re-runnable qualification harness for the MinIO → Silo swap. Results and the pin recommendation: `docs/silo-qualification.md`.
Needs docker, git, python3 (+PyYAML), helm. Throwaway credentials are generated into `$SQ_OUT` (default `./out`, git-ignored);
no production secrets, no cluster access. Containers/volumes/network are prefixed `sq-`; the scripts remove every `sq-*`
container on start and exit, so do not run two scripts at once. Images are pinned by digest in `lib.sh`.
macOS note: scripts avoid bash 4 features (`mapfile`).
