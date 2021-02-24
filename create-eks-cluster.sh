#!/usr/bin/env bash

#
# Ensure all dependencies are installed
#

# Install jq if not previously installed
if ! command -v jq &> /dev/null; then
    echo "jq not found, installing..."
    sudo apt update
    sudo apt install jq -y
fi

# Install eksctl if not previously installed
if ! command -v eksctl &> /dev/null; then
    echo "eksctl not found, installing..."
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
    eksctl version
fi

# Install aws if not previously installed
if ! command -v aws &> /dev/null; then
    echo "aws not found, installing..."
    sudo apt update
    sudo apt install awscli -y
    aws --version
    echo "Run 'aws configure' before you proceed"
    exit 1
fi

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


#
# Read in some input variables from the user
#

CLUSTER_VERSION="1.19"
read -i "EKS-Cluster" -p "Please enter the name of the Kubernetes Cluster: " CLUSTER_NAME
read -i "${CLUSTER_VERSION}" -p "Please enter the Kubernetes Cluster version you want to use: " CLUSTER_VERSION


#
# Create an EKS Cluster, with Fargate
#

eksctl create cluster --name "${CLUSTER_NAME}" --version "${CLUSTER_VERSION}" --region eu-north-1 --with-oidc --without-nodegroup --fargate

# Enable all cloudwatch logging
eksctl utils update-cluster-logging --enable-types all --approve --cluster "${CLUSTER_NAME}"

# Confirm that Kubernetes is working - type: ClusterIP
kubectl get svc


#
# Install AWS ALB Controller
#

AWS_ACCOUNT_ID=$(aws sts get-caller-identity | jq -r '.Account')
#VPC_ID=$(aws cloudformation describe-stacks --stack-name "eksctl-$CLUSTER_NAME-cluster" | jq -r '[.Stacks[0].Outputs[] | {key: .OutputKey, value: .OutputValue}] | from_entries' | jq -r '.VPC')

wget -O alb-ingress-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://alb-ingress-iam-policy.json

eksctl create iamserviceaccount \
  --cluster=${CLUSTER_NAME} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

helm repo add eks https://aws.github.io/eks-charts
helm repo update
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"
helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName=${CLUSTER_NAME} --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller

kubectl get deployment -n kube-system aws-load-balancer-controller


#
# Install Traefik 2 as a Kubernetes Ingress Controller, using Custom Resources 'IngressRoute'
#

helm repo add traefik https://helm.traefik.io/traefik
helm repo update

# See: https://guv.cloud/post/traefik-aws-nlb/ for traefik-values tpl
tee -a ./traefik-values << EOF
replicas: 1

rbac:
  enabled: true

accessLogs:
  enabled: false

dashboard:
  enabled: true
  domain: traefik.localhost
  auth:
    basic:
      # admin: password
      admin: '$apr1$xd1kpMTs$qFcsWe0VjLuTSJB3MihOV0'

service:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb-ip
    #service.beta.kubernetes.io/aws-load-balancer-ssl-cert: arn:aws:acm:eu-west-1:123456789012:certificate/abcdef12-3456-7890-abcd-ef1234567890
    #service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"

externalTrafficPolicy: Local

#ssl:
#  enabled: true
#  enforced: true
#  upstream: true
EOF

# https://docs.traefik.io/providers/kubernetes-crd/
helm install traefik --namespace kube-system traefik/traefik --values traefik-values.yaml
