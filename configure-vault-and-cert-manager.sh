#!/usr/bin/env bash

set -eu -o pipefail

## Wait for vault to be ready
kubectl -n vault wait --for=condition=Ready pod -l app.kubernetes.io/name=vault --timeout=10m

# get the tls ca cert from the cluster
kubectl -n vault get secret vault-server-tls -o jsonpath="{.data['ca\.crt']}" | base64 --decode > vault-server-tls-ca.crt

# port forward to vault and add trap to kill the port forward
kubectl -n vault port-forward svc/vault 8123:8200 &
VAULT_PORT_FORWARD_PID=$!
trap 'kill $VAULT_PORT_FORWARD_PID' EXIT

# wait for port forward to be ready
sleep 5

export VAULT_TOKEN=vault-root-token
export VAULT_ADDR=https://127.0.0.1:8123
export VAULT_CACERT=$(pwd)/vault-server-tls-ca.crt

vault secrets enable -path=internal kv-v2 || true

## PKI
vault secrets enable pki || true
vault secrets tune -max-lease-ttl=8760h pki
vault write pki/root/generate/internal \
    common_name=cluster.local \
    ttl=8760h
vault write pki/config/urls \
    issuing_certificates="https://vault.vault.svc.cluster.local:8200/v1/pki/ca" \
    crl_distribution_points="https://vault.vault.svc.cluster.local:8200/v1/pki/crl"
vault write pki/roles/cluster-local \
    allowed_domains=cluster.local \
    allow_subdomains=true \
    max_ttl=72h

## create PKI policy
vault policy write pki - <<EOF
path "pki*"                         { capabilities = ["read", "list"] }
path "pki/root/sign-intermediate"   { capabilities = ["create", "update"] }
path "pki/sign/cluster-local"       { capabilities = ["create", "update"] }
EOF

## Kube Auth
vault auth enable kubernetes || true
vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc.cluster.local"

vault write auth/kubernetes/role/vault-sa \
    bound_service_account_names=* \
    bound_service_account_namespaces=* \
    policies=pki \
    ttl=20m

kubectl -n cert-manager create serviceaccount vault-sa || true
VAULT_SA_SECRET_REF="$(kubectl get secrets -n cert-manager --output=json | jq -r '.items[].metadata | select(.name|startswith("vault-sa-")).name')"
if [ -z "$VAULT_SA_SECRET_REF" ]; then
    kubectl -n cert-manager create -f vault-sa-secret.yaml
fi
VAULT_SA_SECRET_REF="$(kubectl get secrets -n cert-manager --output=json | jq -r '.items[].metadata | select(.name|startswith("vault-sa-")).name')"

cat > vault-yaml/vault-clusterissuer.yaml <<EOF
#### THIS FILE GENERATED BY SCRIPT configure-vault-and-cert-manager.sh ####
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-clusterissuer
spec:
  vault:
    server: https://vault.vault.svc.cluster.local:8200
    path: pki/root/sign-intermediate
    caBundle: "$(cat vault-server-tls-ca.crt | base64 | tr -d '\n')"
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: vault-sa
        secretRef:
          name: "$VAULT_SA_SECRET_REF"
          key: token
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-apps-clusterissuer
spec:
  vault:
    server: https://vault.vault.svc.cluster.local:8200
    path: pki/sign/cluster-local
    caBundle: "$(cat vault-server-tls-ca.crt | base64 | tr -d '\n')"
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: vault-sa
        secretRef:
          name: "$VAULT_SA_SECRET_REF"
          key: token
EOF

kubectl get ns linkerd || kubectl create ns linkerd
kubectl apply --server-side -f vault-yaml
kubectl wait -n linkerd --for=condition=Ready cert linkerd-identity-issuer
