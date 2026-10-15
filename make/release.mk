.PHONY: deploy deploy-server deploy-web
deploy: deploy-server ## Release Server and Web through ipbot-action
deploy-server: ## Check, bump, push and dispatch the Server + Web workflow
	@$(call ip_release,server)
deploy-web: ## Check, bump, push and dispatch the Web-only workflow
	@$(call ip_release,web)

define ip_release
TARGET='$(1)' RELEASE_VERSION='$(VERSION)' BACKEND_DIR='$(abspath $(BACKEND_DIR))' WEB_DIR='$(abspath $(WEB_DIR))' ACTION_DIR='$(PROJECT_ROOT)' PNPM='$(PNPM)' DRY_RUN='$(DRY_RUN)' bash scripts/release.sh
endef
