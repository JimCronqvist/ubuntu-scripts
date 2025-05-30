#!/bin/bash

#
# Install K3s with optional automatic updates
#

# Abort if not root.
if [ "$(id -u)" -ne "0" ]; then
    echo "This script needs to be run from a user with root permissions.";
    exit 1;
fi

INTERACTIVE=1
# Confirm function that will be used later for yes and no questions.
Confirm () {
    while true; do
        if [ "${2:-}" = "Y" ]; then
            prompt="Y/n"
            default=Y
        elif [ "${2:-}" = "N" ]; then
            prompt="y/N"
            default=N
        else
            prompt="y/n"
            default=N
        fi
            
        if [ $INTERACTIVE == 1 ]; then
            read -p "${1:-Are you sure?} [$prompt]: " reply
            #Default?
            if [ -z "$reply" ]; then
                reply=$default
            fi
	    fi
            
        case ${reply:-$2} in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
        esac
    done
}


# Create a configuration file for k3s
sudo mkdir -p /etc/rancher/k3s
cat << EOF | envsubst | sudo tee /etc/rancher/k3s/config.yaml
# Warning: Setting the kubeconfig mode to 644 should be used with care, it is recommended to leave it as 600, that way no non-root users can access the cluster.
write-kubeconfig-mode: "0644"
kubelet-arg:
- "max-pods=250"
# Disable via .skip files for new installations
disable:
- metrics-server
#- coredns
#- traefik

# Use Cilium as a custom CNI, disable the built-in ones
#disable-kube-proxy: true
disable-network-policy: true
flannel-backend: "none"
EOF

# Create .skip files to prevent the installation of a few k3s addons
sudo mkdir -p /var/lib/rancher/k3s/server/manifests
sudo touch /var/lib/rancher/k3s/server/manifests/traefik.yaml.skip
sudo touch /var/lib/rancher/k3s/server/manifests/traefik-config.yaml.skip
sudo touch /var/lib/rancher/k3s/server/manifests/coredns.yaml.skip

# Install k3s
curl -sfL https://get.k3s.io | sh -

# Display the kube config for remote usage
echo "" && echo "To connect remotely with kubectl, use this as your kube config (~/.kube/config): " && echo "" && sudo cat /etc/rancher/k3s/k3s.yaml | sed "s/127.0.0.1/$(hostname -I | cut -f1 -d' ')/g" | sed "s/default/$(hostname)/g" && echo ""

sleep 40

# Check for Ready node, takes ~30 seconds before this command returns the 'correct' result.
kubectl get node

# Install helm if not previously installed
if ! command -v helm &> /dev/null; then
    echo "helm not found, installing..."
    curl https://baltocdn.com/helm/signing.asc | sudo apt-key add -
    sudo apt install apt-transport-https --yes
    echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
    sudo apt update
    sudo apt install helm -y
    helm version
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /home/ubuntu/.bashrc

# Deploy coredns via helm
helm upgrade --install coredns oci://ghcr.io/jimcronqvist/helm-charts/coredns -n kube-system \
  --set coredns.service.clusterIP="10.43.0.10" \
  --set coredns.replicaCount=1

# Install Cilium CLI if not previously installed
if ! command -v cilium &> /dev/null; then
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=$(uname -m | grep -q aarch64 && echo arm64 || echo amd64)
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
    sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
    rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    cilium version --client
fi

# Deploy cilium via helm
helm upgrade --install cilium oci://ghcr.io/jimcronqvist/helm-charts/cilium -n kube-system \
  --set cilium.ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16" \
  --set cilium.operator.replicas=1 
#  --set cilium.kubeProxyReplacement=true \
#  --set cilium.k8sServiceHost=10.43.0.1 \
#  --set cilium.k8sServicePort=443


if Confirm "Do you want to configure automatic updates for K3s? (Not recommended for production environments)" N; then
    # Set up automated upgrades for K3s - install system-upgrade-controller
    kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml
    kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/crd.yaml

    # Configure server and agent plans for automated updates
    kubectl apply -f - <<EOF
# Server plan
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: server-plan
  namespace: system-upgrade
spec:
  concurrency: 1
  cordon: true
  nodeSelector:
    matchExpressions:
    - key: node-role.kubernetes.io/control-plane
      operator: In
      values:
      - "true"
  serviceAccountName: system-upgrade
  upgrade:
    image: rancher/k3s-upgrade
  channel: https://update.k3s.io/v1-release/channels/stable
---
# Agent plan
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: agent-plan
  namespace: system-upgrade
spec:
  concurrency: 1
  cordon: true
  nodeSelector:
    matchExpressions:
    - key: node-role.kubernetes.io/control-plane
      operator: DoesNotExist
  prepare:
    args:
    - prepare
    - server-plan
    image: rancher/k3s-upgrade
  serviceAccountName: system-upgrade
  upgrade:
    image: rancher/k3s-upgrade
  channel: https://update.k3s.io/v1-release/channels/stable
EOF
fi

echo "Completed. Please consider doing a reboot."
