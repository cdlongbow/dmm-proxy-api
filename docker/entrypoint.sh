#!/bin/sh
# Container entrypoint.
#
# Enables the HTTPS (443) server block only when both SSL certificate files
# exist in /etc/ssl/dmm/. If either is missing, HTTPS is disabled and only
# the HTTP (80) listener runs. The rendered result is written to
# /usr/local/openresty/nginx/conf/dmm.d/ssl.conf, which is included by
# conf/nginx.conf.
#
# Also renders /usr/local/openresty/nginx/conf/dmm.d/cache_dicts.conf from
# $DMM_CACHE_TOTAL (total MB for all query-result caches). Split by fixed
# percentages: findplay 2%, ranking 5%, search 5%, trailer 5%, todayupdate 5%,
# film_sample 20%, magnet gets the remaining share (58%). Default 250 if unset.
#
# NOTE: /api/searchrank analytics do NOT come from the query-result pools above.
# They live in their own fixed 1 m `searchrank_cache` dict (declared in
# nginx.conf) which is intentionally separate and never sized off DMM_CACHE_TOTAL.

set -e

CERT_DIR="${DMM_CERT_DIR:-/etc/ssl/dmm}"
CERT_FILE="${DMM_CERT_FILE:-fullchain.pem}"
KEY_FILE="${DMM_CERT_KEY:-private.key}"
CONF_DIR=/usr/local/openresty/nginx/conf/dmm.d
RENDERED="$CONF_DIR/ssl.conf"
TEMPLATE=/usr/local/openresty/nginx/conf/dmm.ssl.conf.template

mkdir -p "$CONF_DIR"

CACHE_TOTAL="${DMM_CACHE_TOTAL:-250}"
case "$CACHE_TOTAL" in
    ''|*[!0-9]*)
        echo "[entrypoint] warning: invalid DMM_CACHE_TOTAL='$DMM_CACHE_TOTAL', falling back to 250"
        CACHE_TOTAL=250
        ;;
esac
if [ "$CACHE_TOTAL" -lt 30 ]; then
    echo "[entrypoint] warning: DMM_CACHE_TOTAL=${CACHE_TOTAL}m too small (min 30m), falling back to 250"
    CACHE_TOTAL=250
fi

# Integer percentage split (truncating). magnet swallows the exact remainder so
# the seven caches always add up to exactly CACHE_TOTAL.
FINDPLAY_M=$(( CACHE_TOTAL * 2 / 100 ))
RANKING_M=$(( CACHE_TOTAL * 5 / 100 ))
SEARCH_M=$(( CACHE_TOTAL * 5 / 100 ))
TRAILER_M=$(( CACHE_TOTAL * 5 / 100 ))
TODAYUPDATE_M=$(( CACHE_TOTAL * 5 / 100 ))
FILM_SAMPLE_M=$(( CACHE_TOTAL * 20 / 100 ))
FIXED_M=$(( FINDPLAY_M + RANKING_M + SEARCH_M + TRAILER_M + TODAYUPDATE_M + FILM_SAMPLE_M ))
MAGNET_M=$(( CACHE_TOTAL - FIXED_M ))

min1() {
    if [ "$1" -ge 1 ]; then
        echo "$1"
    else
        echo 1
    fi
}
FINDPLAY_M=$(min1 "$FINDPLAY_M")
RANKING_M=$(min1 "$RANKING_M")
SEARCH_M=$(min1 "$SEARCH_M")
TRAILER_M=$(min1 "$TRAILER_M")
TODAYUPDATE_M=$(min1 "$TODAYUPDATE_M")
FILM_SAMPLE_M=$(min1 "$FILM_SAMPLE_M")
MAGNET_M=$(min1 "$MAGNET_M")

cat > "$CONF_DIR/cache_dicts.conf" <<EOF
# Auto-generated from DMM_CACHE_TOTAL=${CACHE_TOTAL}m by entrypoint.sh — do not edit.
lua_shared_dict magnet_cache ${MAGNET_M}m;
lua_shared_dict findplay_cache ${FINDPLAY_M}m;
lua_shared_dict search_cache ${SEARCH_M}m;
lua_shared_dict trailer_cache ${TRAILER_M}m;
lua_shared_dict todayupdate_cache ${TODAYUPDATE_M}m;
lua_shared_dict ranking_cache ${RANKING_M}m;
lua_shared_dict film_sample_cache ${FILM_SAMPLE_M}m;
EOF
echo "[entrypoint] cache dicts rendered (total ${CACHE_TOTAL}m): magnet=${MAGNET_M}m findplay=${FINDPLAY_M}m search=${SEARCH_M}m trailer=${TRAILER_M}m todayupdate=${TODAYUPDATE_M}m ranking=${RANKING_M}m film_sample=${FILM_SAMPLE_M}m"

if [ -f "$CERT_DIR/$CERT_FILE" ] && [ -f "$CERT_DIR/$KEY_FILE" ]; then
    echo "[entrypoint] SSL enabled: using $CERT_DIR/{$CERT_FILE,$KEY_FILE}"
    cp "$TEMPLATE" "$RENDERED"
else
    echo "[entrypoint] SSL disabled: no certificate files in $CERT_DIR, HTTP only"
    : > "$RENDERED"
fi

exec "$@"
