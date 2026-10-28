# syntax=docker/dockerfile:1
# Supply reviewed image references explicitly; see the AI deploy/README.md.
ARG NIM_BUILD_IMAGE
ARG NGINX_RUNTIME_IMAGE
FROM ${NIM_BUILD_IMAGE} AS build
WORKDIR /src
COPY agenticFrontend.nimble ./
RUN nimble install --depsOnly --accept
COPY src ./src
COPY scripts ./scripts
COPY public ./public
RUN nimble build --accept

# Runtime image contract: official Alpine-based nginx image, with its nginx user.
FROM ${NGINX_RUNTIME_IMAGE} AS runtime
USER root
RUN apk add --no-cache curl gettext
COPY --from=build --chown=101:101 /src/public /usr/share/nginx/html
COPY docker/nginx.conf.template /opt/janus/nginx.conf.template
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/janus-frontend
COPY --chmod=755 docker/healthcheck.sh /usr/local/bin/janus-frontend-health
USER 101:101
EXPOSE 8443
ENTRYPOINT ["/usr/local/bin/janus-frontend"]
CMD ["nginx", "-c", "/tmp/janus-nginx.conf", "-g", "daemon off;"]
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 CMD ["/usr/local/bin/janus-frontend-health"]
