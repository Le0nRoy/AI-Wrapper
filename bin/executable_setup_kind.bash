#!/bin/bash
# Install kind (Kubernetes IN Docker) and kubectl for AI agents
# This script installs kind and kubectl to ~/bin/ for use in sandboxed environments

set -euo pipefail

INSTALL_DIR="${HOME}/bin"
KIND_VERSION="v0.25.0"
KUBECTL_VERSION="v1.31.0"

echo "[INFO] Setting up kind and kubectl..."

# Create install directory if it doesn't exist
mkdir -p "${INSTALL_DIR}"

# Check if kind is already installed
if [[ -f "${INSTALL_DIR}/kind" ]]; then
    CURRENT_KIND_VERSION="$("${INSTALL_DIR}/kind" version 2>/dev/null | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown')"
    if [[ "${CURRENT_KIND_VERSION}" == "${KIND_VERSION}" ]]; then
        echo "[INFO] kind ${KIND_VERSION} already installed"
    else
        echo "[INFO] Upgrading kind from ${CURRENT_KIND_VERSION} to ${KIND_VERSION}"
        rm -f "${INSTALL_DIR}/kind"
    fi
fi

# Install kind if not present
if [[ ! -f "${INSTALL_DIR}/kind" ]]; then
    echo "[INFO] Downloading kind ${KIND_VERSION}..."
    curl -Lo "${INSTALL_DIR}/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x "${INSTALL_DIR}/kind"
    echo "[INFO] kind ${KIND_VERSION} installed to ${INSTALL_DIR}/kind"
fi

# Check if kubectl is already installed
if [[ -f "${INSTALL_DIR}/kubectl" ]]; then
    CURRENT_KUBECTL_VERSION="$("${INSTALL_DIR}/kubectl" version --client --short 2>/dev/null | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown')"
    if [[ "${CURRENT_KUBECTL_VERSION}" == "${KUBECTL_VERSION}" ]]; then
        echo "[INFO] kubectl ${KUBECTL_VERSION} already installed"
    else
        echo "[INFO] Upgrading kubectl from ${CURRENT_KUBECTL_VERSION} to ${KUBECTL_VERSION}"
        rm -f "${INSTALL_DIR}/kubectl"
    fi
fi

# Install kubectl if not present
if [[ ! -f "${INSTALL_DIR}/kubectl" ]]; then
    echo "[INFO] Downloading kubectl ${KUBECTL_VERSION}..."
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl "${INSTALL_DIR}/kubectl"
    echo "[INFO] kubectl ${KUBECTL_VERSION} installed to ${INSTALL_DIR}/kubectl"
fi

# Create kind config directory
mkdir -p "${HOME}/.kind"

# Create default kind config
cat > "${HOME}/.kind/config.yaml" <<'EOF'
# Default kind cluster configuration
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
EOF

echo "[INFO] Created default kind config at ${HOME}/.kind/config.yaml"

# Verify installations
echo ""
echo "[INFO] Verifying installations..."
"${INSTALL_DIR}/kind" version
"${INSTALL_DIR}/kubectl" version --client

echo ""
echo "[SUCCESS] Setup complete!"
echo ""
echo "Usage:"
echo "  Create cluster:  kind create cluster --name my-cluster"
echo "  List clusters:   kind get clusters"
echo "  Delete cluster:  kind delete cluster --name my-cluster"
echo "  Use kubectl:     kubectl get nodes"
echo ""
echo "Note: Make sure ${INSTALL_DIR} is in your PATH"
echo "      export PATH=\"${INSTALL_DIR}:\${PATH}\""
