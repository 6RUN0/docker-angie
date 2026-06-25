# Build, lint and smoke-test the Angie images.
# Override image names on the command line, e.g.: make build IMAGE_ALPINE=foo

IMAGE_ALPINE ?= angie-alpine
IMAGE_DEBIAN ?= angie-debian
IMAGE_ALPINE_UNPRIV ?= $(IMAGE_ALPINE)-unprivileged
IMAGE_DEBIAN_UNPRIV ?= $(IMAGE_DEBIAN)-unprivileged
ALPINE_DOCKERFILE := alpine/Dockerfile
DEBIAN_DOCKERFILE := debian/Dockerfile

ENTRYPOINT_SCRIPTS := rootfs/docker-entrypoint.sh \
	rootfs/docker-entrypoint-common.sh \
	$(wildcard rootfs/docker-entrypoint.d/*.sh)

# nginx/angie vhost configs to security-lint with gixy.
NGINX_CONFIGS := rootfs/etc/angie/http.d/default.conf \
	rootfs-unprivileged/etc/angie/http.d/default.conf

# gixy security-lints the nginx/angie vhost configs. Upstream gixy is abandoned
# and breaks on Python >= 3.12; gixy-ng is the maintained drop-in fork (PyPI:
# gixy-ng) that runs on current Python. Override GIXY to use another install.
GIXY ?= uvx --from gixy-ng gixy

# GitHub Actions linters; both expected on PATH like shellcheck/hadolint.
# Override either to use another install (e.g. ZIZMOR='uvx zizmor').
ACTIONLINT ?= actionlint
ZIZMOR ?= zizmor

# Markdown documentation linters. typos (spelling) and rumdl (style) are offline
# and run as part of `lint`; lychee checks links over the network, so it is a
# separate on-demand target (mirroring lint-config / lint-config-full). Override
# any to use another install (e.g. RUMDL='uvx rumdl').
TYPOS ?= typos
RUMDL ?= rumdl
LYCHEE ?= lychee

# Markdown docs to lint: the docs/ tree plus the changelogs and per-locale READMEs.
DOC_DIR := docs
DOC_FILES := README.md README.ru.md CHANGELOG.md CHANGELOG.ru.md

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}'

.PHONY: lint
lint: lint-shell lint-docker lint-config lint-ci lint-docs ## Run all linters

.PHONY: lint-shell
lint-shell: ## shellcheck entrypoint (POSIX sh) and test scripts
	shellcheck -s sh $(ENTRYPOINT_SCRIPTS)
	shellcheck -s bash test/*.sh

.PHONY: lint-docker
lint-docker: ## hadolint all Dockerfiles
	hadolint $(ALPINE_DOCKERFILE) $(DEBIAN_DOCKERFILE) \
		$(ALPINE_DOCKERFILE).unprivileged $(DEBIAN_DOCKERFILE).unprivileged

# Accepted zizmor advisories are suppressed inline (`# zizmor: ignore[...]`) at
# their site, not globally, so new findings still surface at full confidence.
.PHONY: lint-ci
lint-ci: ## actionlint + zizmor of the GitHub Actions workflows
	$(ACTIONLINT) .github/workflows/*.yml
	$(ZIZMOR) --no-online-audits .github/workflows/*.yml

.PHONY: lint-config
lint-config: ## gixy security-lint of the standalone vhost config fragments
	$(GIXY) $(NGINX_CONFIGS)

.PHONY: lint-config-full
lint-config-full: ## gixy security-lint of the full effective config (needs $(IMAGE_ALPINE) built)
	@cid=$$(docker run -d \
		-e ANGIE_GZIP_ENABLED=1 -e ANGIE_BROTLI_ENABLED=1 -e ANGIE_MAP_WEBSOCKET_ENABLED=1 \
		$(IMAGE_ALPINE)); \
	tmp=$$(mktemp); ok=; \
	for _ in $$(seq 1 40); do \
		docker exec $$cid angie -T >"$$tmp" 2>/dev/null && { ok=1; break; }; \
		sleep 0.25; \
	done; \
	docker rm -f $$cid >/dev/null; \
	if [ -z "$$ok" ]; then echo "lint-config-full: angie -T did not succeed" >&2; rm -f "$$tmp"; exit 1; fi; \
	$(GIXY) "$$tmp"; rc=$$?; rm -f "$$tmp"; exit $$rc

# typos (spelling) + rumdl (style) lint of the markdown docs, offline. rumdl
# silently drops directory arguments when files are passed alongside, so the
# docs/ tree and the loose root files are checked in separate calls. MD013 (line
# length) is disabled: prose is hand-wrapped and Cyrillic columns differ from
# rumdl's 80-char default.
.PHONY: lint-docs
lint-docs: ## typos + rumdl lint of the markdown docs (offline)
	$(TYPOS) $(DOC_DIR) $(DOC_FILES)
	$(RUMDL) check --disable MD013 $(DOC_DIR)
	$(RUMDL) check --disable MD013 $(DOC_FILES)

.PHONY: lint-docs-links
lint-docs-links: ## lychee link-check of the markdown docs (hits the network)
	$(LYCHEE) --no-progress $(DOC_DIR) $(DOC_FILES)

.PHONY: build
build: build-alpine build-debian build-alpine-unprivileged build-debian-unprivileged ## Build all images

.PHONY: build-alpine
build-alpine: ## Build the Alpine image
	docker build -t $(IMAGE_ALPINE) -f $(ALPINE_DOCKERFILE) .

.PHONY: build-debian
build-debian: ## Build the Debian image
	docker build -t $(IMAGE_DEBIAN) -f $(DEBIAN_DOCKERFILE) .

.PHONY: build-alpine-unprivileged
build-alpine-unprivileged: build-alpine ## Build the rootless Alpine image
	docker build -t $(IMAGE_ALPINE_UNPRIV) -f $(ALPINE_DOCKERFILE).unprivileged \
		--build-arg BASE_IMAGE=$(IMAGE_ALPINE) .

.PHONY: build-debian-unprivileged
build-debian-unprivileged: build-debian ## Build the rootless Debian image
	docker build -t $(IMAGE_DEBIAN_UNPRIV) -f $(DEBIAN_DOCKERFILE).unprivileged \
		--build-arg BASE_IMAGE=$(IMAGE_DEBIAN) .

.PHONY: test
test: test-alpine test-debian test-alpine-unprivileged test-debian-unprivileged ## Smoke-test all images

.PHONY: test-alpine
test-alpine: build-alpine ## Smoke-test the Alpine image
	IMAGE=$(IMAGE_ALPINE) ./test/smoke.sh

.PHONY: test-debian
test-debian: build-debian ## Smoke-test the Debian image
	IMAGE=$(IMAGE_DEBIAN) ./test/smoke.sh

.PHONY: test-alpine-unprivileged
test-alpine-unprivileged: build-alpine-unprivileged ## Smoke-test the rootless Alpine image
	IMAGE=$(IMAGE_ALPINE_UNPRIV) ./test/smoke-unprivileged.sh

.PHONY: test-debian-unprivileged
test-debian-unprivileged: build-debian-unprivileged ## Smoke-test the rootless Debian image
	IMAGE=$(IMAGE_DEBIAN_UNPRIV) ./test/smoke-unprivileged.sh

.PHONY: clean
clean: ## Remove the built images
	-docker rmi $(IMAGE_ALPINE) $(IMAGE_DEBIAN) $(IMAGE_ALPINE_UNPRIV) $(IMAGE_DEBIAN_UNPRIV)
