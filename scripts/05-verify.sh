#!/usr/bin/env bash
# scripts/05-verify.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "05 — Deployment Verification"

log_step "Flux Kustomizations"
flux get kustomizations -A

log_step "Flux HelmReleases"
flux get helmreleases -A

log_step "Pods — mattermost namespace"
kubectl get pods -n mattermost -o wide 2>/dev/null || echo "(namespace not yet created)"

log_step "Mattermost CR status"
kubectl get mattermost -n mattermost 2>/dev/null || echo "(Mattermost CR not yet created)"

log_step "Ingress"
kubectl get ingress -A 2>/dev/null

log_step "Sealed Secrets"
kubectl get sealedsecrets -n mattermost 2>/dev/null

log_step "TLS Certificates"
kubectl get certificates -A 2>/dev/null || echo "(no certificates yet)"

log_section "Access Summary"
INGRESS_IP=$(kubectl get svc \
  -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

echo ""
if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  echo "  Cluster Type   : kind (local dev)"
  echo "  Access URL     : http://${DOMAIN}  (HTTP only — no real TLS on kind)"
  echo ""
  echo "  Add to /etc/hosts:"
  echo "    ${INGRESS_IP}  ${DOMAIN}"
  echo "  Then open:  http://${DOMAIN}"
else
  echo "  Cluster Type   : kubeadm (on-prem)"
  echo "  Access URL     : https://${DOMAIN}"
  echo "  Ingress LB IP  : ${INGRESS_IP}"
  echo ""
  echo "  Ensure DNS A record: ${DOMAIN} → ${SERVER_IP}"
fi
echo ""
