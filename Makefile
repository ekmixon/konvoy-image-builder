SHELL:=/bin/bash
.DEFAULT_GOAL := help

OS := $(shell uname -s)

INTERACTIVE := $(shell [ -t 0 ] && echo 1)

root_mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
export REPO_ROOT_DIR := $(dir $(root_mkfile_path))
export REPO_REV := $(shell cd $(REPO_ROOT_DIR) && git describe --abbrev=12 --tags --match='v*' HEAD)

UID ?= $(shell id -u)
GID ?= $(shell id -g)
USER_NAME ?= $(shell id -u -n)
GROUP_NAME ?= $(shell id -g -n)

COVERAGE ?= $(REPO_ROOT_DIR)/coverage

VERBOSITY ?= 6

export DOCKER_REPOSITORY ?= mesosphere/konvoy-image-builder
export DOCKER_SOCKET ?= /var/run/docker.sock
ifeq ($(OS),Darwin)
export DOCKER_SOCKET_GID ?= $(shell /usr/bin/stat -f "%g" $(DOCKER_SOCKET))
else
export DOCKER_SOCKET_GID ?= $(shell stat -c %g $(DOCKER_SOCKET))
endif

export DOCKER_IMG ?= $(DOCKER_REPOSITORY):$(REPO_REV)
export DOCKER_PHONY_FILE ?= .docker-$(shell echo '$(DOCKER_IMG)' | tr '/:' '.')

export DOCKER_DEVKIT_IMG ?= $(DOCKER_REPOSITORY):latest-devkit
export DOCKER_DEVKIT_PHONY_FILE ?= .docker-$(shell echo '$(DOCKER_DEVKIT_IMG)' | tr '/:' '.')
export DOCKER_DEVKIT_GO_ENV_ARGS ?= \
	--env GOCACHE=/kib/.cache/go-build \
	--env GOMODCACHE=/kib/.cache/go-mod \
	--env GOLANGCI_LINT_CACHE=/kib/.cache/golangci-lint

export DOCKER_DEVKIT_ENV_ARGS ?= \
	--env CI \
	--env GITHUB_TOKEN \
	$(DOCKER_DEVKIT_GO_ENV_ARGS)

export DOCKER_DEVKIT_AWS_ARGS ?= \
	--env AWS_PROFILE \
	--env AWS_SECRET_ACCESS_KEY \
	--env AWS_SESSION_TOKEN \
	--env AWS_DEFAULT_REGION \
	--volume "$(HOME)/.aws":"/home/$(USER_NAME)/.aws"

ifneq ($(wildcard $(DOCKER_SOCKET)),)
	export DOCKER_SOCKET_ARGS ?= \
		--volume "$(DOCKER_SOCKET)":/var/run/docker.sock
endif

export DOCKER_DEVKIT_PUSH_ARGS ?= \
	--volume "$(HOME)/.docker":"/home/$(USER_NAME)/.docker" \
	--env DOCKER_PASS \
	--env DOCKER_CLI_EXPERIMENTAL

# ulimit arg is a workaround for golang's "suboptimal" bug workaround that
# manifests itself in alpine images, resulting in packer plugins sipmly dying.
#
# On LTS distros like Ubuntu, kernel bugs are backported, so the kernel version
# may seem old even though it is not vulnerable. Golang ignores it and just
# looks at the distro+kernel combination to determine if it should panic or
# not. This results in packer silently failing when running in devkit
# container, as it is using Alpine linux. See the issue below for more details:
# https://github.com/docker-library/golang/issues/320
export DOCKER_ULIMIT_ARGS ?= \
	--ulimit memlock=67108864:67108864

export DOCKER_DEVKIT_USER_ARGS ?= \
	--user $(UID):$(GID) \
	--group-add $(DOCKER_SOCKET_GID)

export DOCKER_DEVKIT_ARGS ?= \
	$(DOCKER_ULIMIT_ARGS) \
	$(DOCKER_DEVKIT_USER_ARGS) \
	--volume $(REPO_ROOT_DIR):/kib \
	--workdir /kib \
	$(DOCKER_SOCKET_ARGS) \
	$(DOCKER_DEVKIT_AWS_ARGS) \
	$(DOCKER_DEVKIT_PUSH_ARGS) \
	$(DOCKER_DEVKIT_ENV_ARGS)


export DOCKER_DEVKIT_DEFAULT_ARGS ?= \
	--rm \
	$(if $(INTERACTIVE),--tty) \
	--interactive

ifneq ($(shell git status --porcelain 2>/dev/null; echo $$?), 0)
	export GIT_TREE_STATE := dirty
else
	export GIT_TREE_STATE :=
endif

# NOTE(jkoelker) Abuse ifeq and the junk variable to proxy docker image state
#                to the target file
ifneq ($(shell command -v docker),)
	ifeq ($(shell docker image ls --quiet "$(DOCKER_DEVKIT_IMG)"),)
		export junk := $(shell rm -rf $(DOCKER_DEVKIT_PHONY_FILE))
	endif
	ifeq ($(shell docker image ls --quiet "$(DOCKER_IMG)"),)
		export junk := $(shell rm -rf $(DOCKER_PHONY_FILE))
	endif
endif

$(DOCKER_DEVKIT_PHONY_FILE): Dockerfile.devkit
	docker build \
		--build-arg USER_ID=$(UID) \
		--build-arg GROUP_ID=$(GID) \
		--build-arg USER_NAME=$(USER_NAME) \
		--build-arg GROUP_NAME=$(GROUP_NAME) \
		--build-arg DOCKER_GID=$(DOCKER_SOCKET_GID) \
		--file $(REPO_ROOT_DIR)/Dockerfile.devkit \
		--tag "$(DOCKER_DEVKIT_IMG)" \
		$(REPO_ROOT_DIR) \
	&& touch $(DOCKER_DEVKIT_PHONY_FILE)

$(DOCKER_PHONY_FILE): $(DOCKER_DEVKIT_PHONY_FILE)
$(DOCKER_PHONY_FILE): bin/konvoy-image
$(DOCKER_PHONY_FILE): Dockerfile
	docker build \
		--file $(REPO_ROOT_DIR)/Dockerfile \
		--tag "$(DOCKER_IMG)" \
		$(REPO_ROOT_DIR) \
	&& touch $(DOCKER_PHONY_FILE)

.PHONY: devkit
devkit: $(DOCKER_DEVKIT_PHONY_FILE)

WHAT ?= bash

.PHONY: devkit.run
devkit.run: ## run $(WHAT) in devkit
devkit.run: devkit
	docker run \
		$(DOCKER_DEVKIT_DEFAULT_ARGS) \
		$(DOCKER_DEVKIT_ARGS) \
		"$(DOCKER_DEVKIT_IMG)" \
		$(WHAT)

.PHONY: centos7
centos7: build
centos7: ## Build Centos 7 image
	./bin/konvoy-image build images/ami/centos-7.yaml

.PHONY: centos7-nvidia
centos7-nvidia: build
centos7-nvidia: ## Build Centos 7 image with GPU support
	./bin/konvoy-image build images/ami/centos-7.yaml --overrides overrides/nvidia.yaml

.PHONY: centos8
centos8: build
centos8: ## Build Centos 8 image
	./bin/konvoy-image build images/ami/centos-8.yaml

.PHONY: centos8-nvidia
centos8-nvidia: build
centos8-nvidia: ## Build Centos 8 image with GPU support
	./bin/konvoy-image build images/ami/centos-8.yaml --overrides overrides/nvidia.yaml

.PHONY: rhel8
rhel8: build
rhel8: ## Build RHEL 8.2 image
	./bin/konvoy-image build images/ami/rhel-8.yaml

.PHONY: rhel8-nvidia
rhel8-nvidia: build
rhel8-nvidia: ## Build RHEL 8.2 image with GPU support
	./bin/konvoy-image build images/ami/rhel-8.yaml --overrides overrides/nvidia.yaml

.PHONY: rhel84
rhel84: build
rhel84: ## Build RHEL 8.4 image
	./bin/konvoy-image build images/ami/rhel-84.yaml

.PHONY: rhel84-nvidia
rhel84-nvidia: build
rhel84-nvidia: ## Build RHEL 8.4 image with GPU support
	./bin/konvoy-image build images/ami/rhel-84.yaml --overrides overrides/nvidia.yaml

flatcar-version.yaml:
	./hack/fetch-flatcar-ami.sh

.PHONY: flatcar
flatcar: build flatcar-version.yaml
flatcar: ## Build flatcar image
	./bin/konvoy-image build images/ami/flatcar.yaml --overrides flatcar-version.yaml

.PHONY: flatcar-nvidia
flatcar-nvidia: build flatcar-version.yaml
flatcar-nvidia: ## Build flatcar image with GPU support
	./bin/konvoy-image build --region us-west-2 \
	--aws-instance-type p2.xlarge \
	images/ami/flatcar.yaml \
	--overrides overrides/nvidia.yaml

.PHONY: ubuntu18
ubuntu18: build
ubuntu18: ## Build Ubuntu 20 image
	./bin/konvoy-image build images/ami/ubuntu-18.yaml

.PHONY: ubuntu20
ubuntu20: build
ubuntu20: ## Build Ubuntu 20 image
	./bin/konvoy-image build images/ami/ubuntu-20.yaml

.PHONY: ubuntu20-nvidia
ubuntu20-nvidia: build
ubuntu20-nvidia: ## Build Ubuntu 20 image with GPU support
	./bin/konvoy-image build images/ami/ubuntu-20.yaml --overrides overrides/nvidia.yaml

.PHONY: oracle7
oracle7: build
oracle7: ## Build Oracle Linux 7 image
	./bin/konvoy-image build images/ami/oracle-7.yaml

.PHONY: oracle8
oracle8: build
oracle8: ## Build Oracle Linux 8 image
	./bin/konvoy-image build images/ami/oracle-8.yaml

.PHONY: dev
dev: ## dev build
dev: clean generate build lint test mod-tidy build.snapshot

.PHONY: ci
ci: ## CI build
ci: dev diff

.PHONY: clean
clean: ## remove files created during build
	$(call print-target)
	rm -rf bin
	rm -rf dist
	rm -rf "$(REPO_ROOT_DIR)/cmd/konvoy-image-wrapper/image/konvoy-image-builder.tar.gz"
	rm -f flatcar-version.yaml
	rm -f $(COVERAGE)*
	docker image rm $(DOCKER_DEVKIT_IMG) || echo "image already removed"

.PHONY: generate
generate: ## go generate
	$(call print-target)
	go generate ./...

bin/konvoy-image: $(REPO_ROOT_DIR)/cmd
bin/konvoy-image: $(shell find $(REPO_ROOT_DIR)/cmd -type f -name '*'.go)
bin/konvoy-image: $(REPO_ROOT_DIR)/pkg
bin/konvoy-image: $(shell find $(REPO_ROOT_DIR)/pkg -type f -name '*'.go)
bin/konvoy-image: $(shell find $(REPO_ROOT_DIR)/pkg -type f -name '*'.tmpl)
bin/konvoy-image:
	$(call print-target)
	go build -o ./bin/konvoy-image ./cmd/konvoy-image/main.go

bin/konvoy-image-wrapper:
	$(call print-target)
	CGO_ENABLED=0 go build -o ./bin/konvoy-image-wrapper ./cmd/konvoy-image-wrapper/main.go

dist/konvoy-image_linux_amd64/konvoy-image: $(REPO_ROOT_DIR)/cmd
dist/konvoy-image_linux_amd64/konvoy-image: $(shell find $(REPO_ROOT_DIR)/cmd -type f -name '*'.go)
dist/konvoy-image_linux_amd64/konvoy-image: $(REPO_ROOT_DIR)/pkg
dist/konvoy-image_linux_amd64/konvoy-image: $(shell find $(REPO_ROOT_DIR)/pkg -type f -name '*'.go)
dist/konvoy-image_linux_amd64/konvoy-image: $(shell find $(REPO_ROOT_DIR)/pkg -type f -name '*'.tmpl)
dist/konvoy-image_linux_amd64/konvoy-image:
	$(call print-target)
	goreleaser build --snapshot --rm-dist --id konvoy-image --single-target

.PHONY: build
build: bin/konvoy-image
build: ## go build

.PHONY: docs
docs: build
	$(REPO_ROOT_DIR)/bin/konvoy-image generate-docs $(REPO_ROOT_DIR)/docs/cli

.PHONY: docs.check
docs.check: docs
docs.check:
	@test -z "$(shell git status --porcelain -- $(REPO_ROOT_DIR)/docs)" \
		|| (echo ''; \
			echo 'Need docs update:'; \
			echo ''; \
			git status --porcelain -- "$(REPO_ROOT_DIR)/docs"; \
			echo ''; \
			echo 'Run `make docs` and commit the results'; \
			exit 1)

.PHONY: lint
lint: ## golangci-lint
	$(call print-target)
	golangci-lint run -c .golangci.yml --fix

# Add a convience alias
.PHONY: super-linter
super-linter: super-lint

.PHONY: super-lint
include $(REPO_ROOT_DIR)/.github/super-linter.env
export
export DOCKER_SUPER_LINTER_ARGS ?= \
	--env RUN_LOCAL=true \
	--env-file $(REPO_ROOT_DIR)/.github/super-linter.env \
	--volume $(REPO_ROOT_DIR):/tmp/lint
export DOCKER_SUPER_LINTER_VERSION ?= $(shell \
	grep 'uses: github/super-linter' $(REPO_ROOT_DIR)/.github/workflows/lint.yml | cut -d@ -f2 \
)
export DOCKER_SUPER_LINTER_IMG := github/super-linter:$(DOCKER_SUPER_LINTER_VERSION)

super-lint: ## run all linting with super-linter
	$(call print-target)
	docker run \
		--rm \
		$(if $(INTERACTIVE),--tty) \
		--interactive \
		$(DOCKER_SUPER_LINTER_ARGS) \
		$(DOCKER_SUPER_LINTER_IMG)

.PHONY: super-lint-shell
super-lint-shell: ## open a shell in the super-linter container
	$(call print-target)
	docker run \
		--rm \
		$(if $(INTERACTIVE),--tty) \
		--interactive \
		$(DOCKER_SUPER_LINTER_ARGS) \
		--workdir=/tmp/lint \
		--entrypoint="/bin/bash" \
		$(DOCKER_SUPER_LINTER_IMG) -l

.PHONY: test
test: ## go test with race detector and code coverage
	$(call print-target)
	go-acc --covermode=atomic --output=$(COVERAGE).out --ignore=e2e ./... -- -race -short -v
ifneq ($(CI),)
	gocover-cobertura -by-files < $(COVERAGE).out > $(COVERAGE).xml
else
	go tool cover -html=$(COVERAGE).out -o $(COVERAGE).html
endif


.PHONY: integration-test
integration-test: ## go test with race detector for integration tests
	$(call print-target)
	go test -race -run Integration -v ./...

.PHONY: mod-tidy
mod-tidy: ## go mod tidy
	$(call print-target)
	go mod tidy

.PHONY: build-snapshot
build.snapshot: dist/konvoy-image_linux_amd64/konvoy-image
build.snapshot:
	$(call print-target)
	# NOTE(jkoelker) shenanigans to get around goreleaser and
	#                `make release-bundle` being able to share the same
	#                `Dockerfile`. Unfortunatly goreleaser forbids
	#                copying the dist folder into the temporary folder
	#                that it uses as its docker build context ;(.
	mkdir -p bin
	cp dist/konvoy-image_linux_amd64/konvoy-image bin/konvoy-image
	goreleaser --parallelism=1 --skip-publish --snapshot --rm-dist

.PHONY: diff
diff: ## git diff
	$(call print-target)
	git diff --exit-code
	RES=$$(git status --porcelain) ; if [ -n "$$RES" ]; then echo $$RES && exit 1 ; fi

.PHONY: release
release: ## goreleaser --rm-dist
	$(call print-target)
	goreleaser --parallelism=1 --rm-dist

.PHONY: release-snapshot
release-snapshot: ## goreleaser --snapshot --rm-dist
	$(call print-target)
	goreleaser release --snapshot --skip-publish --rm-dist

.PHONY: go-clean
go-clean: ## go clean build, test and modules caches
	$(call print-target)
	go clean -r -i -cache -testcache -modcache

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

define print-target
    @printf "Executing target: \033[36m$@\033[0m\n"
endef

docker.clean-latest-ami:
	WHAT="./test/scripts/clean-latest-ami.sh" make -C test/scripts docker.run

# requires ANSIBLE_PATH, otherwise run `make ci.e2e.ansible`
e2e.ansible:
	make -C test/e2e/ansible e2e

ifeq ($(CI), true)
export DOCKER_DEVKIT_AWS_ARGS := --env AWS_ACCESS_KEY_ID --env AWS_SECRET_ACCESS_KEY
endif

ci.e2e.build.all:
	WHAT="make build" make devkit.run
	WHAT="./bin/konvoy-image build images/ami/centos-7.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami
	WHAT="./bin/konvoy-image build images/ami/centos-8.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami
	WHAT="./bin/konvoy-image build images/ami/ubuntu-18.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami
	WHAT="./bin/konvoy-image build images/ami/ubuntu-20.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami
	WHAT="./bin/konvoy-image build images/ami/sles-15.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami
	WHAT="./bin/konvoy-image build images/ami/centos-7.yaml --overrides overrides/nvidia.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami
	WHAT="./bin/konvoy-image build images/ami/centos-8.yaml --overrides overrides/nvidia.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami
	WHAT="./bin/konvoy-image build images/ami/sles-15.yaml --overrides overrides/nvidia.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami
	WHAT="./bin/konvoy-image build images/ami/oracle-7.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami
	WHAT="./bin/konvoy-image build images/ami/oracle-8.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami
	WHAT="make flatcar-version.yaml" make devkit.run
	WHAT="./bin/konvoy-image build images/ami/flatcar.yaml --overrides flatcar-version.yaml -v ${VERBOSITY}" make devkit.run
	make docker.clean-latest-ami

# use sibling containers to handle dependencies and avoid DinD
ci.e2e.ansible:
	make -C test/e2e/ansible e2e.setup
	WHAT="make -C test/e2e/ansible e2e.run" DOCKER_DEVKIT_DEFAULT_ARGS="--rm --net=host" make devkit.run
	make -C test/e2e/ansible e2e.clean

release-bundle-GOOS:
	GOOS=$(GOOS) CGO_ENABLED=0 go build -tags EMBED_DOCKER_IMAGE \
		-ldflags="-X github.com/mesosphere/konvoy-image-builder/pkg/version.version=$(REPO_REV)" \
		-o "$(REPO_ROOT_DIR)/dist/bundle/konvoy-image-bundle-$(REPO_REV)_$(GOOS)/konvoy-image" $(REPO_ROOT_DIR)/cmd/konvoy-image-wrapper/main.go
	cp -a "$(REPO_ROOT_DIR)/ansible" "$(REPO_ROOT_DIR)/dist/bundle/konvoy-image-bundle-$(REPO_REV)_$(GOOS)/"
	cp -a "$(REPO_ROOT_DIR)/goss" "$(REPO_ROOT_DIR)/dist/bundle/konvoy-image-bundle-$(REPO_REV)_$(GOOS)/"
	cp -a "$(REPO_ROOT_DIR)/images" "$(REPO_ROOT_DIR)/dist/bundle/konvoy-image-bundle-$(REPO_REV)_$(GOOS)/"
	cp -a "$(REPO_ROOT_DIR)/overrides" "$(REPO_ROOT_DIR)/dist/bundle/konvoy-image-bundle-$(REPO_REV)_$(GOOS)/"
	cp -a "$(REPO_ROOT_DIR)/packer" "$(REPO_ROOT_DIR)/dist/bundle/konvoy-image-bundle-$(REPO_REV)_$(GOOS)/"
	tar -C "$(REPO_ROOT_DIR)/dist/bundle" -czf "$(REPO_ROOT_DIR)/dist/bundle/konvoy-image-bundle-$(REPO_REV)_$(GOOS).tar.gz" "konvoy-image-bundle-$(REPO_REV)_$(GOOS)"

cmd/konvoy-image-wrapper/image/konvoy-image-builder.tar.gz: $(DOCKER_PHONY_FILE)
	docker save $(DOCKER_IMG) | gzip -c - > "$(REPO_ROOT_DIR)/cmd/konvoy-image-wrapper/image/konvoy-image-builder.tar.gz"

release-bundle: cmd/konvoy-image-wrapper/image/konvoy-image-builder.tar.gz
	$(MAKE) GOOS=linux release-bundle-GOOS
	$(MAKE) GOOS=windows release-bundle-GOOS
	$(MAKE) GOOS=darwin release-bundle-GOOS
