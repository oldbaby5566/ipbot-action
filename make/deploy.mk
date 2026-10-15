DEPLOY_DIR ?= /opt/one-ip
DEPLOY_VERSION ?=
DEPLOY_PORT ?= 27528
DEPLOY_NAME ?= one-ip
DEPLOY_CHECKSUM ?=
DRY_RUN ?= false
export DEPLOY_HOST DEPLOY_DIR DEPLOY_VERSION DEPLOY_PORT DEPLOY_NAME DEPLOY_CHECKSUM DRY_RUN

.PHONY: publish-server deploy-test
publish-server: ## Deploy the published Server release with readiness checks and rollback
	@set -euo pipefail; \
	case "$$DRY_RUN" in true|false) ;; *) echo 'DRY_RUN must be true or false' >&2; exit 1 ;; esac; \
	[[ "$$DEPLOY_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$$ ]] || { echo 'Set DEPLOY_VERSION to the published release version' >&2; exit 1; }; \
	[[ "$$DEPLOY_CHECKSUM" =~ ^[a-f0-9]{64}$$ ]] || { echo 'DEPLOY_CHECKSUM must be the trusted SHA256 of checksums.txt' >&2; exit 1; }; \
	[[ "$$DEPLOY_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9@._-]*$$ ]] || { echo 'Set DEPLOY_HOST to an SSH host or alias' >&2; exit 1; }; \
	[[ "$$DEPLOY_DIR" = /* && ! "$$DEPLOY_DIR" =~ [[:cntrl:]] ]] || { echo 'DEPLOY_DIR must be an absolute non-root directory' >&2; exit 1; }; \
	IFS=/ read -r -a parts <<< "$$DEPLOY_DIR"; depth=0; \
	for part in "$${parts[@]}"; do case "$$part" in ..) echo 'DEPLOY_DIR must not contain ..' >&2; exit 1 ;; ''|.) ;; *) depth=$$((depth + 1)) ;; esac; done; \
	[ "$$depth" -gt 0 ] || { echo 'DEPLOY_DIR must be non-root' >&2; exit 1; }; \
	[[ "$$DEPLOY_PORT" =~ ^[0-9]{1,5}$$ ]] && [ "$$DEPLOY_PORT" -ge 1 ] && [ "$$DEPLOY_PORT" -le 65535 ] || { echo 'DEPLOY_PORT must be a valid port' >&2; exit 1; }; \
	[[ "$$DEPLOY_NAME" =~ ^[a-z0-9][a-z0-9_-]{0,63}$$ ]] || { echo 'DEPLOY_NAME must be a Compose project name' >&2; exit 1; }; \
	if [ "$$DRY_RUN" = true ]; then \
	    printf '[plan] server downloads and verifies GitHub Release deploy-server-%s; host=%s directory=%s port=%s\n[remote]\n%s\n' \
	        "$$DEPLOY_VERSION" "$$DEPLOY_HOST" "$$DEPLOY_DIR" "$$DEPLOY_PORT" "$$IP_REMOTE_SERVER"; \
	else \
	    printf '%s\n' "$$IP_REMOTE_SERVER" | ssh -o BatchMode=yes -o ConnectTimeout=15 \
	        -o ServerAliveInterval=15 -o ServerAliveCountMax=8 "$$DEPLOY_HOST" \
	        "bash -se -- $$(printf '%q' "$$DEPLOY_DIR") $$DEPLOY_VERSION $$DEPLOY_PORT $$DEPLOY_NAME $$DEPLOY_CHECKSUM"; \
	fi

deploy-test: ## Run local deployment contracts without network or Docker
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*deploy.py'

# The server downloads its release assets; SSH only carries this inline body.
define IP_REMOTE_SERVER
set -euo pipefail
root=$$1; version=$$2; port=$$3; name=$$4; checksum=$$5
release_tag="deploy-server-$$version"; image="one-ip:$$version"
incoming="$$root/.deploy-$$version-$$$$"
manifest="$$root/deployments/$$version/docker-compose.yml"
locked=0
old_image=
old_manifest=
old_deployment=
previous_deployment=
started=0
deployment_switched=0

release_lock() {
    if [ -f "$$root/.deployment-lock/owner" ] \
        && [ "$$(cat "$$root/.deployment-lock/owner")" = "$$incoming" ]; then
        rm -f -- "$$root/.deployment-lock/owner"
        rmdir "$$root/.deployment-lock" 2>/dev/null || true
    fi
}

compose() {
    docker compose --project-directory "$$root" --env-file "$$root/.env" \
        --env-file "$$root/deployments/$$version/release.env" -p "$$name" -f "$$manifest" "$$@"
}
old_compose() {
    docker compose --project-directory "$$root" --env-file "$$root/.env" \
        --env-file "$$old_deployment/release.env" -p "$$name" -f "$$old_manifest" "$$@"
}

cleanup() {
    code=$$?
    trap - EXIT
    [ "$$locked" -eq 1 ] || exit "$$code"
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
    rm -f -- "$$root/deployments/current.next"
    rm -rf -- "$$incoming"
    release_lock
    exit "$$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
test -f "$$root/.env"
test -d "$$root/data"
test ! -e "$$root/deployments/$$version"
test ! -L "$$root/deployments/$$version"
mkdir "$$root/.deployment-lock"
locked=1
printf '%s\n' "$$incoming" >"$$root/.deployment-lock/owner"
mkdir "$$incoming"

previous_deployment=$$(readlink "$$root/deployments/current" 2>/dev/null || true)
old_deployment=$$(readlink -f "$$root/deployments/current" 2>/dev/null || true)
if [ -e "$$root/deployments/current" ] || [ -L "$$root/deployments/current" ]; then
    test -f "$$old_deployment/docker-compose.yml"
    test -f "$$old_deployment/release.env"
    old_manifest="$$old_deployment/docker-compose.yml"
fi

base="https://github.com/oldbaby5566/ipbot-action/releases/download/$$release_tag"
curl --fail --silent --show-error --location --retry 5 --retry-all-errors --connect-timeout 15 --max-time 600 \
    "$$base/checksums.txt" -o "$$incoming/checksums.txt"
printf '%s  %s\n' "$$checksum" "$$incoming/checksums.txt" | sha256sum --check --strict
pids=
for asset in server-image.tar.gz docker-compose.yml; do
    curl --fail --silent --show-error --location --retry 5 --retry-all-errors --connect-timeout 15 --max-time 600 \
        "$$base/$$asset" -o "$$incoming/$$asset" &
    pids="$$pids $$!"
done
failed=0
for pid in $$pids; do wait "$$pid" || failed=1; done
[ "$$failed" -eq 0 ]
(cd "$$incoming" && sha256sum --check --strict checksums.txt)

docker load --input "$$incoming/server-image.tar.gz"
digest=$$(docker image inspect --format '{{.Id}}' "$$image")
test -n "$$digest"
mkdir -p "$$root/deployments"
mkdir "$$root/deployments/$$version"
cp "$$incoming/docker-compose.yml" "$$manifest"
printf 'DOCKER_IMAGE=%s\nCONTAINER_NAME=%s\nHOST_PORT=%s\nAPP_ENV=prod\n' \
    "$$digest" "$$name" "$$port" > "$$root/deployments/$$version/release.env"
old_container=$$(compose ps -q ip)
if [ -n "$$old_container" ]; then
    old_image=$$(docker inspect --format '{{.Image}}' "$$old_container")
fi

started=1
compose up -d --no-deps --pull never ip
ready=0
for attempt in $$(seq 1 12); do
    if curl -fsS --max-time 5 "http://127.0.0.1:$$port/readyz" >/dev/null; then
        ready=1
        break
    fi
    sleep 2
done
[ "$$ready" -eq 1 ] || { echo 'Server readiness check failed' >&2; exit 1; }

ln -s "$$version" "$$root/deployments/current.next"
mv -Tf "$$root/deployments/current.next" "$$root/deployments/current"
deployment_switched=1
echo 'Server deployment completed; readiness verified'
endef
export IP_REMOTE_SERVER
