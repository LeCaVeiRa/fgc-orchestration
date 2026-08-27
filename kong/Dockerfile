FROM kong:3.7

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /fgc-docker-entrypoint.sh
RUN chmod +x /fgc-docker-entrypoint.sh

USER kong
ENTRYPOINT ["/fgc-docker-entrypoint.sh"]
