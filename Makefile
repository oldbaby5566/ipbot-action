SHELL := /bin/bash
.DEFAULT_GOAL := help
PROJECT_ROOT := $(CURDIR)
BACKEND_DIR ?= ../backend
WEB_DIR ?= ../web
PNPM ?= pnpm
DEPLOY_HOST ?= ipbot
VERSION ?= $(shell TZ=Asia/Shanghai date +%y.%-m%d.%H%M | awk -F. '{printf "%d.%d.%d", $$1, $$2, $$3}')

include make/release.mk
include make/deploy.mk

.PHONY: help
help:
	@awk 'BEGIN {FS=":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
