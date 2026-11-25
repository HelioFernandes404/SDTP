REGISTRY ?= docker.io
IMAGE    ?= contador
VCS_REF  := $(shell git rev-parse HEAD)
# git describe: "1.4.2-3-g3f9a2c1" fora de tag, "1.5.0" numa tag; sem tags, o SHA curto.
VERSION  := $(shell git describe --tags --always --dirty | sed 's/^v//')

.PHONY: image image-test image-scan lint

image:  ## builda a imagem com tag rastreável até o commit
	docker build \
	  --build-arg REGISTRY=$(REGISTRY) \
	  --build-arg VCS_REF=$(VCS_REF) \
	  --build-arg VERSION=$(VERSION) \
	  -t $(IMAGE):$(VERSION) .
	@echo "imagem: $(IMAGE):$(VERSION)"

image-test: image  ## verificações da Parte 1
	./scripts/test-image.sh $(IMAGE):$(VERSION)

TRIVY_IMAGE ?= aquasec/trivy:0.58.1

image-scan: image  ## CVEs HIGH/CRITICAL com correção (trivy em contêiner, sem instalar nada)
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache \
	  $(TRIVY_IMAGE) image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 $(IMAGE):$(VERSION)

lint:  ## hadolint no Dockerfile e shellcheck nos scripts
	docker run --rm -i hadolint/hadolint:v2.12.0 < Dockerfile
	shellcheck -x docker/entrypoint.sh scripts/*.sh
	cd bootstrap && shellcheck -x bootstrap.sh
