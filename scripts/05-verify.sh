#!/usr/bin/env bash
# scripts/05-verify.sh
# Verifies the full stack and diagnoses the three most common failures:
#   1. Ingress LoadBalancer IP not assigned (MetalLB issue)
#   2. Domain not resolving (DNS A record missing)
#   3. Port 80/443 blocked (cloud security group / firewall)
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
kubectl get pods -n mattermost -o wide 2>/dev/null || echo "  (namespace not yet created)"

log_step "Mattermost CR status"
kubectl get mattermost -n mattermost 2>/dev/null || echo "  (Mattermost CR not yet created)"

log_step "Ingress resources"
kubectl get ingress -A 2>/dev/null

log_step "Sealed Secrets"
kubectl get sealedsecrets -n mattermost 2>/dev/null

log_step "TLS Certificates"
kubectl get certificates -A 2>/dev/null || echo "  (no certificates yet)"

# ── Ingress IP check ─────────────────────────────────────────────────────────
log_step "Checking nginx LoadBalancer IP (MetalLB assignment)"
INGRESS_IP=$(kubectl get svc \
  -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [[ -z "$INGRESS_IP" || "$INGRESS_IP" == "null" ]]; then
  log_warn "Ingress LoadBalancer IP is not yet assigned — MetalLB may still be initialising."
  echo ""
  echo "  Wait 1-2 minutes then check:"
  echo "    kubectl get svc -n ingress-nginx ingress-nginx-controller"
  echo ""
  echo "  If EXTERNAL-IP stays <pending> after 5 min, diagnose with:"
  echo "    kubectl logs -n metallb-system -l component=controller --tail=40"
  echo "    kubectl get ipaddresspools -n metallb-system"
  echo ""
  echo "  Common cause: METALLB_IP_RANGE in .env does not match the server IP."
  echo "  Current value: ${METALLB_IP_RANGE:-not set}"
  echo "  Expected:      ${SERVER_IP}/32"
else
  log_ok "Ingress LoadBalancer IP: ${INGRESS_IP}"
  if [[ "$INGRESS_IP" != "$SERVER_IP" ]]; then
    log_warn "Ingress IP (${INGRESS_IP}) != SERVER_IP (${SERVER_IP})"
    echo "  On AWS, make sure METALLB_IP_RANGE is your Elastic IP (public IP),"
    echo "  not the private/internal IP. Private IPs are not internet-routable."
  fi
fi

CERT_STATUS=""

# ── Domain DNS and port checks (kubeadm only) ────────────────────────────────
if [[ "${CLUSTER_TYPE}" != "kind" ]]; then
  log_step "Checking DNS resolution for ${DOMAIN}"
  RESOLVED_IP=$(dig +short "${DOMAIN}" A 2>/dev/null | tail -1 || true)
  if [[ -z "$RESOLVED_IP" ]]; then
    log_warn "DNS: ${DOMAIN} does not resolve to any IP yet."
    echo ""
    echo "  Action required — add a DNS A record at your registrar/DNS provider:"
    echo "    Name  : ${DOMAIN}  (or @ if this is the apex/root domain)"
    echo "    Type  : A"
    echo "    Value : ${SERVER_IP}"
    echo "    TTL   : 300  (5 minutes — use low TTL while testing)"
  elif [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
    log_warn "DNS: ${DOMAIN} resolves to ${RESOLVED_IP} but SERVER_IP is ${SERVER_IP}"
    echo "  Update the A record to point to ${SERVER_IP}"
  else
    log_ok "DNS: ${DOMAIN} -> ${SERVER_IP}"
  fi

  log_step "Checking ports 80 and 443 reachability on ${SERVER_IP}"
  check_port() {
    local port="$1"
    if timeout 5 bash -c ">/dev/tcp/${SERVER_IP}/${port}" 2>/dev/null; then
      log_ok "Port ${port} open"
    else
      log_warn "Port ${port} is NOT reachable from your machine"
      echo ""
      echo "  This is the most common reason the domain does not load on AWS."
      echo "  Fix: EC2 console -> Security Groups -> Inbound Rules -> Add rules:"
      echo "    HTTP   port 80  source 0.0.0.0/0"
      echo "    HTTPS  port 443 source 0.0.0.0/0"
      echo ""
      echo "  Also allow in the OS firewall on the server:"
      echo "    sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw reload"
    fi
  }
  check_port 80
  check_port 443

  log_step "TLS certificate status"
  CERT_STATUS=$(kubectl get certificate mattermost-tls -n mattermost \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$CERT_STATUS" == "True" ]]; then
    log_ok "TLS certificate issued and ready"
  elif [[ -z "$CERT_STATUS" ]]; then
    log_info "TLS certificate not yet created. cert-manager will issue it automatically once:"
    echo "    1. Mattermost Ingress is deployed"
    echo "    2. DNS A record points ${DOMAIN} -> ${SERVER_IP}"
    echo "    3. Ports 80/443 are open (Let's Encrypt HTTP-01 challenge)"
  else
    log_warn "TLS certificate not ready (status: ${CERT_STATUS})"
    echo "  Debug commands:"
    echo "    kubectl describe certificate mattermost-tls -n mattermost"
    echo "    kubectl describe certificaterequest -n mattermost"
    echo "    kubectl describe challenge -n mattermost 2>/dev/null"
  fi
fi

# ── Final summary ─────────────────────────────────────────────────────────────
log_section "Access Summary"
echo ""
if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  echo "  Cluster Type  : kind (local dev)"
  echo "  Ingress IP    : ${INGRESS_IP:-pending}"
  echo ""
  echo "  Add to /etc/hosts:"
  echo "    ${INGRESS_IP:-<pending>}  ${DOMAIN}"
  echo "  Then open: http://${DOMAIN}  (HTTP only on kind — no real TLS)"
else
  echo "  Cluster Type  : kubeadm (on-prem / cloud)"
  echo "  Server IP     : ${SERVER_IP}"
  echo "  Ingress IP    : ${INGRESS_IP:-pending}"
  echo "  URL           : https://${DOMAIN}"
  echo ""
  echo "  Checklist:"
  echo "    [ ] DNS A record  : ${DOMAIN} -> ${SERVER_IP}"
  echo "    [ ] Security group: ports 80, 443, 6443 open inbound"
  echo "    [ ] MetalLB IP    : ${INGRESS_IP:-not yet assigned}"
  echo "    [ ] TLS cert      : ${CERT_STATUS:-pending}"
fi
echo ""
echo "  Live watch commands:"
echo "    kubectl get pods -n mattermost --watch"
echo "    flux get all -A"
echo "    kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller -f"
echo ""