#!/usr/bin/env bash
###############################################################################
#
#   DevOps Ultimate Bootstrap Installer
#   ------------------------------------
#   Production-style automated bootstrapper for a single-node Kubernetes
#   "DevOps Lab Platform" on a fresh Ubuntu EC2 instance.
#
#   Installs & configures:
#     Base tools, Docker Engine, kubeadm/kubelet/kubectl (single control-plane
#     cluster), Calico CNI, Helm, kubectx/kubens/k9s, AWS CLI, Terraform,
#     NGINX Ingress, cert-manager, Trivy Operator, ArgoCD, Jenkins,
#     kube-prometheus-stack (Prometheus + Grafana), Loki + Promtail,
#     SonarQube, plus kubectl aliases & shell autocompletion.
#
#   USAGE:
#       sudo ./devops-ultimate-bootstrap-installer.sh [OPTIONS]
#
#   OPTIONS:
#       -y, --yes               Non-interactive mode (assume "yes" to prompts)
#       --skip-heavy            Skip Jenkins + SonarQube (saves ~4-6GB RAM)
#       --pod-cidr=CIDR         Override pod network CIDR (default: 192.168.0.0/16)
#       --k8s-version=X.Y       Override Kubernetes minor version (default: 1.31)
#       -h, --help              Show usage
#
#   REQUIREMENTS / NOTES:
#     - Ubuntu 22.04 / 24.04 LTS, x86_64 or arm64
#     - Recommended instance size: >= 4 vCPU / 16GB RAM (8 vCPU / 32GB to run
#       the full stack incl. Jenkins + SonarQube comfortably).
#     - Open inbound in your Security Group: 6443 (API server), 2379-2380,
#       10250-10256, and 30000-32767 (NodePort range) at minimum.
#     - This script is IDEMPOTENT: safe to re-run after a failure once the
#       underlying issue (resources, network, etc.) is fixed.
#     - Full log of every command's real output: /var/log/devops-install.log
#
#   Author: Mostafa Mohammed Ahmed
#
###############################################################################

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# GLOBAL CONFIGURATION
###############################################################################

SCRIPT_NAME="DevOps Ultimate Bootstrap Installer"
SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/devops-install.log"

POD_CIDR="192.168.0.0/16"
K8S_MINOR_VERSION="1.31"          # pkgs.k8s.io stable line - bump as needed
CALICO_VERSION="v3.28.0"          # check https://github.com/projectcalico/calico/releases

HELM_VALUES_DIR="/opt/devops-bootstrap/helm-values"
INSTALL_USER="${SUDO_USER:-${USER:-root}}"
HOME_DIR="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/root}"

NON_INTERACTIVE=false
SKIP_HEAVY=false
START_TIME=$(date +%s)

declare -A RESULT
COMPONENT_ORDER=()

###############################################################################
# COLORS & UI PRIMITIVES
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

log_raw() {
    local level="$1"; shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*" >> "$LOG_FILE"
}
log_info()  { log_raw "INFO"  "$*"; }
log_warn()  { log_raw "WARN"  "$*"; }
log_error() { log_raw "ERROR" "$*"; }

init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    {
        echo "================================================================"
        echo " ${SCRIPT_NAME} v${SCRIPT_VERSION} - run started $(date)"
        echo " Invoked by: ${INSTALL_USER}  |  Args: $*"
        echo "================================================================"
    } >> "$LOG_FILE"
}

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "===================================================="
    echo "        DEVOPS CLOUD BOOTSTRAPPER"
    echo "===================================================="
    echo -e "${NC}${DIM}  ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo -e "  Log file: ${LOG_FILE}${NC}"
    echo
}

section() {
    local title="$1"
    echo
    echo -e "${BLUE}${BOLD}── ${title} $(printf '%*s' $(( 50 - ${#title} )) '' | tr ' ' '─')${NC}"
    log_info "==== SECTION: ${title} ===="
}

spinner() {
    local pid="$1" desc="$2"
    local i=0 chars="$SPINNER_CHARS"
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#chars} ))
        printf "\r${CYAN}[%s]${NC} %s" "${chars:$i:1}" "$desc"
        sleep 0.1
    done
    tput cnorm 2>/dev/null || true
}

# Runs a function quietly in the background, shows a spinner, then prints
# a green check or red X. All real stdout/stderr goes to $LOG_FILE only.
run_step() {
    local desc="$1" func="$2"
    COMPONENT_ORDER+=("$desc")
    printf "${CYAN}[ ]${NC} %s" "$desc"
    log_info "START: ${desc}"

    ( set -Eeuo pipefail; "$func" ) >> "$LOG_FILE" 2>&1 &
    local pid=$!
    spinner "$pid" "$desc"

    wait "$pid"
    local code=$?

    if [[ $code -eq 0 ]]; then
        printf "\r${GREEN}[✓]${NC} %s\n" "$desc"
        log_info "SUCCESS: ${desc}"
        RESULT["$desc"]="OK"
    else
        printf "\r${RED}[✗]${NC} %s\n" "$desc"
        log_error "FAILED: ${desc} (exit code ${code})"
        RESULT["$desc"]="FAILED"
        fail_and_exit "$desc"
    fi
}

skip_step() {
    local desc="$1" reason="$2"
    COMPONENT_ORDER+=("$desc")
    printf "${YELLOW}[~]${NC} %s ${DIM}(skipped: %s)${NC}\n" "$desc" "$reason"
    log_warn "SKIPPED: ${desc} (${reason})"
    RESULT["$desc"]="SKIPPED"
}

fail_and_exit() {
    local desc="$1"
    echo
    echo -e "${RED}${BOLD}✘ Installation failed at step: ${desc}${NC}"
    echo -e "${YELLOW}Full log: ${LOG_FILE}${NC}"
    echo -e "${DIM}── Last 25 log lines ──${NC}"
    tail -n 25 "$LOG_FILE" | sed 's/^/    /'
    echo
    echo -e "${DIM}This script is idempotent - fix the issue above and re-run it to resume.${NC}"
    exit 1
}

on_unexpected_error() {
    local line="$1"
    echo -e "\n${RED}${BOLD}✘ Unexpected error near line ${line}.${NC}"
    echo -e "${YELLOW}Check log: ${LOG_FILE}${NC}"
    exit 1
}
trap 'on_unexpected_error $LINENO' ERR

###############################################################################
# PRELIGHT: ARGS, ROOT, OS, RESOURCES
###############################################################################

usage() {
    cat <<EOF
Usage: sudo ./devops-ultimate-bootstrap-installer.sh [OPTIONS]

Options:
  -y, --yes            Non-interactive mode, assume yes to prompts
  --skip-heavy         Skip Jenkins + SonarQube (saves ~4-6GB RAM)
  --pod-cidr=CIDR      Override pod network CIDR (default: ${POD_CIDR})
  --k8s-version=X.Y    Override Kubernetes minor version (default: ${K8S_MINOR_VERSION})
  -h, --help           Show this help

Examples:
  sudo ./devops-ultimate-bootstrap-installer.sh -y
  sudo ./devops-ultimate-bootstrap-installer.sh -y --skip-heavy
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) NON_INTERACTIVE=true ;;
            --skip-heavy) SKIP_HEAVY=true ;;
            --pod-cidr=*) POD_CIDR="${1#*=}" ;;
            --k8s-version=*) K8S_MINOR_VERSION="${1#*=}" ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
    done
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}This script must be run as root or with sudo.${NC}"
        echo "Try: sudo ./devops-ultimate-bootstrap-installer.sh"
        exit 1
    fi
}

detect_system() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
        OS_CODENAME="${VERSION_CODENAME}"
    else
        echo -e "${RED}Cannot detect OS (/etc/os-release missing).${NC}"
        exit 1
    fi

    if [[ "${OS_ID}" != "ubuntu" ]]; then
        echo -e "${RED}This installer supports Ubuntu only. Detected: ${OS_ID}${NC}"
        exit 1
    fi

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  ARCH_DEB="amd64" ;;
        aarch64) ARCH_DEB="arm64" ;;
        *) echo -e "${RED}Unsupported architecture: ${ARCH}${NC}"; exit 1 ;;
    esac

    echo -e "${GREEN}Detected:${NC} Ubuntu ${OS_VERSION} (${OS_CODENAME}) - ${ARCH} (${ARCH_DEB})"
    log_info "OS=${OS_ID} ${OS_VERSION} (${OS_CODENAME}) ARCH=${ARCH} (${ARCH_DEB})"
}

preflight_resource_check() {
    local mem_kb total_mem_gb cpu_count
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    total_mem_gb=$(( mem_kb / 1024 / 1024 ))
    cpu_count=$(nproc)

    echo -e "${GREEN}Resources:${NC} ${cpu_count} vCPU / ${total_mem_gb}GB RAM"
    log_info "Resources: ${cpu_count} vCPU / ${total_mem_gb}GB RAM"

    if (( total_mem_gb < 8 )); then
        echo -e "${YELLOW}${BOLD}⚠ Warning:${NC} Only ${total_mem_gb}GB RAM detected."
        echo -e "  The full platform stack (K8s + ArgoCD + Jenkins + Prometheus + SonarQube)"
        echo -e "  comfortably needs 16GB+. Consider re-running with ${BOLD}--skip-heavy${NC}."
        if [[ "${NON_INTERACTIVE}" == false && -t 0 ]]; then
            read -rp "  Continue anyway? [y/N] " ans
            [[ "$ans" =~ ^[Yy]$ ]] || exit 1
        fi
    fi
}

confirm_before_proceeding() {
    if [[ "${NON_INTERACTIVE}" == true || ! -t 0 ]]; then
        log_info "Proceeding non-interactively."
        return 0
    fi
    echo -e "${YELLOW}${BOLD}This will install Docker, initialize a Kubernetes cluster (kubeadm),${NC}"
    echo -e "${YELLOW}${BOLD}disable swap, modify sysctl/kernel settings, and deploy a full platform stack.${NC}"
    read -rp "Proceed? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted by user."; exit 0; }
}

###############################################################################
# BASE TOOLS
###############################################################################

step_apt_update() {
    apt-get update -qq
}

step_install_base_tools() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        git curl wget vim nano unzip jq net-tools htop \
        ca-certificates gnupg apt-transport-https
}

###############################################################################
# DOCKER
###############################################################################

step_install_docker() {
    if command -v docker &>/dev/null; then
        echo "Docker already installed: $(docker --version)"
        return 0
    fi
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=${ARCH_DEB} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${OS_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker --now
    if ! getent group docker | grep -qw "${INSTALL_USER}"; then
        usermod -aG docker "${INSTALL_USER}"
    fi
}

step_configure_containerd() {
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl enable containerd
    systemctl restart containerd
}

step_validate_docker() {
    docker run --rm hello-world
}

###############################################################################
# KUBERNETES PREREQUISITES
###############################################################################

step_disable_swap() {
    swapoff -a
    sed -i.bak -E '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab
}

step_kernel_modules() {
    cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter
}

step_sysctl_networking() {
    cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system >/dev/null
}

###############################################################################
# KUBERNETES CONTROL PLANE
###############################################################################

step_install_kube_tools() {
    if command -v kubeadm &>/dev/null; then
        echo "kubeadm already installed: $(kubeadm version -o short 2>/dev/null || true)"
        return 0
    fi
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR_VERSION}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR_VERSION}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
    systemctl enable kubelet
}

step_kubeadm_init() {
    if [[ -f /etc/kubernetes/admin.conf ]]; then
        echo "Cluster already initialized, skipping kubeadm init."
        return 0
    fi

    local advertise_ip
    advertise_ip="$(hostname -I | awk '{print $1}')"

    kubeadm init \
        --pod-network-cidr="${POD_CIDR}" \
        --apiserver-advertise-address="${advertise_ip}" \
        --cri-socket=unix:///run/containerd/containerd.sock \
        --ignore-preflight-errors=NumCPU,Mem

    install -d -m 700 -o "${INSTALL_USER}" -g "${INSTALL_USER}" "${HOME_DIR}/.kube"
    install -m 600 -o "${INSTALL_USER}" -g "${INSTALL_USER}" /etc/kubernetes/admin.conf "${HOME_DIR}/.kube/config"

    install -d -m 700 /root/.kube
    install -m 600 /etc/kubernetes/admin.conf /root/.kube/config

    # Single-node lab cluster: allow workloads to schedule on the control-plane node.
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint nodes --all \
        node-role.kubernetes.io/control-plane- 2>/dev/null || true
}

step_install_calico() {
    if kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -q .; then
        echo "Calico already installed."
        return 0
    fi
    kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
}

step_wait_cluster_ready() {
    kubectl wait --for=condition=Ready node --all --timeout=300s
    kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
}

###############################################################################
# KUBERNETES TOOLING
###############################################################################

step_install_helm() {
    if command -v helm &>/dev/null; then
        echo "Helm already installed: $(helm version --short)"
        return 0
    fi
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get_helm.sh
    chmod +x /tmp/get_helm.sh
    /tmp/get_helm.sh
}

step_add_helm_repos() {
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
    helm repo add argo https://argoproj.github.io/argo-helm --force-update
    helm repo add jenkins https://charts.jenkins.io --force-update
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
    helm repo add grafana https://grafana.github.io/helm-charts --force-update
    helm repo add aqua https://aquasecurity.github.io/helm-charts --force-update
    helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube --force-update
    helm repo update
}

step_install_k8s_cli_tools() {
    if ! command -v kubectx &>/dev/null; then
        if [[ -d /opt/kubectx ]]; then
            git -C /opt/kubectx pull --quiet
        else
            git clone --quiet --depth 1 https://github.com/ahmetb/kubectx /opt/kubectx
        fi
        ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx
        ln -sf /opt/kubectx/kubens /usr/local/bin/kubens
    fi

    if ! command -v k9s &>/dev/null; then
        local k9s_ver
        k9s_ver="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name)"
        curl -fsSL "https://github.com/derailed/k9s/releases/download/${k9s_ver}/k9s_Linux_${ARCH_DEB}.tar.gz" -o /tmp/k9s.tar.gz
        tar -xzf /tmp/k9s.tar.gz -C /tmp k9s
        install -m 0755 /tmp/k9s /usr/local/bin/k9s
    fi
}

###############################################################################
# AWS & IAC TOOLING
###############################################################################

step_install_aws_cli() {
    if command -v aws &>/dev/null; then
        echo "AWS CLI already installed: $(aws --version)"
        return 0
    fi
    local zip_arch="x86_64"
    [[ "${ARCH_DEB}" == "arm64" ]] && zip_arch="aarch64"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${zip_arch}.zip" -o /tmp/awscliv2.zip
    unzip -q -o /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install --update
}

step_install_terraform() {
    if command -v terraform &>/dev/null; then
        echo "Terraform already installed: $(terraform version | head -1)"
        return 0
    fi
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
    echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${OS_CODENAME} main" \
        > /etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq terraform
}

###############################################################################
# PLATFORM: INGRESS, SECURITY, SCANNING
###############################################################################

step_install_nginx_ingress() {
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace \
        --set controller.service.type=NodePort \
        --wait --timeout 10m
}

step_install_cert_manager() {
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --set crds.enabled=true \
        --wait --timeout 10m
}

step_install_trivy() {
    helm upgrade --install trivy aqua/trivy-operator \
        --namespace trivy-system --create-namespace \
        --wait --timeout 10m
}

###############################################################################
# PLATFORM: GITOPS & CI/CD
###############################################################################

step_install_argocd() {
    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd --create-namespace \
        --wait --timeout 10m
}

step_install_jenkins() {
    helm upgrade --install jenkins jenkins/jenkins \
        --namespace jenkins --create-namespace \
        --wait --timeout 10m
}

###############################################################################
# PLATFORM: OBSERVABILITY
###############################################################################

step_install_monitoring_stack() {
    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
        --namespace monitoring --create-namespace \
        --set prometheus.prometheusSpec.retention=6h \
        --set prometheus.prometheusSpec.resources.requests.cpu=250m \
        --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
        --set grafana.resources.requests.cpu=100m \
        --set grafana.resources.requests.memory=128Mi \
        --wait --timeout 15m
}

step_install_logging_stack() {
    helm upgrade --install loki grafana/loki-stack \
        --namespace logging --create-namespace \
        --set promtail.enabled=true \
        --set grafana.enabled=false \
        --wait --timeout 10m
}

###############################################################################
# PLATFORM: CODE QUALITY
###############################################################################

step_install_sonarqube() {
    sysctl -w vm.max_map_count=262144 >/dev/null
    grep -q "^vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf
    helm upgrade --install sonarqube sonarqube/sonarqube \
        --namespace sonarqube --create-namespace \
        --wait --timeout 15m
}

###############################################################################
# SHELL ENHANCEMENTS
###############################################################################

step_configure_shell_extras() {
    kubectl completion bash > /etc/bash_completion.d/kubectl

    local marker="# ===== DevOps Bootstrap Aliases ====="
    local block
    block=$(cat <<'EOF'
# ===== DevOps Bootstrap Aliases =====
alias k=kubectl
complete -o default -F __start_kubectl k
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kga='kubectl get all'
alias kgn='kubectl get nodes'
alias kctx=kubectx
alias kns=kubens
# =====================================
EOF
)
    for rc in "${HOME_DIR}/.bashrc" /root/.bashrc; do
        [[ -f "$rc" ]] || touch "$rc"
        grep -qF "$marker" "$rc" || echo "$block" >> "$rc"
    done

    mkdir -p "${HELM_VALUES_DIR}"
}

###############################################################################
# VALIDATION
###############################################################################

run_validation() {
    section "VALIDATION"
    log_info "==== VALIDATION ===="

    echo -e "${BOLD}Tool Versions:${NC}"
    docker --version                       | tee -a "$LOG_FILE"
    kubectl version --client --output=yaml | tee -a "$LOG_FILE"
    helm version --short                   | tee -a "$LOG_FILE"
    terraform version | head -1            | tee -a "$LOG_FILE"
    aws --version                          | tee -a "$LOG_FILE"

    echo
    echo -e "${BOLD}Cluster Nodes:${NC}"
    kubectl get nodes -o wide | tee -a "$LOG_FILE"

    echo
    echo -e "${BOLD}Namespace Health:${NC}"
    for ns in argocd jenkins monitoring logging; do
        if kubectl get ns "$ns" &>/dev/null; then
            echo -e "${GREEN}[✓]${NC} Namespace '${ns}' exists"
        else
            echo -e "${RED}[✗]${NC} Namespace '${ns}' missing"
        fi
    done
}

###############################################################################
# FINAL REPORT
###############################################################################

status_symbol() {
    case "${RESULT[$1]:-MISSING}" in
        OK) echo -e "${GREEN}✓${NC}" ;;
        SKIPPED) echo -e "${YELLOW}-${NC}" ;;
        *) echo -e "${RED}✗${NC}" ;;
    esac
}

print_final_report() {
    local elapsed=$(( $(date +%s) - START_TIME ))
    local public_ip
    public_ip="$(curl -fsSL --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<EC2_PUBLIC_IP>")"

    echo
    echo -e "${GREEN}${BOLD}===================================================="
    echo " INSTALLATION COMPLETE"
    echo -e "====================================================${NC}"
    echo -e "${DIM}Elapsed time: $(( elapsed / 60 ))m $(( elapsed % 60 ))s${NC}"
    echo
    echo -e "${BOLD}Installed Components:${NC}"
    echo -e " $(status_symbol "Installing Docker Engine") Docker"
    echo -e " $(status_symbol "Initializing Kubernetes cluster") Kubernetes"
    echo -e " $(status_symbol "Installing Helm") Helm"
    echo -e " $(status_symbol "Installing ArgoCD") ArgoCD"
    echo -e " $(status_symbol "Installing Jenkins") Jenkins"
    echo -e " $(status_symbol "Installing kube-prometheus-stack") Prometheus"
    echo -e " $(status_symbol "Installing kube-prometheus-stack") Grafana"
    echo -e " $(status_symbol "Installing Loki + Promtail") Loki"
    echo -e " $(status_symbol "Installing Terraform") Terraform"
    echo -e " $(status_symbol "Installing AWS CLI") AWS CLI"
    echo -e " $(status_symbol "Installing Trivy Operator") Trivy"
    echo -e " $(status_symbol "Installing SonarQube") SonarQube"
    echo
    echo -e "${BOLD}Access the platform (run from the instance, or via SSH tunnel):${NC}"
    echo
    echo -e "${CYAN}ArgoCD${NC}"
    echo "  kubectl -n argocd port-forward svc/argocd-server 8080:443"
    echo "  https://${public_ip}:8080  (or https://localhost:8080 via SSH tunnel)"
    echo "  user: admin / password:"
    echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo
    echo -e "${CYAN}Jenkins${NC}"
    echo "  kubectl -n jenkins port-forward svc/jenkins 8081:8080"
    echo "  http://${public_ip}:8081"
    echo "  user: admin / password:"
    echo "  kubectl -n jenkins exec -it svc/jenkins -c jenkins -- /bin/cat /run/secrets/chart-admin-password"
    echo
    echo -e "${CYAN}Grafana${NC}"
    echo "  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80"
    echo "  http://${public_ip}:3000"
    echo "  user: admin / password: prom-operator   (rotate this immediately)"
    echo
    if [[ "${RESULT["Installing SonarQube"]:-}" == "OK" ]]; then
        echo -e "${CYAN}SonarQube${NC}"
        echo "  kubectl -n sonarqube port-forward svc/sonarqube-sonarqube 9000:9000"
        echo "  http://${public_ip}:9000   (default admin/admin, forces password change)"
        echo
    fi
    echo -e "${DIM}Aliases available in new shells: k, kgp, kgs, kga, kgn, kctx, kns${NC}"
    echo -e "${DIM}Re-login (or run: newgrp docker) for the ec2-user to use docker without sudo.${NC}"
    echo -e "${DIM}Full log: ${LOG_FILE}${NC}"
    echo
    log_info "==== INSTALLATION COMPLETE in ${elapsed}s ===="
}

###############################################################################
# MAIN
###############################################################################

main() {
    parse_args "$@"
    check_root
    init_log "$@"
    print_banner
    detect_system
    preflight_resource_check
    confirm_before_proceeding

    section "BASE TOOLS"
    run_step "Updating package index"              step_apt_update
    run_step "Installing base utilities"            step_install_base_tools

    section "CONTAINER RUNTIME"
    run_step "Installing Docker Engine"             step_install_docker
    run_step "Configuring containerd for Kubernetes" step_configure_containerd
    run_step "Validating Docker (hello-world)"      step_validate_docker

    section "KUBERNETES PREREQUISITES"
    run_step "Disabling swap"                       step_disable_swap
    run_step "Loading kernel modules"                step_kernel_modules
    run_step "Configuring sysctl networking"         step_sysctl_networking

    section "KUBERNETES CONTROL PLANE"
    run_step "Installing kubeadm/kubelet/kubectl"   step_install_kube_tools
    run_step "Initializing Kubernetes cluster"       step_kubeadm_init
    export KUBECONFIG=/etc/kubernetes/admin.conf
    run_step "Installing Calico CNI"                 step_install_calico
    run_step "Waiting for cluster readiness"          step_wait_cluster_ready

    section "KUBERNETES TOOLING"
    run_step "Installing Helm"                       step_install_helm
    run_step "Adding Helm repositories"               step_add_helm_repos
    run_step "Installing kubectx / kubens / k9s"      step_install_k8s_cli_tools

    section "AWS & IAC TOOLING"
    run_step "Installing AWS CLI"                     step_install_aws_cli
    run_step "Installing Terraform"                   step_install_terraform

    section "PLATFORM: INGRESS & SECURITY"
    run_step "Installing NGINX Ingress Controller"   step_install_nginx_ingress
    run_step "Installing cert-manager"                step_install_cert_manager
    run_step "Installing Trivy Operator"              step_install_trivy

    section "PLATFORM: GITOPS & CI/CD"
    run_step "Installing ArgoCD"                       step_install_argocd
    if [[ "${SKIP_HEAVY}" == false ]]; then
        run_step "Installing Jenkins"                  step_install_jenkins
    else
        skip_step "Installing Jenkins" "--skip-heavy"
    fi

    section "PLATFORM: OBSERVABILITY"
    run_step "Installing kube-prometheus-stack"       step_install_monitoring_stack
    run_step "Installing Loki + Promtail"              step_install_logging_stack

    section "PLATFORM: CODE QUALITY"
    if [[ "${SKIP_HEAVY}" == false ]]; then
        run_step "Installing SonarQube"               step_install_sonarqube
    else
        skip_step "Installing SonarQube" "--skip-heavy"
    fi

    section "SHELL ENHANCEMENTS"
    run_step "Configuring kubectl aliases & autocomplete" step_configure_shell_extras

    run_validation
    print_final_report
}

main "$@"
echo " Thank you for using TitanStack Project "
