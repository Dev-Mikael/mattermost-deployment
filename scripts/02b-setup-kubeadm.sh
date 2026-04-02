#!/usr/bin/env bash
# scripts/02b-setup-kubeadm.sh
# Sets up a production Kubernetes cluster on Ubuntu 22.04/24.04 using kubeadm.
# Run DIRECTLY ON THE SERVER as root: sudo bash scripts/02b-setup-kubeadm.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "02b — kubeadm Cluster Setup (On-Prem Server)"

if [[ $EUID -ne 0 ]]; then
  log_error "Run as root: sudo bash $0"
  exit 1
fi

# 1. Disable swap
log_step "Disabling swap"
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab
log_ok "Swap disabled"

# 2. Kernel modules
log_step "Loading kernel modules"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
log_ok "Kernel modules and sysctl applied"

# 3. Install containerd
log_step "Installing containerd"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq containerd.io
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd
log_ok "containerd installed"

# 4. Install kubeadm/kubelet/kubectl
log_step "Installing Kubernetes 1.30 components"
K8S_VERSION="1.30"
apt-get install -y -qq apt-transport-https
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
log_ok "kubeadm/kubelet/kubectl installed"

# 5. kubeadm init
log_step "Initialising Kubernetes cluster"
kubeadm init \
  --apiserver-advertise-address="${SERVER_IP}" \
  --pod-network-cidr="10.244.0.0/16" \
  --kubernetes-version="v${K8S_VERSION}.0" \
  | tee /tmp/kubeadm-init.log
log_ok "kubeadm init complete"

# 6. Configure kubectl
mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# 7. Remove control-plane taint (single-node)
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
log_ok "Control-plane taint removed"

# 8. Install Flannel CNI
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
log_ok "Flannel CNI applied"

# 9. Wait for node Ready
kubectl wait node --all --for condition=Ready --timeout=180s
log_ok "Node is Ready"

# 10. Set MetalLB range (single server IP)
METALLB_IP_RANGE="${SERVER_IP}/32"
if grep -q "^METALLB_IP_RANGE=" "$ROOT_DIR/.env" 2>/dev/null; then
  sed -i.bak "s|^METALLB_IP_RANGE=.*|METALLB_IP_RANGE=${METALLB_IP_RANGE}|" "$ROOT_DIR/.env"
  rm -f "$ROOT_DIR/.env.bak"
else
  echo "METALLB_IP_RANGE=${METALLB_IP_RANGE}" >> "$ROOT_DIR/.env"
fi

# 11. Copy kubeconfig for non-root user
if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  mkdir -p "$USER_HOME/.kube"
  cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
  chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube"
  log_ok "kubeconfig copied for user $SUDO_USER"
fi

log_section "kubeadm cluster ready"
echo "  MetalLB range: $METALLB_IP_RANGE"
echo "  Next: copy kubeconfig to your laptop then run scripts/03-bootstrap-flux.sh"
echo "  Copy command: scp user@${SERVER_IP}:~/.kube/config ~/.kube/config"
