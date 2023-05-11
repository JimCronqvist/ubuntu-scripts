#!/bin/bash

#
# Install K3s and set up a sane base setup
#


# Environment variables ----------------------------- #

DOMAIN=
# DNS Made Easy variables for letsencrypt dns challenge
DNSMADEEASY_API_KEY=
DNSMADEEASY_API_SECRET=


# --------------------------------------------------- #


# Abort if not root.
if [ "$(id -u)" -ne "0" ] ; then
    echo "This script needs to be ran from a user with root permissions.";
    exit 1;
fi


# Install k3s - this makes the kubeconfig readable by for example the ubuntu user, use with care as it gives non-root users access to the cluster
curl -sfL https://get.k3s.io | sh - --write-kubeconfig-mode 644


# Activate the traefik dashboard internally on the private network (i.e. not use an exposed port like 80 or 443, we use port 9000) - available after next restart
# https://github.com/traefik/traefik-helm-chart/blob/v23.0.1/traefik/values.yaml
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

sleep 30

# Check for Ready node, takes ~30 seconds before this command returns the 'correct' result.
kubectl get node

# Create the letsencrypt dnsmadeeasy secret
kubectl -n kube-system create secret generic dnsmadeeasy --from-literal=apiKey=${DNSMADEEASY_API_KEY} --from-literal=apiSecret=${DNSMADEEASY_API_SECRET}

# Install argoCD - install with a helm chart instead?
kubectl create namespace argocd
kubectl -n argocd apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d | sed -r 's/^(.*)$/Login: admin\/\1/g'

# For Traefik as the ingress controller, the ArgoCD API server must run with TLS disabled.
echo -e "$(kubectl -n argocd get configmap argocd-cmd-params-cm -o yaml)\ndata:\n  server.insecure: \"true\"" | kubectl -n argocd apply -f -
            
kubectl apply -f - <<EOF
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: HostRegexp(\`argocd.{domain:[a-z0-9.]+}\`)
      priority: 10
      services:
        - name: argocd-server
          port: 80
EOF

# Set up automated upgrades for K3s - install system-upgrade-controller & configure plans
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml

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

