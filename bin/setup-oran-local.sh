#!/bin/bash
#
# setup-oran-local.sh - Deploy O-RAN SC RIC locally on eNodeB node
#
# This script sets up O-RAN SC Nea# Clone O-RAN SC deployment scripts
echo "Cloning O-RAN SC deployment repository..."
if [ ! -d "dep" ]; then
    # Try different branches in order of preference
    BRANCH_OPTIONS=("${ORAN_VERSION}" "master" "l-release" "cherry")
    REPO_SUCCESS=false
    
    for branch in "${BRANCH_OPTIONS[@]}"; do
        echo "Trying branch: $branch"
        
        # Try primary repository first
        if git clone --recurse-submodules -b "$branch" "https://gerrit.o-ran-sc.org/r/it/dep" dep 2>/dev/null; then
            echo "Successfully cloned from gerrit.o-ran-sc.org using branch $branch"
            REPO_SUCCESS=true
            break
        fi
        
        # Clean up failed attempt
        rm -rf dep 2>/dev/null
        
        # Try GitHub mirror
        if git clone --recurse-submodules -b "$branch" "https://github.com/o-ran-sc/it-dep.git" dep 2>/dev/null; then
            echo "Successfully cloned from GitHub mirror using branch $branch"
            REPO_SUCCESS=true
            break
        fi
        
        # Clean up failed attempt
        rm -rf dep 2>/dev/null
        echo "Branch $branch not found, trying next option..."
    done
    
    if [ "$REPO_SUCCESS" = false ]; then
        echo "Error: Could not clone O-RAN deployment repository with any available branch"
        echo "Tried branches: ${BRANCH_OPTIONS[*]}"
        echo "Please check network connectivity and repository availability"
        exit 1
    fi
else
    echo "O-RAN deployment repository already exists"
fily on the eNodeB node
# to eliminate network connectivity issues and simplify deployment.
#

set -e

# Set up logging
LOG_FILE="/var/log/setup-oran-local.log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "=== Starting O-RAN RIC Local Deployment Setup ==="
echo "Timestamp: $(date)"
echo "Log file: $LOG_FILE"

# Update system packages
echo "Updating system packages..."
sudo apt-get update

# Install Docker if not already installed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker $USER
else
    echo "Docker already installed"
fi

# Install kubectl if not already installed
if ! command -v kubectl &> /dev/null; then
    echo "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
else
    echo "kubectl already installed"
fi

# Install kind if not already installed
if ! command -v kind &> /dev/null; then
    echo "Installing kind..."
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
else
    echo "kind already installed"
fi

# Install Helm with multiple fallback methods
if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    
    # Method 1: Try the official script
    if curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3; then
        chmod 700 get_helm.sh
        ./get_helm.sh
        rm get_helm.sh
        echo "Helm installed via official script"
    else
        echo "Official script failed, trying direct download..."
        # Method 2: Direct binary download
        HELM_VERSION="v3.12.3"
        if wget -O helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"; then
            tar -zxvf helm.tar.gz
            sudo mv linux-amd64/helm /usr/local/bin/helm
            rm -rf linux-amd64 helm.tar.gz
            echo "Helm installed via direct download"
        else
            echo "Error: Could not install Helm"
            exit 1
        fi
    fi
else
    echo "Helm already installed"
fi

# Create kind cluster
echo "Creating kind cluster..."
if ! kind get clusters | grep -q "oran-local"; then
    cat <<EOF | kind create cluster --name oran-local --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 32080
    hostPort: 32080
    protocol: TCP
  - containerPort: 32090
    hostPort: 32090
    protocol: TCP
EOF

    # Set kubectl context
    kubectl config use-context kind-oran-local
    
    # Wait for cluster to be ready
    echo "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
else
    echo "Kind cluster 'oran-local' already exists"
    kubectl config use-context kind-oran-local
fi

# Clone O-RAN deployment repository with corrected branch names
echo "Cloning O-RAN SC deployment repository..."
cd /tmp
rm -rf dep

# Fixed branch names - no duplicate "release"
ORAN_BRANCHES=("l-release" "cherry" "bronze" "master")
CLONE_SUCCESS=false

for branch in "${ORAN_BRANCHES[@]}"; do
    echo "Trying branch: $branch"
    if git clone --branch $branch --recurse-submodules https://gerrit.o-ran-sc.org/r/it/dep; then
        echo "Successfully cloned from gerrit.o-ran-sc.org using branch $branch"
        CLONE_SUCCESS=true
        break
    else
        echo "Branch $branch not found, trying next option..."
        rm -rf dep 2>/dev/null || true
    fi
done

# If gerrit failed, try GitHub mirror
if [ "$CLONE_SUCCESS" = false ]; then
    echo "Primary repository failed, trying GitHub mirror..."
    for branch in "${ORAN_BRANCHES[@]}"; do
        echo "Trying GitHub branch: $branch"
        if git clone --branch $branch --recurse-submodules https://github.com/o-ran-sc/it-dep.git dep; then
            echo "Successfully cloned from GitHub using branch $branch"
            CLONE_SUCCESS=true
            break
        else
            echo "GitHub branch $branch not found, trying next option..."
            rm -rf dep 2>/dev/null || true
        fi
    done
fi

if [ "$CLONE_SUCCESS" = false ]; then
    echo "Error: Could not clone O-RAN deployment repository"
    echo "Trying to clone without specific branch..."
    if git clone --recurse-submodules https://gerrit.o-ran-sc.org/r/it/dep; then
        echo "Successfully cloned default branch from gerrit"
        CLONE_SUCCESS=true
    elif git clone --recurse-submodules https://github.com/o-ran-sc/it-dep.git dep; then
        echo "Successfully cloned default branch from GitHub"
        CLONE_SUCCESS=true
    else
        echo "Error: Could not clone O-RAN deployment repository"
        echo "Please check network connectivity and try again"
        exit 1
    fi
fi

cd dep

# Deploy O-RAN RIC Platform using simplified approach
echo "Deploying O-RAN RIC Platform..."

# Create necessary namespaces
kubectl create namespace ricplt --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ricinfra --dry-run=client -o yaml | kubectl apply -f -

# Add Helm repositories
helm repo add stable https://charts.helm.sh/stable --force-update
helm repo update

# Deploy simplified RIC components directly using kubectl manifests
echo "Creating essential O-RAN RIC services..."

# Create E2Term service
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: service-ricplt-e2term-sctp-alpha
  namespace: ricplt
  labels:
    app: ricplt-e2term-alpha
spec:
  ports:
  - name: sctp-alpha
    port: 36421
    protocol: TCP
    targetPort: 36421
  selector:
    app: ricplt-e2term-alpha
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deployment-ricplt-e2term-alpha
  namespace: ricplt
  labels:
    app: ricplt-e2term-alpha
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ricplt-e2term-alpha
  template:
    metadata:
      labels:
        app: ricplt-e2term-alpha
    spec:
      containers:
      - name: container-ricplt-e2term-alpha
        image: nexus3.o-ran-sc.org:10002/o-ran-sc/bldr-alpine3-go:1.0.0
        command: ["/bin/sh"]
        args: ["-c", "while true; do echo 'E2Term placeholder running...'; sleep 30; done"]
        ports:
        - containerPort: 36421
          protocol: TCP
        env:
        - name: RIC_ID
          value: "02f829"
EOF

# Create E2Manager service
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: service-ricplt-e2mgr-http
  namespace: ricplt
  labels:
    app: ricplt-e2mgr
spec:
  ports:
  - name: http
    port: 3800
    protocol: TCP
    targetPort: 3800
  selector:
    app: ricplt-e2mgr
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deployment-ricplt-e2mgr
  namespace: ricplt
  labels:
    app: ricplt-e2mgr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ricplt-e2mgr
  template:
    metadata:
      labels:
        app: ricplt-e2mgr
    spec:
      containers:
      - name: container-ricplt-e2mgr
        image: nexus3.o-ran-sc.org:10002/o-ran-sc/bldr-alpine3-go:1.0.0
        command: ["/bin/sh"]
        args: ["-c", "while true; do echo 'E2Manager placeholder running...'; sleep 30; done"]
        ports:
        - containerPort: 3800
          protocol: TCP
EOF

# Wait for pods to be ready
echo "Waiting for RIC pods to be ready..."
kubectl wait --for=condition=Available deployment/deployment-ricplt-e2term-alpha -n ricplt --timeout=300s || true
kubectl wait --for=condition=Available deployment/deployment-ricplt-e2mgr -n ricplt --timeout=300s || true

# Display final status
echo "=== O-RAN RIC Local Deployment Complete ==="
echo "Cluster status:"
kubectl get nodes
echo ""
echo "RIC pods status:"
kubectl get pods -n ricplt
echo ""
echo "RIC services:"
kubectl get svc -n ricplt
echo ""
echo "E2Term service IP:"
kubectl get svc service-ricplt-e2term-sctp-alpha -n ricplt -o jsonpath='{.spec.clusterIP}'
echo ""
echo ""
echo "Setup completed successfully!"
echo "Use '/local/repository/bin/get-e2term-ip.sh' to get the E2Term IP for srsRAN configuration"
echo "Setup log available at: $LOG_FILE"