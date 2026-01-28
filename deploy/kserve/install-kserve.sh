#!/bin/bash
# Install KServe and dependencies for OpenShift clusters without a preinstalled KServe stack.
# Mirrors the MaaS installer flow while using oc for OpenShift clusters.
# Supports both InferenceService and LLMInferenceService CRDs.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

KSERVE_VERSION="v0.15.2"
LLMISVC_VERSION="v0.15.2"
CERT_MANAGER_VERSION="v1.14.5"
OCP=false
INSTALL_LLMISVC=true

usage() {
    cat <<EOF
Usage: $0 [--ocp]

Options:
  --ocp    Validate OpenShift Serverless instead of installing vanilla KServe
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ocp)
            OCP=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

if ! command -v oc &>/dev/null; then
    error "oc CLI not found. Install OpenShift CLI first."
    exit 1
fi

if [[ "$OCP" == true ]]; then
    log "Validating OpenShift Serverless operator is installed..."
    if ! oc get subscription serverless-operator -n openshift-serverless >/dev/null 2>&1; then
        error "OpenShift Serverless operator not found. Please install it first."
        exit 1
    fi

    log "Validating OpenShift Serverless controller is running..."
    if ! oc wait --for=condition=ready pod --all -n openshift-serverless --timeout=60s >/dev/null 2>&1; then
        error "OpenShift Serverless controller is not ready."
        exit 1
    fi

    success "OpenShift Serverless operator is installed and running."
    exit 0
fi

# Check if both KServe CRDs are already installed
INFERENCESERVICE_INSTALLED=false
LLMISVC_INSTALLED=false

if oc get crd inferenceservices.serving.kserve.io &>/dev/null; then
    INFERENCESERVICE_INSTALLED=true
    log "InferenceService CRD already installed."
fi

if oc get crd llminferenceservices.serving.kserve.io &>/dev/null; then
    LLMISVC_INSTALLED=true
    log "LLMInferenceService CRD already installed."
fi

if [[ "$INFERENCESERVICE_INSTALLED" == true ]] && [[ "$LLMISVC_INSTALLED" == true ]]; then
    success "All KServe CRDs already installed."
    exit 0
fi

# Install InferenceService CRD if not already installed
if [[ "$INFERENCESERVICE_INSTALLED" == false ]]; then
    if ! oc get crd certificates.cert-manager.io &>/dev/null; then
        log "Installing cert-manager ($CERT_MANAGER_VERSION)..."
        oc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
        if oc get namespace cert-manager &>/dev/null; then
            oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=5m || true
            oc wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=5m || true
            oc wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=5m || true
        else
            warn "cert-manager namespace not found after install; continuing."
        fi
    else
        log "cert-manager CRDs already present."
    fi

    log "Installing KServe ($KSERVE_VERSION)..."
    # Use server-side apply to avoid annotation size limits on CRDs
    oc apply --server-side --force-conflicts -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve.yaml"

    # Wait for KServe controller and webhook to be ready before applying cluster resources
    if oc get namespace kserve &>/dev/null; then
        log "Waiting for KServe controller manager to be ready..."
        oc wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=5m || true

        log "Waiting for KServe webhook service endpoints to be ready..."
        for i in {1..60}; do
            ENDPOINTS=$(oc get endpoints kserve-webhook-server-service -n kserve -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
            if [[ -n "$ENDPOINTS" ]]; then
                success "KServe webhook service has ready endpoints"
                break
            fi
            if [[ $i -eq 60 ]]; then
                warn "Timeout waiting for webhook endpoints, continuing anyway..."
            fi
            sleep 2
        done
    else
        warn "KServe namespace not found after install; verify installation."
    fi

    # Apply cluster resources after webhook is ready
    log "Applying KServe cluster resources..."
    oc apply --server-side --force-conflicts -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve-cluster-resources.yaml"

    if oc get crd inferenceservices.serving.kserve.io &>/dev/null; then
        success "KServe CRDs installed."
    else
        error "KServe CRDs still missing after install."
        exit 1
    fi
fi

# Install LLMInferenceService CRD if requested
if [[ "$INSTALL_LLMISVC" == true ]]; then
    if oc get crd llminferenceservices.serving.kserve.io &>/dev/null; then
        success "LLMInferenceService CRD already installed."
    else
        log "Installing LLMInferenceService CRD..."

        # Download the kserve quick install script which contains embedded CRDs
        LLMISVC_INSTALL_URL="https://raw.githubusercontent.com/kserve/kserve/master/hack/setup/quick-install/llmisvc-full-install-with-manifests.sh"
        TEMP_SCRIPT=$(mktemp)
        TEMP_CRD_CONFIG=$(mktemp)
        TEMP_CRD_MAIN=$(mktemp)

        log "Downloading LLMInferenceService install manifests..."
        if curl -sL "$LLMISVC_INSTALL_URL" -o "$TEMP_SCRIPT"; then
            # Extract CRD definitions from the embedded heredocs in the script
            # LLMInferenceServiceConfig CRD starts at line containing 'apiVersion: apiextensions' for llminferenceserviceconfigs
            # LLMInferenceServices CRD starts at the second 'apiVersion: apiextensions' block

            # Find line numbers for the CRD blocks
            CONFIG_CRD_START=$(grep -n "name: llminferenceserviceconfigs.serving.kserve.io" "$TEMP_SCRIPT" | head -1 | cut -d: -f1)
            MAIN_CRD_START=$(grep -n "name: llminferenceservices.serving.kserve.io" "$TEMP_SCRIPT" | head -1 | cut -d: -f1)

            if [[ -n "$CONFIG_CRD_START" ]] && [[ -n "$MAIN_CRD_START" ]]; then
                # Extract from 6 lines before the name (to get apiVersion line) to the line before the next CRD
                CONFIG_CRD_REAL_START=$((CONFIG_CRD_START - 6))
                sed -n "${CONFIG_CRD_REAL_START},$((MAIN_CRD_START - 8))p" "$TEMP_SCRIPT" > "$TEMP_CRD_CONFIG"

                # For main CRD, extract from 6 lines before name to EOF marker
                MAIN_CRD_REAL_START=$((MAIN_CRD_START - 6))
                MAIN_CRD_END=$(grep -n "KSERVE_CRD_MANIFEST_EOF" "$TEMP_SCRIPT" | tail -1 | cut -d: -f1)
                if [[ -n "$MAIN_CRD_END" ]]; then
                    sed -n "${MAIN_CRD_REAL_START},$((MAIN_CRD_END - 1))p" "$TEMP_SCRIPT" > "$TEMP_CRD_MAIN"
                fi

                # Apply the CRDs using server-side apply to avoid annotation size limits
                if [[ -s "$TEMP_CRD_CONFIG" ]]; then
                    log "Applying LLMInferenceServiceConfig CRD..."
                    oc apply --server-side --force-conflicts -f "$TEMP_CRD_CONFIG" || warn "Failed to apply LLMInferenceServiceConfig CRD"
                fi

                if [[ -s "$TEMP_CRD_MAIN" ]]; then
                    log "Applying LLMInferenceServices CRD..."
                    oc apply --server-side --force-conflicts -f "$TEMP_CRD_MAIN" || warn "Failed to apply LLMInferenceServices CRD"
                fi

                # Extract and apply core manifests (controller, webhook service, etc.)
                TEMP_CORE=$(mktemp)
                CORE_START=$(grep -n "KSERVE_CORE_MANIFEST_EOF" "$TEMP_SCRIPT" | head -1 | cut -d: -f1)
                CORE_END=$(grep -n "KSERVE_CORE_MANIFEST_EOF" "$TEMP_SCRIPT" | tail -1 | cut -d: -f1)
                if [[ -n "$CORE_START" ]] && [[ -n "$CORE_END" ]] && [[ "$CORE_START" -lt "$CORE_END" ]]; then
                    sed -n "$((CORE_START + 1)),$((CORE_END - 1))p" "$TEMP_SCRIPT" > "$TEMP_CORE"
                    if [[ -s "$TEMP_CORE" ]]; then
                        log "Applying LLMInferenceService core manifests (controller, webhook, etc.)..."
                        oc apply --server-side --force-conflicts -f "$TEMP_CORE" || warn "Failed to apply LLMInferenceService core manifests"

                        # Grant privileged SCC to the controller service account (required for OpenShift)
                        log "Granting OpenShift SCC to LLMInferenceService controller..."
                        oc adm policy add-scc-to-user privileged -z llmisvc-controller-manager -n kserve 2>/dev/null || true

                        # Wait for controller to be ready
                        log "Waiting for LLMInferenceService controller to be ready..."
                        oc rollout restart deployment/llmisvc-controller-manager -n kserve 2>/dev/null || true
                        oc wait --for=condition=Available deployment/llmisvc-controller-manager -n kserve --timeout=3m || warn "Controller may not be ready yet"

                        # Wait for webhook endpoints to be ready
                        log "Waiting for LLMInferenceService webhook endpoints..."
                        for i in {1..30}; do
                            ENDPOINTS=$(oc get endpoints llmisvc-webhook-server-service -n kserve -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
                            if [[ -n "$ENDPOINTS" ]]; then
                                success "LLMInferenceService webhook has ready endpoints"
                                break
                            fi
                            sleep 2
                        done
                    fi
                fi
                rm -f "$TEMP_CORE"
            else
                warn "Could not find LLMInferenceService CRD definitions in install script."
            fi
        else
            warn "Failed to download LLMInferenceService install script."
        fi

        rm -f "$TEMP_SCRIPT" "$TEMP_CRD_CONFIG" "$TEMP_CRD_MAIN"

        # Wait for CRD to be established
        log "Waiting for LLMInferenceService CRD to be established..."
        for i in {1..30}; do
            if oc get crd llminferenceservices.serving.kserve.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null | grep -q "True"; then
                success "LLMInferenceService CRD installed and established."
                break
            fi
            if [[ $i -eq 30 ]]; then
                warn "Timeout waiting for CRD to be established."
            fi
            sleep 2
        done
    fi
fi
