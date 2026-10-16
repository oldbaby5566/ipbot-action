.PHONY: deploy deploy-server deploy-web
deploy: deploy-server ## Release only Server through ipbot-action
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
if [[ "$$target" == server ]]; then \
    cd -- "$$backend_dir"; backend_dir=$$(pwd); \
    source_dir=$$backend_dir; source_label=Backend; source_tag=$$deploy_tag; \
else \
    cd -- "$$web_dir"; web_dir=$$(pwd); \
    source_dir=$$web_dir; source_label=Web; source_tag="v$$version"; \
fi; \
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
read -r source_branch source_head < <(repository_state "$$source_label" "$$source_dir"); \
read -r action_branch action_head < <(repository_state Action "$$action_dir"); \
[[ "$$action_branch" == main && "$$action_head" == "$$(git -C "$$action_dir" rev-parse origin/main)" ]] || \
    die 'Action must exactly match published origin/main; commit and push ../action first'; \
require_new_tag "$$source_label" "$$source_dir" "$$source_tag"; \
require_new_tag Action "$$action_dir" "$$deploy_tag"; \
printf '%s\n' 'IPBot release plan:' \
    "  target:   $$target" "  version:  $$version" "  source:   $$source_label $$source_branch@$$source_head" \
    "  action:   $$action_repository@$$action_head" "  trigger:  Action tag $$deploy_tag (source tag $$source_tag)"; \
if [[ "$$dry_run" == true ]]; then \
    echo 'DRY_RUN=true: no checks, version commits, pushes or tags.'; exit 0; \
fi; \
echo "==> Checking $$source_label"; \
if [[ "$$target" == server ]]; then \
    cargo fmt --all --check; \
    cargo clippy --all-targets --locked -- -D warnings; \
    cargo test --locked; \
else \
    "$$pnpm" --dir "$$web_dir" install --frozen-lockfile; \
    "$$pnpm" --dir "$$web_dir" typecheck; \
    "$$pnpm" --dir "$$web_dir" lint; \
    "$$pnpm" --dir "$$web_dir" test; \
    "$$pnpm" --dir "$$web_dir" build; \
fi; \
[[ "$$(git -C "$$source_dir" rev-parse HEAD)" == "$$source_head" \
    && -z "$$(git -C "$$source_dir" status --porcelain --untracked-files=all)" ]] || \
    die "$$source_label changed during checks; nothing was committed"; \
[[ "$$(git -C "$$action_dir" rev-parse HEAD)" == "$$action_head" \
    && -z "$$(git -C "$$action_dir" status --porcelain --untracked-files=all)" ]] || \
    die 'Action changed during checks; nothing was committed'; \
echo "==> Bumping $$source_label version to $$version"; \
if [[ "$$target" == server ]]; then \
    for file in Cargo.toml Cargo.lock; do \
        awk -v version="$$version" -v lock="$$([[ $$file == Cargo.lock ]] && echo 1 || echo 0)" \
            'lock == 0 && /^\[package\]$$/ { target=1; print; next } lock == 1 && /^\[\[package\]\]$$/ { target=0; print; next } lock == 1 && $$0 == "name = \"one-ip-backend\"" { target=1; print; next } /^\[/ { target=0 } target && /^version = / && !done { print "version = \"" version "\""; done=1; next } { print } END { if (!done) exit 42 }' \
            "$$file" >"$$file.tmp" || { rm -f "$$file.tmp"; die "Could not update version in $$file"; }; \
        mv "$$file.tmp" "$$file"; \
    done; \
else \
    VERSION="$$version" node -e 'const fs = require("node:fs"); const file = process.argv[1]; const pkg = JSON.parse(fs.readFileSync(file, "utf8")); pkg.version = process.env.VERSION; fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");' "$$web_dir/package.json"; \
fi; \
commit_release() { \
    local directory=$$1; shift; \
    git -C "$$directory" add -- "$$@"; \
    git -C "$$directory" diff --cached --quiet || git -C "$$directory" commit --quiet -m "chore(release): $$version"; \
}; \
if [[ "$$target" == server ]]; then commit_release "$$backend_dir" Cargo.toml Cargo.lock; \
else commit_release "$$web_dir" package.json; fi; \
echo '==> Publishing'; \
git -C "$$source_dir" tag "$$source_tag"; \
git -C "$$source_dir" push origin "HEAD:refs/heads/$$source_branch" "refs/tags/$$source_tag"; \
backend_ref=; web_ref=; \
if [[ "$$target" == server ]]; then backend_ref=$$(git -C "$$backend_dir" rev-parse HEAD); \
else web_ref=$$(git -C "$$web_dir" rev-parse HEAD); fi; \
metadata=$$(printf '{"target":"%s","version":"%s","backend_ref":"%s","web_ref":"%s","expected_action_sha":"%s"}' \
    "$$target" "$$version" "$$backend_ref" "$$web_ref" "$$action_head"); \
git -C "$$action_dir" tag --annotate "$$deploy_tag" "$$action_head" --message "$$metadata"; \
if ! git -C "$$action_dir" push origin "refs/tags/$$deploy_tag"; then \
    die "Sources published, but Action release tag push failed; retry: git -C '$$action_dir' push origin refs/tags/$$deploy_tag"; \
fi; \
printf 'Triggered IPBot %s deployment %s → https://github.com/oldbaby5566/ipbot-action/actions\n' "$$target" "$$version"
endef
