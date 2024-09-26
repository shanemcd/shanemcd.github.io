SHELL = /bin/bash


# Set CONTAINER_RUNTIME to podman if available, otherwise try docker
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null)
CONTAINER_RUNTIME := $(if $(CONTAINER_RUNTIME),$(CONTAINER_RUNTIME),$(shell command -v docker 2>/dev/null))

ifeq (,$(CONTAINER_RUNTIME))
ifndef SUPPRESS_WARNING
$(warning Neither podman nor docker found in PATH. Some targets may not work properly. Set SUPPRESS_WARNING to hide this warning.)
endif
endif

SCRATCHPAD_IMAGE_NAME ?= scratchpad
IMAGE_TAG ?= latest
QUARTZ_SERVER_PORT ?= 6006
QUARTZ_WEBSOCKET_PORT ?= 3001

MAKEFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))
MAKEFILE_DIR := $(dir $(MAKEFILE_PATH))
PWD := $(shell pwd)

IMAGE_ID_FILE := .generated/.image-id

define COMMON_MOUNTS
-v $(MAKEFILE_DIR):/repo:Z -v "$(MAKEFILE_DIR)/content:/opt/quartz/content:Z"
endef

.DEFAULT_GOAL := scratchpad

.PHONY: scratchpad
scratchpad: check_image_uptodate
	@$(CONTAINER_RUNTIME) run --rm -ti \
		-p $(QUARTZ_SERVER_PORT):$(QUARTZ_SERVER_PORT) \
		-p $(QUARTZ_WEBSOCKET_PORT):$(QUARTZ_WEBSOCKET_PORT) \
		$(COMMON_MOUNTS) \
		$(SCRATCHPAD_IMAGE_NAME) \
		bash -c 'SUPPRESS_WARNING=yes QUARTZ_BUILD_OPTS="--serve --port=$(QUARTZ_SERVER_PORT)" make -f /repo/Makefile public'

.PHONY: debug
debug: check_image_uptodate
	$(CONTAINER_RUNTIME) run --rm -ti $(COMMON_MOUNTS) $(SCRATCHPAD_IMAGE_NAME) bash

RUN_ARGS ?= --rm -ti
RUN_CMD ?= "echo set RUN_CMD to specify another command."
.PHONY: run
run: check_image_uptodate
	$(CONTAINER_RUNTIME) run $(COMMON_MOUNTS) $(SCRATCHPAD_IMAGE_NAME) bash -c "$(RUN_CMD)"

.PHONY: image
image: $(IMAGE_ID_FILE)

$(IMAGE_ID_FILE): .generated Containerfile quartz.config.ts quartz.layout.ts
	$(CONTAINER_RUNTIME) build -t $(SCRATCHPAD_IMAGE_NAME):$(IMAGE_TAG) .
	$(CONTAINER_RUNTIME) inspect --format='{{.Id}}' $(SCRATCHPAD_IMAGE_NAME):$(IMAGE_TAG) > $(IMAGE_ID_FILE)

public:
	npx quartz build $(QUARTZ_BUILD_OPTS)

.PHONY: clean
clean:
	git clean -fdx

.generated:
	@mkdir -p $@

.PHONY: check_image_uptodate
check_image_uptodate: image
	@echo "Checking current image SHA..."
	@current_sha=$$($(CONTAINER_RUNTIME) inspect --format='{{.Id}}' $(SCRATCHPAD_IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || echo "none"); \
	stored_sha=$$(cat $(IMAGE_ID_FILE) 2>/dev/null || echo "none"); \
	if [ "$$current_sha" != "$$stored_sha" ] || [ -z "$$current_sha" ]; then \
		echo "Building image... $$current_sha $$stored_sha"; \
		$(MAKE) -B -f $(MAKEFILE_PATH) image; \
	else \
		echo "Image is up to date."; \
	fi
