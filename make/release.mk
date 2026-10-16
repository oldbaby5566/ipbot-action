.PHONY: deploy deploy-server deploy-web
deploy: ## Check, bump and push Server and Web together; the workflow deploys both concurrently
	@$(call ip_release,all)
deploy-server: ## Check, bump and push the Server release tag
	@$(call ip_release,server)
deploy-web: ## Check, bump and push the Web release tag for Cloudflare Pages
	@$(call ip_release,web)

define ip_release
set -Eeuo pipefail; \
unset GH_TOKEN GITHUB_TOKEN; \
target='$(1)'; version='$(VERSION)'; \
action_dir='$(abspath $(ACTION_DIR))'; backend_dir='$(abspath $(BACKEND_DIR))'; web_dir='$(abspath $(WEB_DIR))'; \
action_repository=oldbaby5566/ipbot-action; pnpm='$(PNPM)'; dry_run='$(DRY_RUN)'; \
die() { printf '%s\n' "$$*" >&2; exit 1; }; \
[[ "$$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$$ ]] || \
    die "VERSION must be three numeric components without leading zeroes, got: $${version:-<empty>}"; \
case "$$dry_run" in true|false) ;; *) die 'DRY_RUN must be true or false' ;; esac; \
deploy_tag="deploy-$$target-$$version"; \
use_backend=false; use_web=false; \
case "$$target" in server) use_backend=true ;; web) use_web=true ;; all) use_backend=true; use_web=true ;; esac; \
backend_tag="deploy-server-$$version"; web_tag="v$$version"; \
if [[ "$$use_backend" == true ]]; then backend_dir=$$(cd -- "$$backend_dir" && pwd); fi; \
if [[ "$$use_web" == true ]]; then web_dir=$$(cd -- "$$web_dir" && pwd); fi; \
repository_state() { \
    local label=$$1 directory=$$2 branch status; \
    [[ -d "$$directory/.git" ]] || die "$$label is not a git repository: $$directory"; \
    branch=$$(git -C "$$directory" symbolic-ref --quiet --short HEAD) || die "$$label must be on a branch"; \
    status=$$(git -C "$$directory" status --porcelain --untracked-files=all); \
    [[ -z "$$status" ]] || die "$$label has uncommitted changes; commit or stash them first:"$$'\n'"$$status"; \
    git -C "$$directory" fetch --quiet --no-tags origin "+refs/heads/$$branch:refs/remotes/origin/$$branch" || \
        die "$$label: could not fetch origin/$$branch"; \
    git -C "$$directory" merge-base --is-ancestor "origin/$$branch" HEAD || \
        die "$$label is behind or diverged from origin/$$branch; pull first"; \
    printf '%s %s\n' "$$branch" "$$(git -C "$$directory" rev-parse HEAD)"; \
}; \
require_new_tag() { \
    local label=$$1 directory=$$2 tag=$$3; \
    if git -C "$$directory" ls-remote --exit-code --tags origin "refs/tags/$$tag" >/dev/null 2>&1 \
        || git -C "$$directory" rev-parse --quiet --verify "refs/tags/$$tag" >/dev/null; then \
        die "$$label tag $$tag already exists; wait a minute or set VERSION=…"; \
    fi; \
}; \
backend_branch=; backend_head=; web_branch=; web_head=; \
if [[ "$$use_backend" == true ]]; then \
    read -r backend_branch backend_head < <(repository_state Backend "$$backend_dir"); \
    [[ -n "$$backend_head" ]] || exit 1; \
fi; \
if [[ "$$use_web" == true ]]; then \
    read -r web_branch web_head < <(repository_state Web "$$web_dir"); \
    [[ -n "$$web_head" ]] || exit 1; \
fi; \
read -r action_branch action_head < <(repository_state Action "$$action_dir"); \
[[ "$$action_branch" == main && "$$action_head" == "$$(git -C "$$action_dir" rev-parse origin/main)" ]] || \
    die 'Action must exactly match published origin/main; commit and push ../action first'; \
if [[ "$$use_backend" == true ]]; then require_new_tag Backend "$$backend_dir" "$$backend_tag"; fi; \
if [[ "$$use_web" == true ]]; then require_new_tag Web "$$web_dir" "$$web_tag"; fi; \
require_new_tag Action "$$action_dir" "$$deploy_tag"; \
printf '%s\n' 'IPBot release plan:' "  target:   $$target" "  version:  $$version"; \
if [[ "$$use_backend" == true ]]; then printf '  backend:  %s@%s (tag %s)\n' "$$backend_branch" "$$backend_head" "$$backend_tag"; fi; \
if [[ "$$use_web" == true ]]; then printf '  web:      %s@%s (tag %s)\n' "$$web_branch" "$$web_head" "$$web_tag"; fi; \
printf '%s\n' "  action:   $$action_repository@$$action_head" "  trigger:  Action tag $$deploy_tag"; \
if [[ "$$dry_run" == true ]]; then \
    echo 'DRY_RUN=true: no checks, version commits, pushes or tags.'; exit 0; \
fi; \
if [[ "$$use_backend" == true ]]; then \
    echo '==> Checking Backend'; \
    (cd -- "$$backend_dir" \
        && cargo fmt --all --check \
        && cargo clippy --all-targets --locked -- -D warnings \
        && cargo test --locked); \
fi; \
if [[ "$$use_web" == true ]]; then \
    echo '==> Checking Web'; \
    "$$pnpm" --dir "$$web_dir" install --frozen-lockfile; \
    "$$pnpm" --dir "$$web_dir" typecheck; \
    "$$pnpm" --dir "$$web_dir" lint; \
    "$$pnpm" --dir "$$web_dir" test; \
    "$$pnpm" --dir "$$web_dir" build; \
fi; \
unchanged() { \
    [[ "$$(git -C "$$2" rev-parse HEAD)" == "$$3" && -z "$$(git -C "$$2" status --porcelain --untracked-files=all)" ]] || \
        die "$$1 changed during checks; nothing was committed"; \
}; \
if [[ "$$use_backend" == true ]]; then unchanged Backend "$$backend_dir" "$$backend_head"; fi; \
if [[ "$$use_web" == true ]]; then unchanged Web "$$web_dir" "$$web_head"; fi; \
[[ "$$(git -C "$$action_dir" rev-parse HEAD)" == "$$action_head" \
    && -z "$$(git -C "$$action_dir" status --porcelain --untracked-files=all)" ]] || \
    die 'Action changed during checks; nothing was committed'; \
echo "==> Bumping version to $$version"; \
if [[ "$$use_backend" == true ]]; then \
    cd -- "$$backend_dir"; \
    for file in Cargo.toml Cargo.lock; do \
        awk -v version="$$version" -v lock="$$([[ $$file == Cargo.lock ]] && echo 1 || echo 0)" \
            'lock == 0 && /^\[package\]$$/ { target=1; print; next } lock == 1 && /^\[\[package\]\]$$/ { target=0; print; next } lock == 1 && $$0 == "name = \"one-ip-backend\"" { target=1; print; next } /^\[/ { target=0 } target && /^version = / && !done { print "version = \"" version "\""; done=1; next } { print } END { if (!done) exit 42 }' \
            "$$file" >"$$file.tmp" || { rm -f "$$file.tmp"; die "Could not update version in $$file"; }; \
        mv "$$file.tmp" "$$file"; \
    done; \
fi; \
if [[ "$$use_web" == true ]]; then \
    VERSION="$$version" node -e 'const fs = require("node:fs"); const file = process.argv[1]; const pkg = JSON.parse(fs.readFileSync(file, "utf8")); pkg.version = process.env.VERSION; fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");' "$$web_dir/package.json"; \
fi; \
commit_release() { \
    local directory=$$1; shift; \
    git -C "$$directory" add -- "$$@"; \
    git -C "$$directory" diff --cached --quiet || git -C "$$directory" commit --quiet -m "chore(release): $$version"; \
}; \
backend_ref=; web_ref=; \
if [[ "$$use_backend" == true ]]; then commit_release "$$backend_dir" Cargo.toml Cargo.lock; backend_ref=$$(git -C "$$backend_dir" rev-parse HEAD); fi; \
if [[ "$$use_web" == true ]]; then commit_release "$$web_dir" package.json; web_ref=$$(git -C "$$web_dir" rev-parse HEAD); fi; \
echo '==> Publishing'; \
if [[ "$$use_backend" == true ]]; then \
    git -C "$$backend_dir" tag "$$backend_tag"; \
    git -C "$$backend_dir" push origin "HEAD:refs/heads/$$backend_branch" "refs/tags/$$backend_tag"; \
fi; \
if [[ "$$use_web" == true ]]; then \
    git -C "$$web_dir" tag "$$web_tag"; \
    git -C "$$web_dir" push origin "HEAD:refs/heads/$$web_branch" "refs/tags/$$web_tag"; \
fi; \
metadata=$$(printf '{"target":"%s","version":"%s","backend_ref":"%s","web_ref":"%s","expected_action_sha":"%s"}' \
    "$$target" "$$version" "$$backend_ref" "$$web_ref" "$$action_head"); \
git -C "$$action_dir" tag --annotate "$$deploy_tag" "$$action_head" --message "$$metadata"; \
if ! git -C "$$action_dir" push origin "refs/tags/$$deploy_tag"; then \
    die "Sources published, but Action release tag push failed; retry: git -C '$$action_dir' push origin refs/tags/$$deploy_tag"; \
fi; \
printf 'Triggered IPBot %s deployment %s → https://github.com/oldbaby5566/ipbot-action/actions\n' "$$target" "$$version"
endef
