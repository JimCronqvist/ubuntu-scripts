#!/bin/bash

# Check for IP argument
if [ -z "$1" ]; then
    echo "Usage: $0 <ip-or-part>"
    exit 1
fi

SEARCH_TERM="$1"

echo "=== Searching for IPs matching: '$SEARCH_TERM' ==="

########## Kubernetes Resources ##########
echo ""
echo "== [Kubernetes] Pods =="
kubectl get pods -A -o wide 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Kubernetes] Services =="
kubectl get svc -A -o wide 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Kubernetes] Endpoints =="
kubectl get endpoints -A -o wide 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Kubernetes] Nodes =="
kubectl get nodes -o wide 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Kubernetes] Ingresses =="
kubectl get ingress -A -o wide 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Kubernetes] Events =="
kubectl get events -A 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Kubernetes] NetworkPolicies =="
kubectl get networkpolicy -A -o yaml 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

########## Cilium Components ##########
echo ""
echo "== [Cilium] CiliumEndpoints =="
kubectl get ciliumeendpoints -A -o wide 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Cilium] CiliumNetworkPolicies =="
kubectl get cnp -A -o yaml 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Cilium] Node Annotations =="
kubectl get nodes -o yaml 2>/dev/null | grep --color=always -i "cilium" | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Cilium] Recent Logs =="
kubectl -n kube-system logs -l k8s-app=cilium --tail=100 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

########## Traefik Specifics ##########
echo ""
echo "== [k3s] Traefik Services =="
kubectl -n kube-system get svc 2>/dev/null | grep --color=always -i "traefik" | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [k3s] Traefik IngressRoutes =="
kubectl -n kube-system get ingressroutes.traefik.containo.us -o yaml 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

########## k3s Specifics ##########
echo ""
echo "== [k3s] Flannel ConfigMap =="
kubectl get configmap -n kube-system -o yaml 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [k3s] Flannel Node Annotations =="
kubectl get nodes -o yaml 2>/dev/null | grep --color=always -i "flannel" | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [k3s] KlipperLB Logs =="
kubectl -n kube-system logs -l app=klipper-lb --tail=100 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [k3s Node] Server Logs =="
sudo journalctl -u k3s 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [k3s Node] Configuration Files =="
sudo grep --color=always -r "$SEARCH_TERM" /etc/rancher/k3s/ 2>/dev/null

########## EKS Specifics ##########
echo ""
echo "== [EKS] aws-node DaemonSet Logs =="
kubectl -n kube-system logs -l k8s-app=aws-node --tail=100 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [EKS Node] kubelet Logs =="
sudo journalctl -u kubelet 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

########## AWS Specifics ##########
echo ""
echo "== [AWS] Elastic Network Interfaces (ENIs) =="
aws ec2 describe-network-interfaces --query 'NetworkInterfaces[*].{ID:NetworkInterfaceId,PrivateIP:PrivateIpAddress,Description:Description}' --output text 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [AWS] Load Balancers =="
aws elb describe-load-balancers 2>/dev/null | grep --color=always -i "$SEARCH_TERM"
aws elbv2 describe-load-balancers 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [AWS] Security Groups =="
aws ec2 describe-security-groups 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [AWS] NAT Gateways =="
aws ec2 describe-nat-gateways 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

########## Node-level checks ##########
echo ""
echo "== [Node] IP Addresses =="
ip addr show | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Node] Logs (/var/log) =="
sudo grep --color=always -ri "$SEARCH_TERM" /var/log/ 2>/dev/null | grep -v "COMMAND=/usr/bin/grep"

echo ""
echo "== [Node] iptables Rules =="
sudo iptables-save 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

echo ""
echo "== [Node] ipset Rules =="
sudo ipset list 2>/dev/null | grep --color=always -i "$SEARCH_TERM"

########## AWS Flow Logs Specifics ##########

echo ""
echo "== [EKS] VPC Flow Logs (Last 5 Minutes) =="

# Customize this with your VPC flow logs log group name
LOG_GROUP_NAME="/aws/vpc/flow-log-group"

START_TIME=$(($(date +%s) - 300))  # 5 minutes ago
END_TIME=$(date +%s)

echo aws logs filter-log-events \
  --log-group-name "$LOG_GROUP_NAME" \
  --start-time $((START_TIME * 1000)) \
  --end-time $((END_TIME * 1000)) \
  --filter-pattern "$SEARCH_TERM" 2>/dev/null | grep --color=always -i "$SEARCH_TERM"


echo ""
echo "Search complete."
