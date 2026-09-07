#!/bin/sh
set -e
CONF=/opt/app-root/etc/nginx.default.d/app.conf
sed -i "s|__RAG_API_UPSTREAM__|${RAG_API_UPSTREAM:-rag-api:8080}|g" "$CONF"
exec nginx -g "daemon off;"
