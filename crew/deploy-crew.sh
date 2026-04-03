#!/bin/bash
# CT-FAC Crew Deploy — tested on aks-eose-aaas-dev 2026-04-02
# Reads Anthropic key from local openclaw config — no copy-paste needed
# Usage: bash deploy-crew.sh
set -e

NS=${NAMESPACE:-eose-entry}
GATEWAY_TOKEN=ct-fac-eose-2026

# Pull key from local openclaw config
if command -v node &>/dev/null; then
  ANTHROPIC_KEY=$(node -e "
    const fs=require('fs');
    const cfg=JSON.parse(fs.readFileSync(process.env.HOME+'/.openclaw/openclaw.json','utf8'));
    process.stdout.write(cfg.models.providers.anthropic.apiKey);
  " 2>/dev/null)
fi

if [ -z "$ANTHROPIC_KEY" ]; then
  echo "ERROR: Could not read key from ~/.openclaw/openclaw.json"
  echo "Set ANTHROPIC_KEY env var manually and re-run"
  exit 1
fi

echo "✅ Key found (${#ANTHROPIC_KEY} chars)"
echo "📦 Deploying to namespace: $NS"

# 1. Auth secret
kubectl create secret generic ct-gateway-auth -n $NS \
  --from-literal=auth-profiles.json="{\"version\":1,\"profiles\":{\"anthropic:default\":{\"type\":\"api_key\",\"provider\":\"anthropic\",\"key\":\"${ANTHROPIC_KEY}\"}}}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "✅ Auth secret"

# 2. Config map
kubectl create configmap ct-gateway-config -n $NS \
  --from-literal=openclaw.json='{
    "gateway": {
      "mode": "local", "bind": "lan",
      "auth": {"mode": "token"},
      "port": 18830,
      "controlUi": {"dangerouslyAllowHostHeaderOriginFallback": true}
    },
    "agents": {
      "defaults": {"workspace": "/root/.openclaw/workspace", "skipBootstrap": true},
      "list": [{"id": "ct-fac", "default": true, "workspace": "/root/.openclaw/workspace"}]
    }
  }' --dry-run=client -o yaml | kubectl apply -f -
echo "✅ Config map"

# 3. Deployment + Service
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ct-builder-gateway
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ct-builder-gateway
  template:
    metadata:
      labels:
        app: ct-builder-gateway
    spec:
      automountServiceAccountToken: false
      containers:
      - name: gateway
        image: eoseentry.azurecr.io/openclaw:latest
        command:
        - sh
        - -c
        - |
          mkdir -p /root/.openclaw/agents/ct-fac/agent /root/.openclaw/workspace
          cp /config/openclaw.json /root/.openclaw/openclaw.json
          cp /auth/auth-profiles.json /root/.openclaw/agents/ct-fac/agent/auth-profiles.json
          openclaw gateway run
        env:
        - name: OPENCLAW_GATEWAY_TOKEN
          value: "$GATEWAY_TOKEN"
        ports:
        - containerPort: 18830
        resources:
          requests: {cpu: 100m, memory: 256Mi}
          limits: {cpu: 500m, memory: 512Mi}
        volumeMounts:
        - name: config
          mountPath: /config
        - name: auth
          mountPath: /auth
        - name: workspace
          mountPath: /root/.openclaw/workspace
      volumes:
      - name: config
        configMap:
          name: ct-gateway-config
      - name: auth
        secret:
          secretName: ct-gateway-auth
      - name: workspace
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ct-builder-gateway
  namespace: $NS
spec:
  selector:
    app: ct-builder-gateway
  ports:
  - port: 18830
    targetPort: 18830
EOF

kubectl rollout restart deployment/ct-builder-gateway -n $NS
kubectl rollout status deployment/ct-builder-gateway -n $NS --timeout=90s

echo ""
echo "🎉 CT-FAC crew live!"
echo "   kubectl port-forward svc/ct-builder-gateway 18830:18830 -n $NS"
echo "   http://localhost:18830/chat?session=main&token=$GATEWAY_TOKEN"
