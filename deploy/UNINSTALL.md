# Uninstall Instructions for Semantic Router + MaaS

This document provides instructions for completely removing the two-gateway deployment to enable clean reinstalls.

## Quick Uninstall (vSR Only)

Remove just the semantic router deployment while keeping MaaS:

```bash
# Delete the vSR namespace (includes all pods, services, deployments)
kubectl delete namespace vllm-semantic-router-system --force --grace-period=0

# Wait for namespace deletion to complete
kubectl wait --for=delete namespace/vllm-semantic-router-system --timeout=120s 2>/dev/null || true
```

## Full Uninstall (vSR + MaaS)

Remove both semantic router and MaaS gateway:

```bash
# 1. Delete vSR namespace
kubectl delete namespace vllm-semantic-router-system --force --grace-period=0

# 2. Delete MaaS components
kubectl delete gateway maas-default-gateway -n openshift-ingress 2>/dev/null
kubectl delete deployment maas-api -n openshift-ingress 2>/dev/null
kubectl delete service maas-api -n openshift-ingress 2>/dev/null

# 3. Delete Kuadrant policies (if any custom ones were created)
kubectl delete authpolicy --all -n vllm-semantic-router-system 2>/dev/null
kubectl delete ratelimitpolicy --all -n vllm-semantic-router-system 2>/dev/null

# 4. Optionally remove Kuadrant (if not used elsewhere)
# kubectl delete namespace kuadrant-system
```

## Deep Clean (Including KServe LLMInferenceService)

If you also need to reset the KServe LLMInferenceService components:

```bash
# Delete LLMInferenceServiceConfig templates (will be recreated on next install)
kubectl delete llminferenceserviceconfig kserve-config-llm-template -n kserve 2>/dev/null

# Delete version-prefixed templates (ODH creates these)
kubectl get llminferenceserviceconfig -n kserve -o name | xargs kubectl delete -n kserve 2>/dev/null

# Reset the webhook CA bundle (may need re-patching on next install)
# Note: This is usually not needed unless webhook is broken
```

## Verify Clean State

After uninstall, verify the cluster is clean:

```bash
# Check no vSR resources remain
kubectl get all -n vllm-semantic-router-system 2>/dev/null || echo "Namespace removed"

# Check no LLMInferenceServices in target namespace
kubectl get llminferenceservices -A 2>/dev/null | grep -v "^kserve"

# Check MaaS gateway status
kubectl get gateway maas-default-gateway -n openshift-ingress 2>/dev/null || echo "MaaS gateway not present"

# Check node resources available for fresh deploy
kubectl top nodes 2>/dev/null
```

## Reinstall

After cleanup, redeploy with:

```bash
# Deploy MaaS (if removed)
cd /path/to/models-as-a-service/scripts
./deploy-rhoai-stable.sh

# Deploy vSR with simulator
cd /path/to/semantic-router/deploy/openshift
./deploy-to-openshift.sh --kserve --simulator --no-public-route

# Apply MaaS integration
cd maas-integration
./apply-maas-integration.sh
```

## Troubleshooting Stuck Deletions

If namespace deletion hangs:

```bash
# Check for stuck finalizers
kubectl get namespace vllm-semantic-router-system -o yaml | grep -A5 "finalizers:"

# Force remove finalizers (use with caution)
kubectl patch namespace vllm-semantic-router-system -p '{"metadata":{"finalizers":[]}}' --type=merge

# Check for resources preventing deletion
kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get --show-kind --ignore-not-found -n vllm-semantic-router-system
```

If LLMInferenceService deletion hangs:

```bash
# Remove finalizer from stuck LLMInferenceService
kubectl patch llminferenceservice <name> -n vllm-semantic-router-system \
  -p '{"metadata":{"finalizers":[]}}' --type=merge
```
