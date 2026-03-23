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

echo "==> Step 3: Pre-create Grafana dashboard ConfigMap
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${MONITORING_DIR}/grafana-dashboard-configmap.yaml"
echo "Dashboard ConfigMap pre-created."

echo "==> Step 4: Install kube-prometheus-stack"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "${MONITORING_DIR}/kube-prometheus-stack-values.yaml" \
  --timeout 10m \
  --wait

echo "==> Step 4: Apply Grafana dashboard ConfigMap"
kubectl apply -f "${MONITORING_DIR}/grafana-dashboard-configmap.yaml"

echo "==> Step 5: Apply SLO recording rules and alerts"
kubectl apply -f "${MONITORING_DIR}/slo-rules.yaml"

echo "==> Step 6: Apply ServiceMonitors"
kubectl apply -f "${MONITORING_DIR}/service-monitors.yaml"

echo ""
echo "==> Done! Waiting for pods to be ready..."
kubectl -n monitoring rollout status deployment/kube-prometheus-stack-grafana
kubectl -n monitoring rollout status deployment/kube-prometheus-stack-kube-state-metrics

echo ""
echo "============================================================"
echo "  Access Grafana:"
echo "  kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "  Open: http://localhost:3000"
echo "  Login: admin / supply-demo-admin"
echo ""
echo "  Access Prometheus:"
echo "  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
echo "  Open: http://localhost:9090"
echo "============================================================"
