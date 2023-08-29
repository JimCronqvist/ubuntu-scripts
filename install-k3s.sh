#!/bin/bash

#
# Install K3s and set up a sane base setup
#


# Environment variables ----------------------------- #

DOMAIN=${DOMAIN:-}
# DNS Made Easy variables for letsencrypt dns challenge
DNSMADEEASY_API_KEY=${DNSMADEEASY_API_KEY:-}
DNSMADEEASY_API_SECRET=${DNSMADEEASY_API_SECRET:-}

# --------------------------------------------------- #

# Check that all mandatory variables exist
if [ -z "$DOMAIN" ] || [ -z "$DNSMADEEASY_API_KEY" ] || [ -z "$DNSMADEEASY_API_SECRET" ]; then
    echo "Variables not configured"
    exit 1
fi

# Abort if not root.
if [ "$(id -u)" -ne "0" ]; then
    echo "This script needs to be run from a user with root permissions.";
    exit 1;
fi

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
EOF

# Install k3s
curl -sfL https://get.k3s.io | sh -


# Activate the traefik dashboard internally on the private network (i.e. not use an exposed port like 80 or 443, we use port 9000) - available after the next restart
# https://github.com/traefik/traefik-helm-chart/blob/v23.0.1/traefik/values.yaml
sudo mkdir -p /var/lib/rancher/k3s/server/manifests/
cat << EOF | envsubst | sudo tee /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    # Enable dashboard
    ports:
      websecure:
        tls:
          certResolver: letsencrypt-dnsmadeeasy
          domains:
            - main: ${DOMAIN}
              sans:
                - "*.${DOMAIN}"
      traefik:
        expose: true
    dashboard:
      enabled: true
    
    # Enable access logs
    logs:
      general:
        # Format is required due to a bug in the helm chart for the specific version K3s is using at the time being.
        format: common
        # Set the debug level to debug temporarily to troubleshoot
        #level: DEBUG
      access:
        enabled: true
    
    # Letsencrypt with DNSMadeEasy
    deployment:
      initContainers:
        - name: volume-permissions
          image: busybox:latest
          command: ["sh", "-c", "chmod -Rv 600 /data/* || true"]
          volumeMounts:
          - name: data
            mountPath: /data
    certResolvers:
      letsencrypt-dnsmadeeasy:
        dnsChallenge:
          provider: dnsmadeeasy
          delaybeforecheck: 60
        storage: /data/letsencrypt-dnsmadeeasy.json
    env:
      - name: DNSMADEEASY_API_KEY
        valueFrom:
          secretKeyRef:
            name: dnsmadeeasy
            key: apiKey
      - name: DNSMADEEASY_API_SECRET
        valueFrom:
          secretKeyRef:
            name: dnsmadeeasy
            key: apiSecret
EOF

# Display the kube config for remote usage
echo "" && echo "To connect remotely with kubectl, use this as your kube config (~/.kube/config): " && echo "" && sudo cat /etc/rancher/k3s/k3s.yaml | sed "s/127.0.0.1/$(hostname -I | cut -f1 -d' ')/g" && echo ""

sleep 40

# Check for Ready node, takes ~30 seconds before this command returns the 'correct' result.
kubectl get node

# Create the letsencrypt dnsmadeeasy secret
kubectl -n kube-system create secret generic dnsmadeeasy --from-literal=apiKey=${DNSMADEEASY_API_KEY} --from-literal=apiSecret=${DNSMADEEASY_API_SECRET}


# Set up automated upgrades for K3s - install system-upgrade-controller
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml

if Confirm "Do you want to configure automatic updates for K3s? (Not recommended for production environments)" N; then
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
