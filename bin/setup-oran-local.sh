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
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

ORAN_SETUP_DIR="/local/setup/oran"
KUBERNETES_VERSION="v1.26.15"
ORAN_VERSION="l-release"  # Updated to use existing branch
RICPLT_RELEASE="3.0.1"

echo "=========================================="
echo "Setting up O-RAN SC RIC locally on eNodeB"
echo "Start time: $(date)"
echo "=========================================="

# Basic network connectivity check
echo "Checking network connectivity..."
if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "Warning: Limited network connectivity detected. Some downloads may fail."
    echo "Continuing with available methods..."
fi

# Update system and install dependencies
echo "Installing system dependencies..."
apt-get update
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common

# Install Docker
echo "Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
    
    # Add user to docker group
    usermod -aG docker $(logname)
    
    # Start and enable docker
    systemctl start docker
    systemctl enable docker
    
    echo "Docker installed successfully"
else
    echo "Docker already installed"
fi

# Install kubectl
echo "Installing kubectl..."
if ! command -v kubectl &> /dev/null; then
    curl -LO "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
    echo "kubectl installed successfully"
else
    echo "kubectl already installed"
fi

# Install Helm
echo "Installing Helm..."
if ! command -v helm &> /dev/null; then
    # Method 1: Try direct binary download from GitHub
    echo "Downloading Helm binary directly..."
    if curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 2>/dev/null; then
        chmod 700 get_helm.sh
        ./get_helm.sh
        rm get_helm.sh
        echo "Helm installed successfully via GitHub"
    else
        # Method 2: Fallback to direct binary download
        echo "GitHub method failed, trying direct binary download..."
        HELM_VERSION="v3.12.3"
        wget -O helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" || \
        curl -L -o helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
        
        tar -zxvf helm.tar.gz
        mv linux-amd64/helm /usr/local/bin/helm
        rm -rf helm.tar.gz linux-amd64/
        chmod +x /usr/local/bin/helm
        echo "Helm installed successfully via direct download"
    fi
else
    echo "Helm already installed"
fi

# Install kind (Kubernetes in Docker) for local cluster
echo "Installing kind..."
if ! command -v kind &> /dev/null; then
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
    chmod +x ./kind
    mv ./kind /usr/local/bin/kind
    echo "kind installed successfully"
else
    echo "kind already installed"
fi

# Create O-RAN setup directory
mkdir -p $ORAN_SETUP_DIR
cd $ORAN_SETUP_DIR

# Clone O-RAN SC deployment scripts
echo "Cloning O-RAN SC deployment repository..."
if [ ! -d "dep" ]; then
    # Try primary repository first
    if ! git clone --recurse-submodules -b ${ORAN_VERSION}-release "https://gerrit.o-ran-sc.org/r/it/dep" dep; then
        echo "Primary repository failed, trying GitHub mirror..."
        git clone --recurse-submodules -b ${ORAN_VERSION}-release "https://github.com/o-ran-sc/it-dep.git" dep || {
            echo "Error: Could not clone O-RAN deployment repository"
            echo "Please check network connectivity and try again"
            exit 1
        }
    fi
else
    echo "O-RAN deployment repository already exists"
fi

# Create kind cluster configuration
echo "Creating kind cluster configuration..."
cat > kind-config.yaml << 'EOF'
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
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
  - containerPort: 36421
    hostPort: 36421
    protocol: SCTP
  - containerPort: 36422
    hostPort: 36422
    protocol: TCP
EOF

# Create kind cluster
echo "Creating kind Kubernetes cluster..."
if ! kind get clusters | grep -q "oran-local"; then
    echo "This may take several minutes as container images are downloaded..."
    if ! kind create cluster --name oran-local --config kind-config.yaml; then
        echo "Error: Failed to create kind cluster"
        echo "This might be due to network issues downloading container images"
        echo "You can try running the script again, or check Docker connectivity"
        exit 1
    fi
    echo "Kind cluster 'oran-local' created successfully"
else
    echo "Kind cluster 'oran-local' already exists"
fi

# Set kubectl context
kubectl config use-context kind-oran-local

# Wait for cluster to be ready
echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# Deploy essential O-RAN components directly using Helm
echo "Deploying essential O-RAN SC components..."

# Create namespaces
kubectl create namespace ricplt --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ricinfra --dry-run=client -o yaml | kubectl apply -f -

# Add O-RAN helm repositories
echo "Adding O-RAN Helm repositories..."
helm repo add oran https://gerrit.o-ran-sc.org/r/it/dep/raw/l-release || \
helm repo add oran https://charts.o-ran-sc.org || \
echo "Warning: Could not add O-RAN helm repo, will use direct images"

helm repo update || echo "Warning: Could not update helm repos"

# Deploy Redis (required for RIC platform)
echo "Deploying Redis for RIC platform..."
helm install redis-ricplt oci://registry-1.docker.io/bitnamicharts/redis \
    --namespace ricinfra \
    --set auth.enabled=false \
    --set replica.replicaCount=1 \
    --wait --timeout=300s

# Deploy essential RIC platform components using direct manifests
echo "Deploying RIC platform components..."

# E2Term deployment
cat <<EOF | kubectl apply -f -
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
      - name: e2term
        image: nexus3.o-ran-sc.org:10004/o-ran-sc/ric-plt-e2:6.0.1
        ports:
        - containerPort: 36421
          protocol: SCTP
        - containerPort: 36422
          protocol: TCP
        env:
        - name: RIC_ID
          value: "bbbccc-abcd0e-def123"
        - name: SCTP_PORT
          value: "36421"
        - name: HTTP_PORT  
          value: "36422"
---
apiVersion: v1
kind: Service
metadata:
  name: service-ricplt-e2term-sctp-alpha
  namespace: ricplt
spec:
  selector:
    app: ricplt-e2term-alpha
  ports:
  - port: 36421
    targetPort: 36421
    protocol: SCTP
    name: sctp
---
apiVersion: v1
kind: Service
metadata:
  name: service-ricplt-e2term-alpha
  namespace: ricplt
spec:
  selector:
    app: ricplt-e2term-alpha
  ports:
  - port: 36422
    targetPort: 36422
    protocol: TCP
    name: http
EOF

# E2Manager deployment
cat <<EOF | kubectl apply -f -
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
      - name: e2mgr
        image: nexus3.o-ran-sc.org:10004/o-ran-sc/ric-plt-e2mgr:5.4.14
        env:
        - name: RIC_ID
          value: "bbbccc-abcd0e-def123"
---
apiVersion: v1
kind: Service
metadata:
  name: service-ricplt-e2mgr-http
  namespace: ricplt
spec:
  selector:
    app: ricplt-e2mgr
  ports:
  - port: 3800
    targetPort: 3800
    protocol: TCP
EOF

# Subscription Manager
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1  
kind: Deployment
metadata:
  name: deployment-ricplt-submgr
  namespace: ricplt
  labels:
    app: ricplt-submgr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ricplt-submgr
  template:
    metadata:
      labels:
        app: ricplt-submgr
    spec:
      containers:
      - name: submgr
        image: nexus3.o-ran-sc.org:10004/o-ran-sc/ric-plt-submgr:0.15.5
EOF

# Wait for essential components to be ready
echo "Waiting for essential RIC components to be ready..."
kubectl wait --for=condition=Available deployment/deployment-ricplt-e2term-alpha -n ricplt --timeout=300s
kubectl wait --for=condition=Available deployment/deployment-ricplt-e2mgr -n ricplt --timeout=300s
kubectl wait --for=condition=Available deployment/deployment-ricplt-submgr -n ricplt --timeout=300s

# Get E2Term service information
echo "Getting E2Term service information..."
E2TERM_IP=$(kubectl get svc -n ricplt service-ricplt-e2term-sctp-alpha -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "127.0.0.1")
echo "E2Term SCTP service IP: $E2TERM_IP"

# Create convenience script for getting E2Term IP
cat > /local/repository/bin/get-e2term-ip.sh << 'EOF'
#!/bin/bash
# Get E2Term service IP for srsRAN eNodeB configuration
E2TERM_IP=$(kubectl get svc -n ricplt service-ricplt-e2term-sctp-alpha -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "$E2TERM_IP" ]; then
    echo "E2Term SCTP IP: $E2TERM_IP"
    echo "Use this IP in srsRAN eNodeB configuration:"
    echo "  --ric.agent.remote_ipv4_addr=$E2TERM_IP"
else
    echo "Error: Could not get E2Term service IP"
    echo "Check if RIC platform is running: kubectl get pods -n ricplt"
    exit 1
fi
EOF
chmod +x /local/repository/bin/get-e2term-ip.sh

# Create RIC management script
cat > /local/repository/bin/manage-oran-ric.sh << 'EOF'
#!/bin/bash
# O-RAN RIC management script

case "$1" in
    status)
        echo "=== RIC Platform Status ==="
        kubectl get pods -n ricplt
        echo ""
        echo "=== RIC Infrastructure Status ==="  
        kubectl get pods -n ricinfra
        echo ""
        echo "=== E2Term Service ==="
        kubectl get svc -n ricplt service-ricplt-e2term-sctp-alpha
        ;;
    logs)
        if [ -n "$2" ]; then
            kubectl logs -f -n ricplt -l app=ricplt-$2
        else
            echo "Usage: $0 logs <component>"
            echo "Components: e2term-alpha, e2mgr, submgr, rtmgr"
        fi
        ;;
    restart)
        echo "Restarting RIC core services..."
        kubectl -n ricplt rollout restart deployment/deployment-ricplt-e2term-alpha
        kubectl -n ricplt rollout restart deployment/deployment-ricplt-e2mgr  
        kubectl -n ricplt rollout restart deployment/deployment-ricplt-submgr
        kubectl -n ricplt rollout restart deployment/deployment-ricplt-rtmgr
        ;;
    e2term-ip)
        /local/repository/bin/get-e2term-ip.sh
        ;;
    *)
        echo "Usage: $0 {status|logs|restart|e2term-ip}"
        echo ""
        echo "Commands:"
        echo "  status    - Show RIC pod status"
        echo "  logs      - Show logs for RIC component (e.g., logs e2term-alpha)"
        echo "  restart   - Restart RIC core services"  
        echo "  e2term-ip - Get E2Term service IP for eNodeB configuration"
        exit 1
        ;;
esac
EOF
chmod +x /local/repository/bin/manage-oran-ric.sh

# Set up kubectl for all users
echo "export KUBECONFIG=/root/.kube/config" >> /root/.bashrc
echo "export KUBECONFIG=/root/.kube/config" >> /home/$(logname)/.bashrc

echo "=========================================="
echo "O-RAN SC RIC setup completed successfully!"
echo "Completion time: $(date)"
echo "=========================================="
echo ""
echo "E2Term service IP: $E2TERM_IP"
echo ""
echo "Useful commands:"
echo "  /local/repository/bin/manage-oran-ric.sh status    - Check RIC status"
echo "  /local/repository/bin/manage-oran-ric.sh e2term-ip - Get E2Term IP"
echo "  kubectl get pods -n ricplt                         - Check RIC pods"
echo ""
echo "Configure srsRAN eNodeB with:"
echo "  --ric.agent.remote_ipv4_addr=$E2TERM_IP"
echo ""

fi
echo "Setup log available at: $LOG_FILE"