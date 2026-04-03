#!/bin/bash
# CT-FAC Crew Deploy
# Uses msi01 MAL as primary model provider (local fleet first)
# Falls back to Anthropic if ANTHROPIC_KEY is set
set -e

NS=${NAMESPACE:-eose-entry}
GATEWAY_TOKEN=ct-fac-eose-2026
MAL_URL=${MAL_URL:-http://192.168.2.18:9334}
ANTHROPIC_KEY=${ANTHROPIC_KEY:-}

echo "📦 Deploying CT-FAC crew to: $NS"
echo "🔗 MAL: $MAL_URL"

# Config with MAL as primary
kubectl create configmap ct-gateway-config -n $NS \
  --from-literal=openclaw.json="{
    \"gateway\": {
      \"mode\": \"local\", \"bind\": \"lan\",
      \"auth\": {\"mode\": \"token\"},
      \"port\": 18830,
      \"controlUi\": {\"dangerouslyAllowHostHeaderOriginFallback\": true}
    },
    \"models\": {
      \"default\": \"mal/default\",
      \"providers\": {
        \"mal\": {
          \"baseUrl\": \"${MAL_URL}\",
          \"apiKey\": \"mal-local\",
          \"models\": [{\"id\": \"default\", \"name\": \"MAL Fleet Router\", \"maxTokens\": 8192}]
        }
      }
    },
    \"agents\": {
      \"defaults\": {\"workspace\": \"/root/.openclaw/workspace\", \"skipBootstrap\": true},
      \"list\": [{\"id\": \"ct-fac\", \"default\": true, \"workspace\": \"/root/.openclaw/workspace\"}]
    }
  }" --dry-run=client -o yaml | kubectl apply -f -

# Auth — MAL key only, Anthropic optional
AUTH_PROFILES="{\"version\":1,\"profiles\":{\"mal:default\":{\"type\":\"api_key\",\"provider\":\"mal\",\"key\":\"mal-local\"}"
if [ -n "$ANTHROPIC_KEY" ]; then
  AUTH_PROFILES="${AUTH_PROFILES},\"anthropic:default\":{\"type\":\"api_key\",\"provider\":\"anthropic\",\"key\":\"${ANTHROPIC_KEY}\"}"
fi
AUTH_PROFILES="${AUTH_PROFILES}}}"

kubectl create secret generic ct-gateway-auth -n $NS \
  --from-literal=auth-profiles.json="$AUTH_PROFILES" \
  --dry-run=client -o yaml | kubectl apply -f -

# Deployment
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
