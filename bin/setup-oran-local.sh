#!/bin/bash
#
# setup-oran-local.sh - Deploy O-RAN SC RIC locally on eNodeB node
#
# This script sets up O-RAN SC Near-RT RIC directly on the eNodeB node
# to eliminate network connectivity issues and simplify deployment.
#

set -e

# Set up logging
LOG_FILE="/var/log/setup-oran-local.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

ORAN_SETUP_DIR="/local/setup/oran"
KUBERNETES_VERSION="v1.26.15"
ORAN_VERSION="g"
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

# Create O-RAN recipe configuration
echo "Creating O-RAN recipe configuration..."
cd $ORAN_SETUP_DIR/dep/bin
cat > ../example_recipe_local.yaml << EOF
#
# Local O-RAN deployment recipe for eNodeB integration
#
ricplt:
  release_name: ricplt
  ricplt_recipe: RIC_PLATFORM_RECIPE
  ricplt_release_name: ${RICPLT_RELEASE}
  ricplt_namespace: ricplt
  
ricinfra:
  release_name: ricinfra  
  ricinfra_recipe: RIC_INFRA_RECIPE
  ricinfra_release_name: 3.0.0
  ricinfra_namespace: ricinfra

# Basic deployment - no auxiliary services for simplicity
EOF

# Deploy O-RAN SC RIC Platform
echo "Deploying O-RAN SC RIC Platform..."
./deploy-ric-platform -f ../example_recipe_local.yaml

# Wait for RIC platform to be ready
echo "Waiting for RIC platform pods to be ready..."
for ns in ricinfra ricplt; do
    echo "Waiting for pods in namespace $ns..."
    kubectl wait --for=condition=Ready pods --all -n $ns --timeout=600s
done

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
echo "Setup log available at: $LOG_FILE"