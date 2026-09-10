#!/usr/bin/env bash
# Creates the TLS secret LiveKit's TURN server needs (livekit.turn.tlsSecret in the chart
# values), run on the bastion host after scripts/bootstrap-cluster.sh. Browsers only use
# TURN over TLS when they trust the certificate, so a self-signed one is useless.
#
#   scripts/setup-turn-tls.sh copy          (default) copy the cluster's wildcard ingress
#                                           certificate into the project, after checking
#                                           that it is publicly trusted and covers *.<domain>
#   scripts/setup-turn-tls.sh cert-manager  ask Let's Encrypt for a certificate through
#                                           cert-manager (ACME HTTP-01 via an OpenShift route)
#   PROJECT=voice-avatar-assistant  SECRET=livekit-turn-tls  ACME_EMAIL=<you@example.com>
set -uo pipefail
MODE="${1:-copy}"
PROJECT="${PROJECT:-voice-avatar-assistant}"
SECRET="${SECRET:-livekit-turn-tls}"
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
info() { printf '  ..   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
cert_ready() { [ "$(oc get certificate "$SECRET" -n "$PROJECT" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; }
DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}') || { fail "not logged in"; exit 1; }
HOST="livekit-turn-${PROJECT}.${DOMAIN}"
oc get namespace "$PROJECT" >/dev/null 2>&1 || { fail "project $PROJECT missing: run scripts/bootstrap-cluster.sh first"; exit 1; }
echo "TURN host: $HOST"

case "$MODE" in
copy)
  name=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
  name="${name:-router-certs-default}"
  info "ingress certificate secret: openshift-ingress/$name"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  oc get secret "$name" -n openshift-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmp/tls.crt" || { fail "cannot read the ingress certificate"; exit 1; }
  oc get secret "$name" -n openshift-ingress -o jsonpath='{.data.tls\.key}' | base64 -d > "$tmp/tls.key"
  subject=$(openssl x509 -in "$tmp/tls.crt" -noout -subject -issuer -enddate | tr '\n' ' ')
  info "$subject"
  if ! openssl x509 -in "$tmp/tls.crt" -noout -ext subjectAltName | grep -q "\*\.${DOMAIN}"; then
    fail "the certificate does not cover *.${DOMAIN}; use: scripts/setup-turn-tls.sh cert-manager"; exit 2; fi
  if openssl verify -untrusted "$tmp/tls.crt" "$tmp/tls.crt" >/dev/null 2>&1; then ok "certificate chain is trusted by this host's CA store"; else
    fail "the ingress certificate is not publicly trusted (self-signed cluster); use: scripts/setup-turn-tls.sh cert-manager"; exit 2; fi
  oc create secret tls "$SECRET" -n "$PROJECT" --cert="$tmp/tls.crt" --key="$tmp/tls.key" --dry-run=client -o yaml | oc apply -f - >/dev/null && ok "secret $PROJECT/$SECRET created from the wildcard certificate"
  echo "Note: the wildcard certificate rotates; rerun this script when it does (check: oc get secret $SECRET -n $PROJECT -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate)."
  ;;
cert-manager)
  : "${ACME_EMAIL:?set ACME_EMAIL=<address for ACME expiry notices>}"
  oc get crd clusterissuers.cert-manager.io >/dev/null 2>&1 || { fail "cert-manager is not installed (deploy/bootstrap/operators/cert-manager.yaml)"; exit 1; }
  oc apply -f - <<YAML >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-http01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-http01-account
    solvers:
      - http01:
          ingress:
            ingressClassName: openshift-default
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${SECRET}
  namespace: ${PROJECT}
spec:
  secretName: ${SECRET}
  dnsNames:
    - ${HOST}
  issuerRef:
    name: letsencrypt-http01
    kind: ClusterIssuer
YAML
  ok "ClusterIssuer letsencrypt-http01 and Certificate $PROJECT/$SECRET applied"
  waited=0
  until cert_ready; do
    if [ "$waited" -ge 600 ]; then fail "certificate not Ready after 10 min"; echo "  debug: oc describe certificate $SECRET -n $PROJECT; oc get order,challenge -n $PROJECT; oc describe challenge -n $PROJECT"; exit 1; fi
    sleep 15; waited=$((waited + 15)); [ $((waited % 60)) -eq 0 ] && info "waiting for the ACME challenge (${waited}s)"
  done
  ok "certificate Ready; secret $PROJECT/$SECRET issued for $HOST (renewed automatically)"
  ;;
*) echo "usage: scripts/setup-turn-tls.sh [copy|cert-manager]"; exit 1 ;;
esac
