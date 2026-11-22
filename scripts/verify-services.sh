#!/bin/bash
# Verify all expected services are Running after an RKE2 upgrade.
# Prints a pass/fail summary per namespace.
#
# Usage: ./verify-services.sh

set -euo pipefail

echo "=== Post-Upgrade Service Verification ==="
echo "Cluster: $(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}')"
echo "Date   : $(date -u)"
echo ""

PASS=0
FAIL=0

check_deployment() {
  local ns="$1" name="$2"
  local ready
  ready=$(kubectl get deployment -n "$ns" "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  local desired
  desired=$(kubectl get deployment -n "$ns" "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [[ "$desired" == "0" ]]; then
    echo "  SKIP  [$ns] $name (scaled to 0 — intentional)"
    return
  fi
  if [[ "$ready" == "$desired" && "$ready" != "0" ]]; then
    echo "  PASS  [$ns] $name ($ready/$desired ready)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  [$ns] $name ($ready/$desired ready)"
    FAIL=$((FAIL + 1))
  fi
}

check_statefulset() {
  local ns="$1" name="$2"
  local ready
  ready=$(kubectl get statefulset -n "$ns" "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  local desired
  desired=$(kubectl get statefulset -n "$ns" "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [[ "$desired" == "0" ]]; then
    echo "  SKIP  [$ns] $name (scaled to 0 — intentional)"
    return
  fi
  if [[ "$ready" == "$desired" && "$ready" != "0" ]]; then
    echo "  PASS  [$ns] $name ($ready/$desired ready)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  [$ns] $name ($ready/$desired ready)"
    FAIL=$((FAIL + 1))
  fi
}

check_daemonset() {
  local ns="$1" name="$2"
  local ready desired
  ready=$(kubectl get daemonset -n "$ns" "$name" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  desired=$(kubectl get daemonset -n "$ns" "$name" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  if [[ "$ready" == "$desired" && "$ready" != "0" ]]; then
    echo "  PASS  [$ns] $name ($ready/$desired ready)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  [$ns] $name ($ready/$desired ready)"
    FAIL=$((FAIL + 1))
  fi
}

echo "--- Node ---"
NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
if echo "$NODE_STATUS" | grep -qv "Ready"; then
  echo "  FAIL  Node not Ready"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  All nodes Ready"
  PASS=$((PASS + 1))
fi

echo ""
echo "--- kube-system ---"
check_daemonset   kube-system rke2-canal
check_deployment  kube-system rke2-coredns-rke2-coredns
check_deployment  kube-system rke2-metrics-server
check_deployment  kube-system rke2-snapshot-controller

echo ""
echo "--- default namespace ---"
check_deployment  default minio-operator
check_statefulset default myminio-pool-test
check_deployment  default nessie
check_deployment  default superset
check_statefulset default superset-postgresql
check_statefulset default superset-redis-master
check_deployment  default superset-worker
check_deployment  default trino-coordinator
check_deployment  default trino-worker

echo ""
echo "--- logging ---"
check_statefulset logging opensearch-cluster-master
check_deployment  logging opensearch-dashboards

echo ""
echo "--- monitoring ---"
check_daemonset   monitoring fluent-bit
check_statefulset monitoring loki

echo ""
echo "--- ranger ---"
check_deployment  ranger ranger-apache-ranger
check_statefulset ranger ranger-postgresql

echo ""
echo "--- spark-operator ---"
check_deployment  spark-operator spark-operator-controller
check_deployment  spark-operator spark-operator-webhook

echo ""
echo "--- nfs-provisioner ---"
check_deployment  nfs-provisioner nfs-provisioner-nfs-subdir-external-provisioner

echo ""
echo "=== Results ==="
echo "PASS: $PASS   FAIL: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "All services healthy."
else
  echo "WARNING: $FAIL service(s) not ready — investigate before declaring upgrade complete."
  exit 1
fi
