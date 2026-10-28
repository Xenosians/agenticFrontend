#!/bin/sh
set -eu
: "${PUBLIC_HOST:?PUBLIC_HOST is required}"
status=$(curl --silent --show-error --max-time 7 --output /dev/null --write-out '%{http_code}' \
  --resolve "$PUBLIC_HOST:8443:127.0.0.1" "https://$PUBLIC_HOST:8443/index.html")
test "$status" = 200
