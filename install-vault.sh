#!/usr/bin/env bash

# Source: https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-minikube-raft

## Enable cert-manager
helm upgrade cert-manager jetstack/cert-manager \
  --install \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait

kubectl apply --server-side -f ./vault-server-tls.yaml

helm repo add hashicorp https://helm.releases.hashicorp.com
# helm repo update
helm upgrade vault hashicorp/vault \
  --install \
  --namespace vault \
  --values helm-vault-values.yaml \
  --wait

## Wait for pods to be running
kubectl -n vault wait --for=condition=Ready pod -l app.kubernetes.io/name=vault --timeout=10m
