# Release checklist

Maintainer steps for cutting a new image release. Images are versioned by the
upstream Angie release plus a packaging build number — `<angie>-build<N>` — not
by semantic versioning of the packaging itself (see `CHANGELOG.md`). A **build
bump** repackages the same Angie version (base-image bump, entrypoint fix,
`angie-ctl` update); an **Angie version bump** changes `ANGIE_VERSION` and resets
the build number to `build1`.

## 1. Decide the kind of bump

- Repackaging the same Angie version → increment the build number only.
- New upstream Angie → bump `ANGIE_VERSION`, reset to `build1`.

For an Angie bump, confirm the target version from a **live source**, never from
memory: the [version history](https://en.angie.software/angie/docs/oss_changes/)
or [`webserver-llc/angie` releases](https://github.com/webserver-llc/angie/releases).

## 2. Edit the pins (Angie version bump only)

- `alpine/Dockerfile` — `ARG ANGIE_VERSION=` (alpine pulls modules with the
  fuzzy `=~${ANGIE_VERSION}` apk operator).
- `debian/Dockerfile` — `ARG ANGIE_VERSION=` (the build resolves the exact apt
  package version matching it).
- Keep both Dockerfiles in sync. The `angie-ctl` pin (`ANGIE_CTL_COMMIT`) is
  independent of the Angie version — bump it only when intended.

## 3. Actualize the docs that hard-code the tag

The current tag is embedded in examples and changelog entries, so update all of:

- `README.md` / `README.ru.md` — example tags in the tag table
  (`<angie>-build<N>-alpine`, `<angie>-alpine`, the `…-unprivileged` example).
- `CHANGELOG.md` / `CHANGELOG.ru.md` — see step 4.
- `docs/dockerhub-overview.md` — example tags in **both** the EN and RU tables.
  Nothing pushes this file automatically; it is the source for the Docker Hub
  repository description, updated by hand (see step 6).
- `docs/limitations.md` / `docs/limitations.ru.md` — the `…-debian` pin example.
- `docs/configuration.md` / `docs/configuration.ru.md` — the `IMAGE_VERSION`
  example value.
- `CLAUDE.md` — review for any version/tag reference (today only the meta-mention
  in the *Releasing* section, no literal version/tag string — check anyway).

This list is a guide, not a guarantee. Catch every occurrence by grepping for the
outgoing tag (the build you are replacing), e.g.
`rg -F '<angie>-build<N-1>'` — every hit outside the historical `CHANGELOG`
entries must move to the new build.

## 4. CHANGELOG

In both `CHANGELOG.md` and `CHANGELOG.ru.md`:

- Move the accumulated `[Unreleased]` / `[Не выпущено]` entries into a new
  `## [<angie>-build<N>] - <YYYY-MM-DD>` section.
- Update the footer links: repoint `[Unreleased]` (`[Не выпущено]` in the RU
  file) to `…/compare/v<angie>-build<N>...HEAD` and add
  `[<angie>-build<N>]: …/releases/tag/v<angie>-build<N>`.
- Keep the EN and RU entries factually identical (same versions, dates, names).
- The `## [<angie>-build<N>]` header must match the tag **exactly** (modulo the
  leading `v`): the release workflow lifts the GitHub Release notes from this
  section by literal prefix match (step 6) and fails the release if no section
  matches.

## 5. Verify

```bash
make lint            # shell, docker, config, ci, docs (offline)
make lint-docs-links # markdown link check (network)
make build           # all four images
make test            # smoke-test all four images
```

`make lint-docs-links` will report the new `[<angie>-build<N>]` and `[Unreleased]`
footer links from step 4 as `404` — the `compare/…` and `releases/tag/…` URLs do
not resolve until the tag is pushed in step 6. That is expected; the only failures
allowed here are exactly those new-build URLs. Anything else is a real broken link.

## 6. Tag and publish

- Land the changes on `develop`, then merge to `main` (the PR target).
- Tag the merge commit on `main` `v<angie>-build<N>` and push the tag. The format
  is **validated** by CI (`vX.Y.Z-buildN`) — a malformed tag fails the release,
  it does not merely break CHANGELOG links.
- Pushing the tag triggers `.github/workflows/release.yml`, which:
  - builds and pushes all four images (alpine, debian + their unprivileged
    variants) to GHCR and Docker Hub (`6run0/angie`), publishing the immutable
    `…-build<N>` tag plus the floating tags (`latest`, `alpine`, …);
  - then creates a **GitHub Release**, lifting its notes from the matching
    `## [<angie>-build<N>]` `CHANGELOG.md` section (step 4); a header that does
    not match the tag fails this job. Re-running is safe — it is idempotent.
- The Docker Hub push needs the `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` repo
  secrets; the GitHub Release needs no extra setup.
- After publish, update the Docker Hub repository description by hand from
  `docs/dockerhub-overview.md`, then smoke-check a published image:
  `docker run --rm 6run0/angie:<angie>-build<N>-alpine angie -v`.
