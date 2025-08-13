#!/bin/bash
set -eo pipefail

# Parameters
CLUSTER_NAME=$1
AWS_REGION=$2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

install_tools() {
  echo "Installing tools..."
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip awscliv2.zip
  sudo ./aws/install --update
  
  curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
  sudo mv /tmp/eksctl /usr/local/bin
  
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

configure_iam() {
  echo "Configuring IAM..."
  eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve
  
  curl -sLO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
  
  aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json || \
    echo "Policy already exists (continuing...)"

  eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --approve
}
{
- name: Install cert-manager
      run: |
        echo "Installing cert-manager..."
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.yaml --validate=false
        
        echo "Waiting for cert-manager to be ready..."
        kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager
        kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager-webhook
        kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager-cainjector
}

install_alb_controller() {
  echo "Installing ALB Controller..."
  helm repo add eks https://aws.github.io/eks-charts
  helm repo update
  
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=$CLUSTER_NAME \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region=$AWS_REGION
  
  kubectl wait --for=condition=Available \
    --timeout=300s \
    -n kube-system deployment/aws-load-balancer-controller
}

# Main execution
main() {
  install_tools
  configure_iam
  install_cert_manager
  install_alb_controller
}

main "$@"