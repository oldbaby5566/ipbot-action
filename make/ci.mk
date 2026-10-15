.PHONY: build-server configure-ssh

build-server: export VERSION := $(VERSION)
build-server: ## Build and package the Server release on the Action runner
	@set -Eeuo pipefail; \
	[[ "$${VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$$ ]]; \
	cd '$(PROJECT_ROOT)/..'; \
	rust_version=$$(sed -n 's/^channel = "\([0-9.]*\)"$$/\1/p' backend/rust-toolchain.toml); \
	[[ "$$rust_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]]; \
	mkdir -p .cache/cargo/registry .cache/cargo/git .cache/target .cache/fonts dist/image/fonts; \
	docker run --rm --platform linux/amd64 \
	  -v "$$PWD/backend:/src" -w /src \
	  -v "$$PWD/.cache/cargo/registry:/usr/local/cargo/registry" \
	  -v "$$PWD/.cache/cargo/git:/usr/local/cargo/git" \
	  -v "$$PWD/.cache/target:/src/target" \
	  "rust:$$rust_version-slim-bookworm" cargo build --release --locked --bin one-ip-backend; \
	cp .cache/target/release/one-ip-backend dist/image/; \
	for spec in 'Regular:faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9' 'Bold:c6cb5a93abaa9edc8ee7463b7ebb7f42d618d40e6ed2f7a5371c97b0b64767c0'; do \
	  font="NotoSansSC-$${spec%%:*}.otf"; digest="$${spec#*:}"; cached=".cache/fonts/$$font"; \
	  if [ ! -f "$$cached" ] || [ "$$(sha256sum "$$cached" | cut -d ' ' -f 1)" != "$$digest" ]; then \
	    curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
	      --output "$$cached.part" "https://github.com/notofonts/noto-cjk/raw/Sans2.004/Sans/SubsetOTF/SC/$$font"; \
	    printf '%s  %s\n' "$$digest" "$$cached.part" | sha256sum --check --strict; \
	    mv "$$cached.part" "$$cached"; \
	  fi; \
	  cp "$$cached" dist/image/fonts/; \
	done; \
	docker build --platform linux/amd64 --pull --file '$(PROJECT_ROOT)/deploy/Dockerfile' \
	  --tag "one-ip:$$VERSION" dist/image; \
	docker save "one-ip:$$VERSION" | gzip -1 > dist/server-image.tar.gz; \
	cp backend/deploy/docker/docker-compose.yml dist/docker-compose.yml

configure-ssh: export DEPLOY_PORT := $(if $(filter file undefined,$(origin DEPLOY_PORT)),22,$(DEPLOY_PORT))
configure-ssh: ## Configure the Action runner's deployment SSH identity
	@set -Eeuo pipefail; \
	umask 077; \
	: "$${DEPLOY_HOST:?}" "$${DEPLOY_USER:?}" "$${DEPLOY_SSH_KEY:?}" "$${DEPLOY_KNOWN_HOSTS:?}"; \
	[[ "$$DEPLOY_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$$ ]]; \
	[[ "$$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]*$$ ]]; \
	[[ "$${DEPLOY_PORT:-22}" =~ ^[0-9]{1,5}$$ ]]; \
	install -d -m 700 ~/.ssh; \
	printf '%s\n' "$$DEPLOY_SSH_KEY" > ~/.ssh/ipbot_deploy; \
	printf '%s\n' "$$DEPLOY_KNOWN_HOSTS" > ~/.ssh/known_hosts; \
	printf 'Host ipbot\n  HostName %s\n  Port %s\n  User %s\n  IdentityFile ~/.ssh/ipbot_deploy\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n' \
	  "$$DEPLOY_HOST" "$${DEPLOY_PORT:-22}" "$$DEPLOY_USER" > ~/.ssh/config
