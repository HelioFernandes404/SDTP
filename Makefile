REGISTRY ?= docker.io
IMAGE    ?= contador

# VCS_REF e VERSION: calculados uma única vez, e só se algum alvo usar (lint não precisa do cog).
# "X = $(eval X := ...)$(X)": na primeira leitura troca a si mesma pelo valor e não roda de novo.
# Valor passado na linha de comando (o CI passa VERSION pronta) tem prioridade; variável de ambiente não.
# "1.5.0" numa tag v1.5.0; "1.5.0-rc.3.gd743945" fora de tag (ver scripts/versao.sh).
ifneq ($(origin VCS_REF),command line)
VCS_REF = $(eval VCS_REF := $$(shell git rev-parse HEAD))$(VCS_REF)
endif
ifneq ($(origin VERSION),command line)
VERSION = $(eval VERSION := $$(shell ./scripts/versao.sh))$(VERSION)
endif

.PHONY: image image-push image-test image-scan lint deploy release

image:  ## builda a imagem com tag rastreável até o commit
	@test -n "$(VERSION)" || { echo "erro: VERSION vazia (scripts/versao.sh falhou; cog instalado?)" >&2; exit 1; }
	docker build \
	  --build-arg REGISTRY=$(REGISTRY) \
	  --build-arg VCS_REF=$(VCS_REF) \
	  --build-arg VERSION=$(VERSION) \
	  -t $(IMAGE):$(VERSION) .
	@echo "imagem: $(IMAGE):$(VERSION)"

image-push:  ## publica no registry; nunca sobrescreve tag (mesmo commit = nada a fazer)
	./scripts/publicar-imagem.sh "$(IMAGE)" "$(VERSION)" "$(VCS_REF)" "$(REGISTRY)"

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
