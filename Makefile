REGISTRY ?= docker.io
IMAGE    ?= contador
VCS_REF  ?= $(shell git rev-parse HEAD)
# "1.5.0" numa tag v1.5.0; "1.5.0-rc.3.d743945" fora de tag (ver scripts/versao.sh).
# ?= : o CI pode passar VERSION pronta; localmente é calculada só quando algum alvo usa.
VERSION  ?= $(shell ./scripts/versao.sh)

.PHONY: tag-livre image image-push image-test image-scan lint deploy release

image:  ## builda a imagem com tag rastreável até o commit
	docker build \
	  --build-arg REGISTRY=$(REGISTRY) \
	  --build-arg VCS_REF=$(VCS_REF) \
	  --build-arg VERSION=$(VERSION) \
	  -t $(IMAGE):$(VERSION) .
	@echo "imagem: $(IMAGE):$(VERSION)"

tag-livre:  # tags são imutáveis: falha antes do build se a tag já existe no registry
	@if docker manifest inspect $(IMAGE):$(VERSION) >/dev/null 2>&1; then \
	  echo "erro: $(IMAGE):$(VERSION) já existe no registry; tags são imutáveis" >&2; exit 1; fi

image-push: tag-livre image  ## publica no registry (recusa sobrescrever tag existente)
	docker push $(IMAGE):$(VERSION)

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

deploy:  ## contrato com o pipeline: make deploy AMBIENTE=homologacao IMAGE_TAG=<tag> (IMAGE e KUBE_CONTEXT no ambiente)
	./scripts/deploy.sh $(AMBIENTE) $(IMAGE_TAG)

release:  ## cria e envia a tag vX.Y.Z calculada pelo cog (só da develop, com confirmação)
	./scripts/release.sh
