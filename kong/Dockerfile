FROM kong:3.7.1

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Template embutido para o EKS; no compose o volume em /kong-src sobrescreve (edição sem rebuild).
COPY kong.yml.template /kong-src/kong.yml.template
COPY docker-entrypoint.sh /fgc-docker-entrypoint.sh
RUN chmod +x /fgc-docker-entrypoint.sh

USER kong
ENTRYPOINT ["/fgc-docker-entrypoint.sh"]
