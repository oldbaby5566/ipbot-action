SHELL := /bin/bash
DEPLOY_DIR ?= /opt/one-ip
DEPLOY_IMAGE ?=
DEPLOY_VERSION ?=
DEPLOY_PORT ?= 27528
DEPLOY_NAME ?= one-ip
DEPLOY_PLATFORM ?= linux/amd64
DEPLOY_TRANSFER ?= ssh
DEPLOY_RELEASE ?=
DEPLOY_CHECKSUM ?=
DEPLOY_SUDO ?= false
DEPLOY_STAGE_HOST ?=
DEPLOY_STAGE_DIR ?=
DEPLOY_STAGE_IMAGE ?=
DEPLOY_STAGE_VERSION ?=
DEPLOY_STAGE_PORT ?=
DEPLOY_STAGE_NAME ?= one-ip-stage
DEPLOY_STAGE_PLATFORM ?=
DEPLOY_STAGE_TRANSFER ?= registry
DEPLOY_STAGE_SUDO ?= false
DRY_RUN ?= false
IP_DEPLOY_ENV := prod
export DEPLOY_HOST DEPLOY_DIR DEPLOY_IMAGE DEPLOY_VERSION DEPLOY_PORT DEPLOY_NAME DEPLOY_PLATFORM DEPLOY_TRANSFER DEPLOY_RELEASE DEPLOY_CHECKSUM DEPLOY_SUDO DRY_RUN IP_DEPLOY_ENV

.PHONY: image-build image-build-stage publish-server publish-web deploy-stage deploy-stage-web deploy-test
image-build: ## Build a local release image without pushing
	@set -eu; cd '$(BACKEND_DIR)'; $(call ip_settings,image); $(ip_image_build)

# Executors run on the Action runner (or by hand) against DEPLOY_HOST.
publish-server: ## Build or pull an image, deploy Server and Web with health checks and rollback
	@set -eu; if [ "$$DEPLOY_TRANSFER" != release ]; then cd '$(BACKEND_DIR)'; fi; $(call ip_settings,server); $(ip_publish)
publish-web: ## Atomically deploy Web with health checks and rollback
	@set -eu; if [ "$$DEPLOY_TRANSFER" != release ]; then cd '$(BACKEND_DIR)'; fi; $(call ip_settings,web); $(ip_publish)

image-build-stage deploy-stage deploy-stage-web: override DEPLOY_HOST = $(DEPLOY_STAGE_HOST)
image-build-stage deploy-stage deploy-stage-web: override DEPLOY_DIR = $(DEPLOY_STAGE_DIR)
image-build-stage deploy-stage deploy-stage-web: override DEPLOY_IMAGE = $(DEPLOY_STAGE_IMAGE)
image-build-stage deploy-stage deploy-stage-web: override DEPLOY_VERSION = $(DEPLOY_STAGE_VERSION)
image-build-stage deploy-stage deploy-stage-web: override DEPLOY_PORT = $(DEPLOY_STAGE_PORT)
image-build-stage deploy-stage deploy-stage-web: override DEPLOY_NAME = $(DEPLOY_STAGE_NAME)
image-build-stage deploy-stage deploy-stage-web: override DEPLOY_PLATFORM = $(DEPLOY_STAGE_PLATFORM)
image-build-stage deploy-stage deploy-stage-web: override DEPLOY_TRANSFER = $(DEPLOY_STAGE_TRANSFER)
image-build-stage deploy-stage deploy-stage-web: override DEPLOY_SUDO = $(DEPLOY_STAGE_SUDO)
image-build-stage deploy-stage deploy-stage-web: override IP_DEPLOY_ENV = stage
image-build-stage: image-build ## Build a stage image from explicit stage settings
deploy-stage: publish-server ## Deploy stage Server and Web from explicit stage settings
deploy-stage-web: publish-web ## Deploy only stage Web from explicit stage settings
deploy-test: ## Run local deployment contracts without network or Docker
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*deploy.py'

# Export the inline shell bodies as data; no generated or external shell script.
define IP_REMOTE_COMMON

set -eu
current="$$root/web/current"
release="$$root/web/releases/$$version"
previous=$$(readlink "$$current" 2>/dev/null || true)
switched=0
container=
old_image=
started=0
deployment_switched=0
switch_web() {
    ln -s "$$1" "$$current.next"
    mv -Tf "$$current.next" "$$current"
}
check_release() {
    for attempt in $$(seq 1 12); do
        if curl -fsS --max-time 5 "http://127.0.0.1:$$port/readyz" >/dev/null \
            && curl -fsS --max-time 5 "http://127.0.0.1:$$port/" >/dev/null \
            && [ "$$(curl -fsS --max-time 5 -H 'Cache-Control: no-cache' "http://127.0.0.1:$$port/one-web-revision.txt")" = "$$version" ]; then
            return 0
        fi
        sleep 2
    done
    echo 'Deployment health or Web revision check failed' >&2
    return 1
}

release_lock() {
    if [ -f "$$root/.deployment-lock/owner" ] \
        && [ "$$(cat "$$root/.deployment-lock/owner")" = "$$incoming" ]; then
        rm -f -- "$$root/.deployment-lock/owner"
        rmdir "$$root/.deployment-lock" 2>/dev/null || true
    fi
}

download_release() {
    base="https://github.com/oldbaby5566/ipbot-action/releases/download/$$release_tag"
    curl --fail --silent --show-error --location --retry 5 --retry-all-errors --connect-timeout 15 --max-time 600 \
        "$$base/checksums.txt" -o "$$incoming/checksums.txt"
    printf '%s  %s\n' "$$checksum" "$$incoming/checksums.txt" | sha256sum --check --strict
    pids=
    for asset in "$$@"; do
        curl --fail --silent --show-error --location --retry 5 --retry-all-errors --connect-timeout 15 --max-time 600 \
            "$$base/$$asset" -o "$$incoming/$$asset" &
        pids="$$pids $$!"
    done
    failed=0
    for pid in $$pids; do wait "$$pid" || failed=1; done
    [ "$$failed" -eq 0 ]
    (cd "$$incoming" && sha256sum --check --strict checksums.txt)
    mkdir "$$incoming/web"
    tar -xzf "$$incoming/web.tar.gz" -C "$$incoming/web" --no-same-owner
}
endef

define IP_REMOTE_SERVER
set -eu
root=$$1; version=$$2; port=$$3; name=$$4; environment=$$5; image=$$6; incoming=$$7; transfer=$$8
release_tag=$${9:-}; checksum=$${10:-}
$(IP_REMOTE_COMMON)

manifest="$$root/deployments/$$version/docker-compose.yml"
previous_deployment=$$(readlink "$$root/deployments/current" 2>/dev/null || true)
old_deployment=$$(readlink -f "$$root/deployments/current" 2>/dev/null || true)
old_manifest=
if [ -e "$$root/deployments/current" ] || [ -L "$$root/deployments/current" ]; then
    test -f "$$old_deployment/docker-compose.yml"
    test -f "$$old_deployment/release.env"
    old_manifest="$$old_deployment/docker-compose.yml"
fi
compose() {
    docker compose --project-directory "$$root" --env-file "$$root/.env" \
        --env-file "$$root/deployments/$$version/release.env" -p "$$name" -f "$$manifest" "$$@"
}
old_compose() {
    docker compose --project-directory "$$root" --env-file "$$root/.env" \
        --env-file "$$old_deployment/release.env" -p "$$name" -f "$$old_manifest" "$$@"
}

rollback() {
    code=$$?
    trap - EXIT
    if [ "$$code" -ne 0 ] && [ "$$switched" -eq 1 ]; then
        if [ -n "$$previous" ]; then
            switch_web "$$previous" || echo 'Web rollback failed; manual recovery required' >&2
        else
            rm -f -- "$$current"
        fi
        echo 'Restored previous Web link' >&2
    fi

    if [ "$$code" -ne 0 ] && [ "$$started" -eq 1 ]; then
        if [ -n "$$old_manifest" ]; then
            if [ -n "$$old_image" ]; then
                DOCKER_IMAGE="$$old_image" old_compose up -d --no-deps --pull never ip || echo 'Server rollback failed; manual recovery required' >&2
            else
                old_compose up -d --no-deps --pull never ip || echo 'Server rollback failed; manual recovery required' >&2
            fi
        elif [ -n "$$old_image" ]; then
            echo 'No previous managed manifest; restoring old image with current Compose settings' >&2
            DOCKER_IMAGE="$$old_image" compose up -d --no-deps --pull never ip || echo 'Server rollback failed; manual recovery required' >&2
        else
            compose rm --stop --force ip || echo 'Failed to remove initial deployment container' >&2
        fi
    fi
    if [ "$$code" -ne 0 ] && [ "$$deployment_switched" -eq 1 ]; then
        if [ -n "$$previous_deployment" ]; then
            ln -s "$$previous_deployment" "$$root/deployments/current.next"
            mv -Tf "$$root/deployments/current.next" "$$root/deployments/current"
        else
            rm -f -- "$$root/deployments/current"
        fi
    fi
    if [ -n "$$container" ]; then docker rm "$$container" >/dev/null || true; fi
    rm -f -- "$$root/deployments/current.next"

    rm -f -- "$$current.next"
    rm -rf -- "$$incoming"
    release_lock
    exit "$$code"
}
trap rollback EXIT
mkdir -p "$$root/web/releases"
test ! -e "$$release"
test ! -L "$$release"

test -f "$$root/.env"
test -d "$$root/data"
if [ "$$transfer" = release ]; then
    download_release web.tar.gz server-image.tar.gz docker-compose.yml
    docker load --input "$$incoming/server-image.tar.gz"
fi
if [ "$$transfer" = ssh ] || [ "$$transfer" = release ]; then
    digest=$$(docker image inspect --format '{{.Id}}' "$$image")
else
    docker pull "$$image"
    digest=$$(docker image inspect --format '{{index .RepoDigests 0}}' "$$image")
fi
test -n "$$digest"
if [ "$$transfer" != release ]; then
    mkdir "$$incoming/web"
    container=$$(docker create "$$digest")
    docker cp "$$container:/opt/one-ip/web-dist/." "$$incoming/web"
    docker rm "$$container" >/dev/null
    container=
fi
mkdir -p "$$root/deployments"
mkdir "$$root/deployments/$$version"
cp "$$incoming/docker-compose.yml" "$$manifest"
printf 'DOCKER_IMAGE=%s\nCONTAINER_NAME=%s\nHOST_PORT=%s\nAPP_ENV=%s\n' \
    "$$digest" "$$name" "$$port" "$$environment" > "$$root/deployments/$$version/release.env"
old_container=$$(compose ps -q ip)
if [ -n "$$old_container" ]; then
    old_image=$$(docker inspect --format '{{.Image}}' "$$old_container")
fi

test -f "$$incoming/web/index.html"
test -f "$$incoming/web/app-version.json"
test "$$(cat "$$incoming/web/one-web-revision.txt")" = "$$version"
chmod -R a+rX "$$incoming/web"
mv -T "$$incoming/web" "$$release"
switch_web "releases/$$version"
switched=1

started=1
compose up -d --no-deps --pull never ip

check_release

ln -s "$$version" "$$root/deployments/current.next"
mv -Tf "$$root/deployments/current.next" "$$root/deployments/current"
deployment_switched=1

echo 'Deployment completed; health and Web revision verified'
endef

define IP_REMOTE_WEB
set -eu
root=$$1; version=$$2; port=$$3; name=$$4; environment=$$5; image=$$6; incoming=$$7; transfer=$$8
release_tag=$${9:-}; checksum=$${10:-}
$(IP_REMOTE_COMMON)

rollback() {
    code=$$?
    trap - EXIT
    if [ "$$code" -ne 0 ] && [ "$$switched" -eq 1 ]; then
        if [ -n "$$previous" ]; then
            switch_web "$$previous" || echo 'Web rollback failed; manual recovery required' >&2
        else
            rm -f -- "$$current"
        fi
        echo 'Restored previous Web link' >&2
    fi

    rm -f -- "$$current.next"
    rm -rf -- "$$incoming"
    release_lock
    exit "$$code"
}
trap rollback EXIT
mkdir -p "$$root/web/releases"
test ! -e "$$release"
test ! -L "$$release"

test -L "$$current"
if [ "$$transfer" = release ]; then
    download_release web.tar.gz
else
    tar -xf "$$incoming/web.tar" -C "$$incoming"
fi

test -f "$$incoming/web/index.html"
test -f "$$incoming/web/app-version.json"
test "$$(cat "$$incoming/web/one-web-revision.txt")" = "$$version"
chmod -R a+rX "$$incoming/web"
mv -T "$$incoming/web" "$$release"
switch_web "releases/$$version"
switched=1

check_release

echo 'Deployment completed; health and Web revision verified'
endef

export IP_REMOTE_SERVER IP_REMOTE_WEB

define ip_settings
set -eu; mode='$(1)'; \
case "$$DRY_RUN" in true|false) ;; *) echo 'DRY_RUN must be true or false' >&2; exit 1 ;; esac; \
case "$$DEPLOY_TRANSFER" in registry|ssh|release) ;; *) echo 'DEPLOY_TRANSFER must be registry, ssh or release' >&2; exit 1 ;; esac; \
case "$$DEPLOY_SUDO" in true) elevate='sudo -n ' ;; false) elevate= ;; *) echo 'DEPLOY_SUDO must be true or false' >&2; exit 1 ;; esac; \
version="$$DEPLOY_VERSION"; image="$$DEPLOY_IMAGE"; \
if [ "$$mode" = server ] && [ "$$DEPLOY_TRANSFER" = ssh ]; then \
    version="$${version:-$$(date +%Y%m%d-%H%M%S)}"; image="$${image:-$$DEPLOY_NAME:$$version}"; \
fi; \
[[ "$$version" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$$ ]] || { echo 'Set DEPLOY_VERSION (DEPLOY_STAGE_VERSION for stage) to a unique release label' >&2; exit 1; }; \
if [ "$$DEPLOY_TRANSFER" = release ]; then \
    [ "$$DEPLOY_RELEASE" = "deploy-$$mode-$$version" ] || { echo 'DEPLOY_RELEASE must match deploy-<server|web>-<version>' >&2; exit 1; }; \
    [[ "$$DEPLOY_CHECKSUM" =~ ^[a-f0-9]{64}$$ ]] || { echo 'DEPLOY_CHECKSUM must be the trusted SHA256 of checksums.txt' >&2; exit 1; }; \
fi; \
if [ "$$mode" != web ]; then \
    [[ "$$image" =~ ^[a-z0-9][a-z0-9./:_-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]*|@sha256:[a-f0-9]{64})$$ ]] && [[ "$$image" != *:latest ]] || { echo 'DEPLOY_IMAGE requires a versioned tag or sha256 digest; latest is not accepted' >&2; exit 1; }; \
    if [ "$$mode" = image ] || [ "$$DEPLOY_TRANSFER" = ssh ]; then \
        [[ "$$image" != *@* ]] || { echo 'Local image builds require a tag' >&2; exit 1; }; \
        case "$$DEPLOY_PLATFORM" in linux/amd64|linux/arm64) ;; *) echo 'Set DEPLOY_PLATFORM (DEPLOY_STAGE_PLATFORM for stage) explicitly to linux/amd64 or linux/arm64' >&2; exit 1 ;; esac; \
    fi; \
fi; \
if [ "$$mode" != image ]; then \
    [[ "$$DEPLOY_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9@._-]*$$ ]] || { echo 'Set DEPLOY_HOST to an SSH host or alias' >&2; exit 1; }; \
    [[ "$$DEPLOY_DIR" = /* && ! "$$DEPLOY_DIR" =~ [[:cntrl:]] ]] || { echo 'DEPLOY_DIR must be an absolute non-root directory' >&2; exit 1; }; \
    IFS=/ read -r -a parts <<< "$$DEPLOY_DIR"; depth=0; \
    for part in "$${parts[@]}"; do case "$$part" in ..) echo 'DEPLOY_DIR must not contain ..' >&2; exit 1 ;; ''|.) ;; *) depth=$$((depth + 1)) ;; esac; done; \
    [ "$$depth" -gt 0 ] || { echo 'DEPLOY_DIR must be non-root' >&2; exit 1; }; \
    [[ "$$DEPLOY_PORT" =~ ^[0-9]{1,5}$$ ]] && [ "$$DEPLOY_PORT" -ge 1 ] && [ "$$DEPLOY_PORT" -le 65535 ] || { echo 'DEPLOY_PORT must be a valid port' >&2; exit 1; }; \
    [[ "$$DEPLOY_NAME" =~ ^[a-z0-9][a-z0-9_-]{0,63}$$ ]] || { echo 'DEPLOY_NAME must be a Compose project name' >&2; exit 1; }; \
fi; \
build_script=build; [ "$$IP_DEPLOY_ENV" != stage ] || build_script=build:stage
endef

# Only public source/build files enter the temporary image context.
define ip_image_build
if [ "$$DRY_RUN" = true ]; then \
    printf '[plan] pnpm --dir %s %s; stage Cargo/src/sql, stamped Web and verified fonts; docker build --platform %s --tag %s\n' '$(abspath $(WEB_DIR))' "$$build_script" "$$DEPLOY_PLATFORM" "$$image"; \
else \
    '$(PNPM)' --dir '$(abspath $(WEB_DIR))' "$$build_script"; \
    context="$$(mktemp -d)"; trap 'rm -rf "$$context"' EXIT; \
    cp Cargo.toml Cargo.lock rust-toolchain.toml "$$context/"; \
    cp -R src sql "$$context/"; cp deploy/docker/Dockerfile "$$context/Dockerfile"; \
    test -f '$(abspath $(WEB_DIR))/dist/index.html'; test -f '$(abspath $(WEB_DIR))/dist/app-version.json'; \
    test -z "$$(find '$(abspath $(WEB_DIR))/dist' -type l -print -quit)" || { echo 'Web build must not contain symlinks' >&2; exit 1; }; \
    cp -R '$(abspath $(WEB_DIR))/dist' "$$context/web-dist"; printf '%s\n' "$$version" >"$$context/web-dist/one-web-revision.txt"; \
    mkdir -p .cache/fonts "$$context/fonts"; \
    for spec in 'Regular:faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9' 'Bold:c6cb5a93abaa9edc8ee7463b7ebb7f42d618d40e6ed2f7a5371c97b0b64767c0'; do \
        font="NotoSansSC-$${spec%%:*}.otf"; digest="$${spec#*:}"; cached=".cache/fonts/$$font"; \
        if [ ! -f "$$cached" ] || [ "$$(shasum -a 256 "$$cached" | cut -d ' ' -f 1)" != "$$digest" ]; then \
            curl --fail --silent --show-error --location --retry 5 --retry-all-errors --output "$$cached.part" "https://github.com/notofonts/noto-cjk/raw/Sans2.004/Sans/SubsetOTF/SC/$$font"; \
            [ "$$(shasum -a 256 "$$cached.part" | cut -d ' ' -f 1)" = "$$digest" ] || { rm -f "$$cached.part"; echo "$$font checksum mismatch" >&2; exit 1; }; \
            mv "$$cached.part" "$$cached"; \
        fi; \
        cp "$$cached" "$$context/fonts/"; \
    done; \
    docker build --platform "$$DEPLOY_PLATFORM" --pull --file "$$context/Dockerfile" --tag "$$image" "$$context"; \
    rm -rf "$$context"; trap - EXIT; \
fi
endef

# Upload through one shared SSH connection; remote bodies preserve the release
# lock, atomic Web/manifest links, immutable images, health checks and rollback.
define ip_publish
remote_script="$$IP_REMOTE_WEB"; [ "$$mode" != server ] || remote_script="$$IP_REMOTE_SERVER"; \
if [ "$$DRY_RUN" = true ]; then \
    if [ "$$mode" = server ] && [ "$$DEPLOY_TRANSFER" = ssh ]; then \
        $(ip_image_build); \
        printf '[plan] docker save %s | gzip | ssh %s gunzip | %sdocker load\n' "$$image" "$$DEPLOY_HOST" "$$elevate"; \
    elif [ "$$DEPLOY_TRANSFER" = release ]; then printf '[plan] server downloads and verifies GitHub Release %s (no build or SSH artifact upload)\n' "$$DEPLOY_RELEASE"; \
    elif [ "$$mode" = web ]; then printf '[plan] pnpm --dir %s %s; upload stamped Web archive\n' '$(abspath $(WEB_DIR))' "$$build_script"; fi; \
    printf '[plan] %s environment=%s version=%s host=%s directory=%s; ssh %sbash -se\n[remote]\n%s\n' "$$mode" "$$IP_DEPLOY_ENV" "$$version" "$$DEPLOY_HOST" "$$DEPLOY_DIR" "$$elevate" "$$remote_script"; \
else \
    if [ "$$mode" = server ] && [ "$$DEPLOY_TRANSFER" = ssh ]; then $(ip_image_build); fi; \
    if [ "$$mode" = web ] && [ "$$DEPLOY_TRANSFER" != release ]; then '$(PNPM)' --dir '$(abspath $(WEB_DIR))' "$$build_script"; fi; \
    ssh_command=(ssh -o BatchMode=yes -o ControlMaster=auto -o ControlPath=/tmp/ipbot-ssh-%C -o ServerAliveInterval=15 -o ServerAliveCountMax=8); \
    incoming="$$DEPLOY_DIR/.deploy-$$(uuidgen | tr -d '-')"; remote_root="$$(printf '%q' "$$DEPLOY_DIR")"; remote_incoming="$$(printf '%q' "$$incoming")"; acquired=; archive_dir=; \
    cleanup() { \
        status=$$?; trap - EXIT; \
        if [ -n "$$acquired" ]; then \
            "$${ssh_command[@]}" "$$DEPLOY_HOST" "$${elevate}bash -se -- $$remote_root $$remote_incoming" <<< 'root=$$1; incoming=$$2; rm -rf -- "$$incoming"; if [ -f "$$root/.deployment-lock/owner" ] && [ "$$(cat "$$root/.deployment-lock/owner")" = "$$incoming" ]; then rm -f "$$root/.deployment-lock/owner"; rmdir "$$root/.deployment-lock"; fi' || true; \
        fi; \
        [ -z "$$archive_dir" ] || rm -rf "$$archive_dir"; \
        "$${ssh_command[@]}" -O exit "$$DEPLOY_HOST" >/dev/null 2>&1 || true; exit "$$status"; \
    }; \
    trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; \
    for attempt in 1 2 3 4 5; do \
        if "$${ssh_command[@]}" -o ControlMaster=yes -o ControlPersist=600 -o ConnectTimeout=15 -fN "$$DEPLOY_HOST"; then break; fi; \
        [ "$$attempt" -lt 5 ] || exit 1; sleep $$((3 * attempt)); \
    done; \
    if [ "$$mode" = server ] && [ "$$DEPLOY_TRANSFER" = ssh ]; then \
        set -o pipefail; docker save "$$image" | gzip -1 | "$${ssh_command[@]}" "$$DEPLOY_HOST" "gunzip | $${elevate}docker load"; \
    fi; \
    "$${ssh_command[@]}" "$$DEPLOY_HOST" "$${elevate}bash -se -- $$remote_root $$remote_incoming $$version" <<< 'root=$$1; incoming=$$2; version=$$3; test -d "$$root"; test ! -e "$$root/web/current" || test -L "$$root/web/current"; test ! -e "$$root/web/releases/$$version"; test ! -L "$$root/web/releases/$$version"; mkdir "$$root/.deployment-lock"; printf "%s\n" "$$incoming" >"$$root/.deployment-lock/owner"; trap '\''rm -f "$$root/.deployment-lock/owner"; rmdir "$$root/.deployment-lock"'\'' EXIT; mkdir "$$incoming"; trap - EXIT'; \
    acquired=1; \
    if [ "$$DEPLOY_TRANSFER" = release ]; then \
        :; \
    elif [ "$$mode" = web ]; then \
        test -f '$(abspath $(WEB_DIR))/dist/index.html'; test -f '$(abspath $(WEB_DIR))/dist/app-version.json'; \
        test -z "$$(find '$(abspath $(WEB_DIR))/dist' -type l -print -quit)" || { echo 'Web build must not contain symlinks' >&2; exit 1; }; \
        archive_dir="$$(mktemp -d)"; cp -R '$(abspath $(WEB_DIR))/dist' "$$archive_dir/web"; \
        printf '%s\n' "$$version" >"$$archive_dir/web/one-web-revision.txt"; \
        tar -cf "$$archive_dir/web.tar" -C "$$archive_dir" web; \
        "$${ssh_command[@]}" "$$DEPLOY_HOST" "$${elevate}tee $$remote_incoming/web.tar >/dev/null" <"$$archive_dir/web.tar"; \
    else \
        "$${ssh_command[@]}" "$$DEPLOY_HOST" "$${elevate}tee $$remote_incoming/docker-compose.yml >/dev/null" <deploy/docker/docker-compose.yml; \
    fi; \
    remote_release="$$(printf '%q' "$$DEPLOY_RELEASE")"; remote_checksum="$$(printf '%q' "$$DEPLOY_CHECKSUM")"; \
    printf '%s\n' "$$remote_script" | "$${ssh_command[@]}" "$$DEPLOY_HOST" "$${elevate}bash -se -- $$remote_root $$version $$DEPLOY_PORT $$DEPLOY_NAME $$IP_DEPLOY_ENV '$$image' $$remote_incoming $$DEPLOY_TRANSFER $$remote_release $$remote_checksum"; \
fi
endef
