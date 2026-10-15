#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_SSH_KEY:?}" "${DEPLOY_KNOWN_HOSTS:?}"
[[ "$DEPLOY_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]
[[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]
[[ "${DEPLOY_PORT:-22}" =~ ^[0-9]{1,5}$ ]]
command -v uuidgen >/dev/null || sudo apt-get install --yes uuid-runtime
install -d -m 700 ~/.ssh
printf '%s\n' "$DEPLOY_SSH_KEY" > ~/.ssh/ipbot_deploy
printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > ~/.ssh/known_hosts
cat > ~/.ssh/config <<EOF
Host ipbot
  HostName $DEPLOY_HOST
  Port ${DEPLOY_PORT:-22}
  User $DEPLOY_USER
  IdentityFile ~/.ssh/ipbot_deploy
  IdentitiesOnly yes
  StrictHostKeyChecking yes
EOF
