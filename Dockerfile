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
# Build contexts from Windows filesystems arrive world-writable; normalise modes.
# The development config.js is not shipped: the container renders its own, so a
# missing runtime configuration fails closed instead of pointing at a dev backend.
RUN nimble build --accept && rm public/config.js && chmod -R u=rwX,go=rX public

# Runtime image contract: official Alpine-based nginx image, with its nginx user.
FROM ${NGINX_RUNTIME_IMAGE} AS runtime
USER root
RUN apk add --no-cache curl gettext
# The web root stays root-owned and read-only for nginx; the entrypoint renders
# runtime values onto the container's tmpfs.
COPY --from=build /src/public /usr/share/nginx/html
COPY docker/nginx.conf.template /opt/janus/nginx.conf.template
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/janus-frontend
COPY --chmod=755 docker/healthcheck.sh /usr/local/bin/janus-frontend-health
USER 101:101
EXPOSE 8443
ENTRYPOINT ["/usr/local/bin/janus-frontend"]
CMD ["nginx", "-c", "/tmp/janus-nginx.conf", "-g", "daemon off;"]
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 CMD ["/usr/local/bin/janus-frontend-health"]
