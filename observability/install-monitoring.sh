#!/usr/bin/env bash
# install-monitoring.sh
# Installs kube-prometheus-stack + supply SLO rules + Grafana dashboard
# Run from repo root: bash observability/install-monitoring.sh

set -euo pipefail

MONITORING_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Step 1: Add Helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "==> Step 2: Create monitoring namespace"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "==> Step 3: Pre-create Grafana dashboard ConfigMap"
# Must happen BEFORE Helm install so the Grafana pod can mount it on first start.
# If ConfigMap is missing at pod start, Grafana gets stuck in ContainerCreating forever.
kubectl apply -f "${MONITORING_DIR}/grafana-dashboard-configmap.yaml"
echo "Dashboard ConfigMap ready."

echo "==> Step 4: Install kube-prometheus-stack"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "${MONITORING_DIR}/kube-prometheus-stack-values.yaml" \
  --timeout 10m \
  --wait

echo "==> Step 5: Apply SLO recording rules and alerts"
kubectl apply -f "${MONITORING_DIR}/slo-rules.yaml"

echo "==> Step 6: Apply ServiceMonitors"
kubectl apply -f "${MONITORING_DIR}/service-monitors.yaml"

echo ""
echo "==> Waiting for rollout..."
kubectl -n monitoring rollout status deployment/kube-prometheus-stack-grafana --timeout=5m
kubectl -n monitoring rollout status deployment/kube-prometheus-stack-kube-state-metrics --timeout=5m

echo ""
echo "============================================================"
echo "  Monitoring stack ready."
echo ""
echo "  Grafana:    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "              http://localhost:3000  (admin / supply-demo-admin)"
echo ""
echo "  Prometheus: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
echo "              http://localhost:9090"
echo "============================================================"
