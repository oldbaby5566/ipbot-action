#!/usr/bin/env bash
# Release one component: checks → its version commit/tag → dispatch ipbot-action.
set -Eeuo pipefail

target=${TARGET:-server}
version=${RELEASE_VERSION:-}
action_dir=${ACTION_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
backend_dir=${BACKEND_DIR:-$action_dir/../backend}
web_dir=${WEB_DIR:-$action_dir/../web}
action_repository=oldbaby5566/ipbot-action
pnpm=${PNPM:-pnpm}

die() { printf '%s\n' "$*" >&2; exit 1; }

case "$target" in server|web) ;; *) die 'TARGET must be server or web' ;; esac
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  die "RELEASE_VERSION must be three numeric components without leading zeroes, got: ${version:-<empty>}"
case "${DRY_RUN:-false}" in
  true) dry_run=true ;; false) dry_run=false ;; *) die 'DRY_RUN must be true or false' ;;
esac
deploy_tag="deploy-$target-$version"
if [[ "$target" == server ]]; then
  cd -- "$backend_dir"
  backend_dir=$(pwd)
  source_dir=$backend_dir; source_label=Backend; source_tag=$deploy_tag
else
  cd -- "$web_dir"
  web_dir=$(pwd)
  source_dir=$web_dir; source_label=Web; source_tag="v$version"
fi

# Prints "<branch> <head>" for a clean repository that is not behind its origin branch.
repository_state() {
  local label=$1 directory=$2 branch status
  [[ -d "$directory/.git" ]] || die "$label is not a git repository: $directory"
  branch=$(git -C "$directory" symbolic-ref --quiet --short HEAD) || die "$label must be on a branch"
  status=$(git -C "$directory" status --porcelain --untracked-files=all)
  [[ -z "$status" ]] || die "$label has uncommitted changes; commit or stash them first:"$'\n'"$status"
  git -C "$directory" fetch --quiet --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch" ||
    die "$label: could not fetch origin/$branch"
  git -C "$directory" merge-base --is-ancestor "origin/$branch" HEAD ||
    die "$label is behind or diverged from origin/$branch; pull first"
  printf '%s %s\n' "$branch" "$(git -C "$directory" rev-parse HEAD)"
}

require_new_tag() {
  local label=$1 directory=$2 tag=$3
  if git -C "$directory" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 \
    || git -C "$directory" rev-parse --quiet --verify "refs/tags/$tag" >/dev/null; then
    die "$label tag $tag already exists; wait a minute or set VERSION=…"
  fi
}

read -r source_branch source_head < <(repository_state "$source_label" "$source_dir")
read -r action_branch action_head < <(repository_state Action "$action_dir")
[[ "$action_branch" == main && "$action_head" == "$(git -C "$action_dir" rev-parse origin/main)" ]] ||
  die 'Action must exactly match published origin/main; commit and push ../action first'
require_new_tag "$source_label" "$source_dir" "$source_tag"

printf '%s\n' \
  "One IP release plan:" \
  "  target:   $target" \
  "  version:  $version" \
  "  source:   $source_label $source_branch@$source_head" \
  "  action:   $action_repository@$action_head" \
  "  trigger:  workflow_dispatch deploy.yml (source tag $source_tag)"
if [[ "$dry_run" == true ]]; then
  echo 'DRY_RUN=true: no checks, version commits, pushes or tags.'
  exit 0
fi

# Resolve dispatch credentials before any release commits are made.
token=${GH_TOKEN:-}
if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
  token=$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token 2>/dev/null || true)
fi
if [[ -z "$token" ]]; then
  token=$(printf 'protocol=https\nhost=github.com\n\n' |
    GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p') || true
fi
[[ "$token" =~ ^[A-Za-z0-9_]{20,255}$ ]] || die 'Set GH_TOKEN with Actions write access to ipbot-action'

echo "==> Checking $source_label"
if [[ "$target" == server ]]; then
  cargo fmt --all --check
  cargo clippy --all-targets --locked -- -D warnings
  cargo test --locked
else
  "$pnpm" --dir "$web_dir" install --frozen-lockfile
  "$pnpm" --dir "$web_dir" typecheck
  "$pnpm" --dir "$web_dir" lint
  "$pnpm" --dir "$web_dir" test
  "$pnpm" --dir "$web_dir" build
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$source_head" \
  && -z "$(git -C "$source_dir" status --porcelain --untracked-files=all)" ]] ||
  die "$source_label changed during checks; nothing was committed"
[[ "$(git -C "$action_dir" rev-parse HEAD)" == "$action_head" \
  && -z "$(git -C "$action_dir" status --porcelain --untracked-files=all)" ]] ||
  die 'Action changed during checks; nothing was committed'

echo "==> Bumping $source_label version to $version"
if [[ "$target" == server ]]; then
  for file in Cargo.toml Cargo.lock; do
    awk -v version="$version" -v lock="$([[ $file == Cargo.lock ]] && echo 1 || echo 0)" '
      lock == 0 && /^\[package\]$/ { target=1; print; next }
      lock == 1 && /^\[\[package\]\]$/ { target=0; print; next }
      lock == 1 && $0 == "name = \"one-ip-backend\"" { target=1; print; next }
      /^\[/ { target=0 }
      target && /^version = / && !done { print "version = \"" version "\""; done=1; next }
      { print }
      END { if (!done) exit 42 }
    ' "$file" >"$file.tmp" || { rm -f "$file.tmp"; die "Could not update version in $file"; }
    mv "$file.tmp" "$file"
  done
else
  VERSION="$version" node - "$web_dir/package.json" <<'NODE'
const fs = require('node:fs');
const file = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(file, 'utf8'));
pkg.version = process.env.VERSION;
fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
NODE
fi

commit_release() {
  local directory=$1; shift
  git -C "$directory" add -- "$@"
  git -C "$directory" diff --cached --quiet ||
    git -C "$directory" commit --quiet -m "chore(release): $version"
}
if [[ "$target" == server ]]; then
  commit_release "$backend_dir" Cargo.toml Cargo.lock
else
  commit_release "$web_dir" package.json
fi

echo '==> Publishing'
git -C "$source_dir" tag "$source_tag"
git -C "$source_dir" push origin "HEAD:refs/heads/$source_branch" "refs/tags/$source_tag"
backend_ref=; web_ref=
if [[ "$target" == server ]]; then backend_ref=$(git -C "$backend_dir" rev-parse HEAD)
else web_ref=$(git -C "$web_dir" rev-parse HEAD); fi

payload_file=$(mktemp)
response_file=$(mktemp)
trap 'rm -f "$payload_file" "$response_file"' EXIT
node - "$payload_file" "$target" "$version" "$backend_ref" "$web_ref" "$action_head" <<'NODE'
const fs = require('node:fs');
const [file, target, version, backend_ref, web_ref, expected_action_sha] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({ref: 'main', inputs: {target, version, backend_ref, web_ref, expected_action_sha}}));
NODE
status=$(curl --disable --config - --silent --show-error --connect-timeout 15 --max-time 60 \
  --output "$response_file" --write-out '%{http_code}' \
  --header 'Accept: application/vnd.github+json' --header 'X-GitHub-Api-Version: 2026-03-10' \
  --data-binary "@$payload_file" \
  "https://api.github.com/repos/$action_repository/actions/workflows/deploy.yml/dispatches" \
  <<<"header = \"Authorization: Bearer $token\"") || {
    unset token
    die 'Sources published, but Action dispatch request failed; retry dispatch with the published source SHAs'
  }
unset token
if [[ "$status" != 200 && "$status" != 204 ]]; then
  cat "$response_file" >&2
  die "Sources published, but Action dispatch failed (HTTP $status); retry dispatch with the published source SHAs"
fi
printf 'Triggered One IP %s deployment %s → https://github.com/oldbaby5566/ipbot-action/actions\n' \
  "$target" "$version"
