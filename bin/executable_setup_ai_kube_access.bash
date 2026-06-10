#!/bin/bash
# Setup restricted Kubernetes access for AI agents
# Creates a ServiceAccount with read-only pod/log permissions and generates a dedicated kubeconfig
#
# Usage:
#   setup_ai_kube_access.bash                             # Interactive mode
#   setup_ai_kube_access.bash <context-name>              # Full setup
#   setup_ai_kube_access.bash <context-name> --refresh    # Refresh token only
#   setup_ai_kube_access.bash --list                      # List available contexts
#   setup_ai_kube_access.bash --check                     # Check if configured
#   setup_ai_kube_access.bash --test                      # Test existing config

set -euo pipefail

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly AI_KUBECONFIG="${HOME}/.kube/ai-agent-config"
readonly SERVICE_ACCOUNT_NAME="ai-agent-readonly"
readonly CLUSTER_ROLE_NAME="ai-agent-pod-log-reader"
readonly TOKEN_DURATION="8760h"  # 1 year

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'  # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Show usage
show_usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [context-name] [options]

Setup restricted Kubernetes access for AI agents.
Creates a ServiceAccount with read-only pod/log permissions.

Arguments:
  <context-name>    The kubectl context to configure access for
                    If omitted, runs in interactive mode

Options:
  --refresh         Only refresh the token (skip RBAC setup)
  --list            List available kubectl contexts
  --check           Check if AI kubeconfig exists and is valid
  --test            Test the existing AI kubeconfig connection
  --namespace NS    Namespace for ServiceAccount (default: default)
  --help            Show this help message

Examples:
  ${SCRIPT_NAME}                          # Interactive mode
  ${SCRIPT_NAME} --list
  ${SCRIPT_NAME} --check
  ${SCRIPT_NAME} my-cluster
  ${SCRIPT_NAME} my-cluster --refresh
  ${SCRIPT_NAME} my-cluster --namespace kube-system

Output:
  Creates ${AI_KUBECONFIG} with restricted access
EOF
}

# List available contexts
list_contexts() {
    log_info "Available kubectl contexts:"
    echo ""
    kubectl config get-contexts --output='name' 2>/dev/null | while read -r ctx; do
        local current=""
        if [[ "$(kubectl config current-context 2>/dev/null)" == "${ctx}" ]]; then
            current=" (current)"
        fi
        echo "  - ${ctx}${current}"
    done
    echo ""
}

# Check if AI kubeconfig exists and is valid
check_config() {
    if [[ ! -f "${AI_KUBECONFIG}" ]]; then
        log_warn "AI kubeconfig not found: ${AI_KUBECONFIG}"
        return 1
    fi

    # Check if the file is valid YAML/kubeconfig
    if ! KUBECONFIG="${AI_KUBECONFIG}" kubectl config view &>/dev/null; then
        log_warn "AI kubeconfig exists but is invalid"
        return 1
    fi

    log_info "AI kubeconfig exists: ${AI_KUBECONFIG}"
    return 0
}

# Test the existing AI kubeconfig connection
test_config() {
    if ! check_config; then
        return 1
    fi

    log_info "Testing AI kubeconfig connection..."
    echo ""

    # Try to list namespaces (basic connectivity test)
    if KUBECONFIG="${AI_KUBECONFIG}" kubectl get namespaces --no-headers &>/dev/null; then
        log_info "Connection successful!"
        echo ""
        echo "Namespaces accessible:"
        KUBECONFIG="${AI_KUBECONFIG}" kubectl get namespaces --no-headers 2>/dev/null | head -5 || true
        echo "  ... (showing first 5)"
        echo ""

        echo "Pods accessible:"
        KUBECONFIG="${AI_KUBECONFIG}" kubectl get pods --all-namespaces --no-headers 2>/dev/null | head -5 || true
        echo "  ... (showing first 5)"
        return 0
    else
        log_error "Connection failed or no permissions"
        log_warn "Token may have expired. Run: ${SCRIPT_NAME} <context> --refresh"
        return 1
    fi
}

# Interactive mode - prompt user to select context
interactive_mode() {
    echo ""
    echo "=========================================="
    echo "  AI Agent Kubernetes Access Setup"
    echo "=========================================="
    echo ""

    # Check if kubectl is available
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found. Please install kubectl first."
        exit 1
    fi

    # Get available contexts
    local -a contexts=()
    mapfile -t contexts < <(kubectl config get-contexts --output='name' 2>/dev/null)

    if [[ ${#contexts[@]} -eq 0 ]]; then
        log_error "No kubectl contexts found."
        log_warn "Please configure kubectl with access to a cluster first."
        exit 1
    fi

    local current_context
    current_context="$(kubectl config current-context 2>/dev/null || echo "")"

    # Check if already configured
    if check_config 2>/dev/null; then
        echo ""
        echo "Existing AI kubeconfig found."
        echo -n "Do you want to reconfigure? [y/N]: "
        read -r reconfigure
        if [[ "${reconfigure}" != "y" && "${reconfigure}" != "Y" ]]; then
            echo ""
            echo "To test existing config: ${SCRIPT_NAME} --test"
            echo "To refresh token: ${SCRIPT_NAME} <context> --refresh"
            exit 0
        fi
        echo ""
    fi

    # Show available contexts
    echo "Available Kubernetes contexts:"
    echo ""
    local i=1
    for ctx in "${contexts[@]}"; do
        local marker=""
        if [[ "${ctx}" == "${current_context}" ]]; then
            marker=" (current)"
        fi
        printf "  %2d) %s%s\n" "${i}" "${ctx}" "${marker}"
        i=$((i + 1))
    done
    echo ""

    # Prompt for selection
    local selection
    echo -n "Select context number [1-${#contexts[@]}]: "
    read -r selection

    # Validate selection
    if ! [[ "${selection}" =~ ^[0-9]+$ ]] || [[ "${selection}" -lt 1 ]] || [[ "${selection}" -gt ${#contexts[@]} ]]; then
        log_error "Invalid selection: ${selection}"
        exit 1
    fi

    local selected_context="${contexts[$((selection - 1))]}"
    echo ""
    log_info "Selected context: ${selected_context}"
    echo ""

    # Ask for namespace
    local namespace="default"
    echo -n "Namespace for ServiceAccount [default]: "
    read -r ns_input
    if [[ -n "${ns_input}" ]]; then
        namespace="${ns_input}"
    fi
    echo ""

    # Confirm
    echo "Configuration:"
    echo "  Context:   ${selected_context}"
    echo "  Namespace: ${namespace}"
    echo "  Output:    ${AI_KUBECONFIG}"
    echo ""
    echo -n "Proceed with setup? [Y/n]: "
    read -r confirm
    if [[ "${confirm}" == "n" || "${confirm}" == "N" ]]; then
        log_warn "Setup cancelled."
        exit 0
    fi
    echo ""

    # Run the setup
    main "${selected_context}" --namespace "${namespace}"
}

# Validate context exists
validate_context() {
    local context="${1}"

    if ! kubectl config get-contexts "${context}" &>/dev/null; then
        log_error "Context '${context}' not found"
        echo ""
        list_contexts
        exit 1
    fi
}

# Get cluster name from context
get_cluster_from_context() {
    local context="${1}"
    kubectl config view -o jsonpath="{.contexts[?(@.name=='${context}')].context.cluster}"
}

# Get server URL from cluster
get_server_from_cluster() {
    local cluster="${1}"
    kubectl config view -o jsonpath="{.clusters[?(@.name=='${cluster}')].cluster.server}"
}

# Get CA data from cluster
get_ca_from_cluster() {
    local cluster="${1}"
    # Try certificate-authority-data first
    local ca_data
    ca_data=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${cluster}')].cluster.certificate-authority-data}" 2>/dev/null || true)

    if [[ -n "${ca_data}" ]]; then
        echo "${ca_data}"
        return 0
    fi

    # Try certificate-authority file
    local ca_file
    ca_file=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${cluster}')].cluster.certificate-authority}" 2>/dev/null || true)

    if [[ -n "${ca_file}" && -f "${ca_file}" ]]; then
        base64 -w0 < "${ca_file}"
        return 0
    fi

    log_error "Could not find CA certificate for cluster '${cluster}'"
    return 1
}

# Create RBAC resources
create_rbac() {
    local context="${1}"
    local namespace="${2}"

    log_info "Creating RBAC resources in context '${context}'..."

    # Create ServiceAccount
    log_info "Creating ServiceAccount '${SERVICE_ACCOUNT_NAME}' in namespace '${namespace}'..."
    kubectl --context="${context}" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: ai-agent-access
    app.kubernetes.io/component: rbac
EOF

    # Create ClusterRole for pod log reading
    log_info "Creating ClusterRole '${CLUSTER_ROLE_NAME}'..."
    kubectl --context="${context}" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTER_ROLE_NAME}
  labels:
    app.kubernetes.io/name: ai-agent-access
    app.kubernetes.io/component: rbac
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list"]
EOF

    # Create ClusterRoleBinding
    log_info "Creating ClusterRoleBinding..."
    kubectl --context="${context}" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${SERVICE_ACCOUNT_NAME}-binding
  labels:
    app.kubernetes.io/name: ai-agent-access
    app.kubernetes.io/component: rbac
subjects:
- kind: ServiceAccount
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${namespace}
roleRef:
  kind: ClusterRole
  name: ${CLUSTER_ROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF

    log_info "RBAC resources created successfully"
}

# Generate token for ServiceAccount
generate_token() {
    local context="${1}"
    local namespace="${2}"

    log_info "Generating token for ServiceAccount (duration: ${TOKEN_DURATION})..."

    local token
    token=$(kubectl --context="${context}" create token "${SERVICE_ACCOUNT_NAME}" \
        --namespace="${namespace}" \
        --duration="${TOKEN_DURATION}" 2>/dev/null)

    if [[ -z "${token}" ]]; then
        log_error "Failed to generate token"
        exit 1
    fi

    echo "${token}"
}

# Create the AI agent kubeconfig
create_kubeconfig() {
    local context="${1}"
    local token="${2}"

    local cluster_name
    cluster_name=$(get_cluster_from_context "${context}")

    local server
    server=$(get_server_from_cluster "${cluster_name}")

    local ca_data
    ca_data=$(get_ca_from_cluster "${cluster_name}")

    log_info "Creating AI agent kubeconfig at ${AI_KUBECONFIG}..."

    # Ensure directory exists
    mkdir -p "$(dirname "${AI_KUBECONFIG}")"

    # Create the kubeconfig file
    cat > "${AI_KUBECONFIG}" <<EOF
apiVersion: v1
kind: Config
preferences: {}

clusters:
- cluster:
    certificate-authority-data: ${ca_data}
    server: ${server}
  name: ai-agent-cluster

contexts:
- context:
    cluster: ai-agent-cluster
    user: ai-agent
    namespace: default
  name: ai-agent

current-context: ai-agent

users:
- name: ai-agent
  user:
    token: ${token}
EOF

    # Restrict permissions
    chmod 600 "${AI_KUBECONFIG}"

    log_info "Kubeconfig created successfully"
}

# Verify the setup works
verify_setup() {
    log_info "Verifying AI agent access..."

    echo ""
    echo "Testing pod list access:"
    if KUBECONFIG="${AI_KUBECONFIG}" kubectl get pods --all-namespaces --no-headers 2>/dev/null | head -5; then
        echo "  ... (truncated)"
    else
        log_warn "Could not list pods - this might be expected if no pods exist"
    fi

    echo ""
    echo "Testing namespace access:"
    KUBECONFIG="${AI_KUBECONFIG}" kubectl get namespaces --no-headers 2>/dev/null | head -5 || true

    echo ""
    log_info "Verification complete"
}

# Main function
main() {
    local context=""
    local namespace="default"
    local refresh_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --help|-h)
                show_usage
                exit 0
                ;;
            --list|-l)
                list_contexts
                exit 0
                ;;
            --check|-c)
                if check_config; then
                    exit 0
                else
                    exit 1
                fi
                ;;
            --test|-t)
                if test_config; then
                    exit 0
                else
                    exit 1
                fi
                ;;
            --refresh|-r)
                refresh_only=true
                shift
                ;;
            --namespace|-n)
                namespace="${2}"
                shift 2
                ;;
            -*)
                log_error "Unknown option: ${1}"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "${context}" ]]; then
                    context="${1}"
                else
                    log_error "Unexpected argument: ${1}"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # If no context provided, run interactive mode
    if [[ -z "${context}" ]]; then
        interactive_mode
        exit 0
    fi

    # Validate context exists
    validate_context "${context}"

    log_info "Setting up AI agent access for context: ${context}"
    log_info "Namespace: ${namespace}"
    echo ""

    # Create RBAC if not refresh-only
    if [[ "${refresh_only}" == "false" ]]; then
        create_rbac "${context}" "${namespace}"
        echo ""
    else
        log_info "Skipping RBAC setup (refresh mode)"
        echo ""
    fi

    # Generate token
    local token
    token=$(generate_token "${context}" "${namespace}")
    echo ""

    # Create kubeconfig
    create_kubeconfig "${context}" "${token}"
    echo ""

    # Verify setup
    verify_setup

    echo ""
    echo "=========================================="
    log_info "Setup complete!"
    echo "=========================================="
    echo ""
    echo "AI agent kubeconfig: ${AI_KUBECONFIG}"
    echo ""
    echo "To use in AI agent sandbox, set:"
    echo "  export KUBECONFIG=${AI_KUBECONFIG}"
    echo ""
    echo "Permissions granted:"
    echo "  - List pods (all namespaces)"
    echo "  - Get pod details"
    echo "  - Read pod logs"
    echo "  - List namespaces"
    echo ""
    echo "To refresh token later:"
    echo "  ${SCRIPT_NAME} ${context} --refresh"
    echo ""
}

main "$@"
