#!/bin/sh
set -eu

: "${PUBLIC_HOST:?PUBLIC_HOST is required}"
: "${PUBLIC_ORIGIN:?PUBLIC_ORIGIN is required}"
case "$PUBLIC_HOST" in ''|*[!a-zA-Z0-9.-]*) echo 'Invalid PUBLIC_HOST' >&2; exit 64;; esac
case "$PUBLIC_ORIGIN" in *[!a-zA-Z0-9:/.-]*) echo 'Invalid PUBLIC_ORIGIN' >&2; exit 64;; esac
if ! printf '%s\n' "$PUBLIC_ORIGIN" | grep -Eq '^https://[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]+)?$'; then
  echo 'PUBLIC_ORIGIN must be an HTTPS origin without a path or credentials' >&2
  exit 64
fi
origin_host=${PUBLIC_ORIGIN#https://}
authority=$origin_host
origin_host=${authority%%:*}
if [ "$origin_host" != "$PUBLIC_HOST" ]; then
  echo 'PUBLIC_ORIGIN and PUBLIC_HOST must name the same host' >&2
  exit 64
fi
case "$authority" in
  *:*)
    port=${authority##*:}
    if [ "${#port}" -gt 5 ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ] || [ "$port" = 443 ]; then
      echo 'PUBLIC_ORIGIN must use a valid non-default port, or omit port 443' >&2
      exit 64
    fi
    ;;
esac

template=${NGINX_CONFIG_TEMPLATE:-/opt/janus/nginx.conf.template}
output=${NGINX_CONFIG_OUTPUT:-/tmp/janus-nginx.conf}
# The image, including its web root, is read-only. The browser's runtime
# configuration is written to the container's tmpfs and served by nginx.
FRONTEND_RUNTIME_DIR=${FRONTEND_RUNTIME_DIR:-/tmp/janus-frontend}
case "$FRONTEND_RUNTIME_DIR" in /*) ;; *) echo 'FRONTEND_RUNTIME_DIR must be absolute' >&2; exit 64;; esac
case "$FRONTEND_RUNTIME_DIR" in *[!a-zA-Z0-9/._-]*|*..*) echo 'Invalid FRONTEND_RUNTIME_DIR' >&2; exit 64;; esac
TLS_CERT_PATH=${TLS_CERT_PATH:-/run/tls/tls.crt}
TLS_KEY_PATH=${TLS_KEY_PATH:-/run/tls/tls.key}
case "$TLS_CERT_PATH:$TLS_KEY_PATH" in *[!a-zA-Z0-9/._:-]*) echo 'Invalid TLS file path' >&2; exit 64;; esac
case "$TLS_CERT_PATH" in /*) ;; *) echo 'TLS paths must be absolute' >&2; exit 64;; esac
case "$TLS_KEY_PATH" in /*) ;; *) echo 'TLS paths must be absolute' >&2; exit 64;; esac
test -r "$TLS_CERT_PATH"
test -r "$TLS_KEY_PATH"
export TLS_CERT_PATH TLS_KEY_PATH FRONTEND_RUNTIME_DIR
mkdir -p "$FRONTEND_RUNTIME_DIR"
printf 'window.AGENTIC_CONFIG = Object.freeze({backendBaseUrl:"%s",pollIntervalMs:1000,healthIntervalMs:30000});\n' \
  "$PUBLIC_ORIGIN" > "$FRONTEND_RUNTIME_DIR/config.js"
# Behind a company port forward, a cloud load balancer or another reverse proxy,
# every connection comes from that proxy. EDGE_TRUSTED_PROXIES lists the exact
# addresses or ranges (comma separated) allowed to name the real client in
# X-Forwarded-For, so the per-client sign-in limits still count real clients.
# Empty (the default) trusts nobody: the connecting address is the client.
real_ip="$FRONTEND_RUNTIME_DIR/real-ip.conf"
: > "$real_ip"
case "${EDGE_TRUSTED_PROXIES:-}" in *"
"*) echo "Invalid EDGE_TRUSTED_PROXIES entry" >&2; exit 64;; esac
if [ -n "${EDGE_TRUSTED_PROXIES:-}" ]; then
  for proxy in $(printf '%s' "$EDGE_TRUSTED_PROXIES" | tr ',' ' '); do
    if ! printf '%s\n' "$proxy" | grep -Eq '^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*)(/[0-9]{1,3})?$'; then
      echo "Invalid EDGE_TRUSTED_PROXIES entry" >&2; exit 64
    fi
    case "$proxy" in */0|*/00|*/000) echo "EDGE_TRUSTED_PROXIES must not trust every address" >&2; exit 64;; esac
    printf 'set_real_ip_from %s;\n' "$proxy" >> "$real_ip"
  done
  printf 'real_ip_header X-Forwarded-For;\nreal_ip_recursive on;\n' >> "$real_ip"
fi
# Restrict substitution so nginx's request variables survive intact.
envsubst '${PUBLIC_HOST} ${TLS_CERT_PATH} ${TLS_KEY_PATH} ${FRONTEND_RUNTIME_DIR}' < "$template" > "$output"
exec "$@"
