# Imagem do contador.
#
# REGISTRY permite trocar o Docker Hub pelo mirror interno sem editar o arquivo:
#   docker build --build-arg REGISTRY=mirror.interno.local ...
# A base é fixada por digest (build reproduzível). O digest do índice multi-arch
# é o mesmo no Docker Hub e no mirror (conferido com `docker buildx imagetools inspect`).
# Atualização do digest: Renovate/Dependabot abre PR.
ARG REGISTRY=docker.io
ARG PYTHON_IMAGE=library/python:3.12-slim-bookworm
ARG PYTHON_DIGEST=sha256:44cf1793efa7c7a476bb0f2cff81443f4a072c90c1cb127e2924933daa3e8c64

FROM ${REGISTRY}/${PYTHON_IMAGE}@${PYTHON_DIGEST}

# Rastreabilidade: SHA completo do commit. Obrigatório (sem "unknown" em imagem publicada).
ARG VCS_REF
ARG VERSION=dev
RUN test -n "${VCS_REF}" || { echo "erro: --build-arg VCS_REF=<sha do commit> é obrigatório" >&2; exit 1; }
LABEL org.opencontainers.image.title="contador" \
      org.opencontainers.image.source="https://github.com/HelioFernandes404/SDTP" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/data \
    PORT=8080

# UID/GID numéricos e fixos: o k8s só consegue validar runAsNonRoot com UID numérico.
# /data com dono 10001: volume nomeado novo (Swarm/Docker) herda essa permissão.
# Sem VOLUME de propósito: quem fornece o volume é o orquestrador.
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app \
 && mkdir -p /data \
 && chown 10001:10001 /data

WORKDIR /app
# Arquivos de root e só leitura: o processo não consegue alterar o próprio código.
COPY --chmod=0555 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0444 app/app.py /app/app.py

USER 10001:10001
EXPOSE 8080

# Vale para docker run e Swarm; no Kubernetes usamos probes (Parte 3).
HEALTHCHECK --interval=15s --timeout=3s --retries=3 --start-period=10s \
  CMD ["python3", "-c", "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.environ.get('PORT', '8080'), timeout=2)"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["python3", "/app/app.py"]
