#!/bin/bash
# Run this to verify the full stack is healthy

echo "=== Pod Status ==="
kubectl get pods -n monitoring

echo ""
echo "=== PVC Status ==="
kubectl get pvc -n monitoring

echo ""
echo "=== Prometheus Targets ==="
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF=$!
sleep 2
UP=$(curl -s http://localhost:9090/api/v1/targets | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(len([t for t in d['data']['activeTargets'] if t['health']=='up']))
")
DOWN=$(curl -s http://localhost:9090/api/v1/targets | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(len([t for t in d['data']['activeTargets'] if t['health']!='up']))
")
echo "  UP:   $UP targets"
echo "  DOWN: $DOWN targets"
kill $PF 2>/dev/null

echo ""
echo "=== Active Alerts ==="
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &
PF=$!
sleep 2
curl -s http://localhost:9093/api/v2/alerts | python3 -c "
import json,sys
alerts=json.load(sys.stdin)
if not alerts: print('  No active alerts')
for a in alerts:
    print(f\"  {a['labels'].get('alertname','?')} [{a['labels'].get('severity','?')}]\")
"
kill $PF 2>/dev/null

echo ""
echo "=== Prometheus TSDB Stats ==="
PROM_POD=$(kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  promtool tsdb analyze /prometheus 2>/dev/null | head -20

echo ""
echo "=== Config Validation ==="
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  promtool check config /etc/prometheus/config_out/prometheus.env.yaml
