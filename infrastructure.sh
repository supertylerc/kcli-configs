#!/bin/bash
set -e
set -x

# Make sure we have the tools we need
tools=(cilium istioctl helm)
for tool in "${tools}"; do
    if ! which "${tool}" > /dev/null; then
        echo "Unable to find ${tool}, you should install it.  Bye."
        exit 1
    fi
done

# Ensure the user has an opportunity to bail out.
echo "Attention!  This uses whatever kube context you're presently on!"
echo $(kubectl config current-context)
echo "If the above is not where you want to make changes, you have 10"
echo "seconds to cancel with ctrl-c (^c)!  After 10 seconds, changes"
echo "will proceed automatically."
sleep 10

# Ensure $KUBECONFIG is not group- or world-readable to cut down noise.
chmod o-r $KUBECONFIG
chmod g-r $KUBECONFIG

# Add the Helm Repos
## Cilium
helm repo add cilium https://helm.cilium.io
## Nginx Ingress
helm repo add nginx-stable https://helm.nginx.com/stable
## MetalLB
helm repo add metallb https://metallb.github.io/metallb
## Prom Op
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
## Loki
helm repo add grafana https://grafana.github.io/helm-charts
## Longhorn for storage
helm repo add longhorn https://charts.longhorn.io
## Update Helm repo adds
helm repo update

# Cilium
## Install Cilium (our CNI of choice)
helm upgrade --install cilium \
  cilium/cilium \
  --namespace kube-system \
  --wait \
  --values - <<EOF
kubeProxyReplacement: strict
hostServices:
  enabled: true
externalIPs:
  enabled: true
nodePort:
  enabled: true
hostPort:
  enabled: true
image:
  pullPolicy: IfNotPresent
ipam:
  mode: kubernetes
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
operator:
  replicas: 1
EOF

## Validate Cilium is working and delete the test pods afterward
cilium connectivity test
cilium status
kubectl delete ns cilium-test

# Istio
## Install istiod
if ! kubectl get deploy -n istio-system istiod > /dev/null; then
    istioctl install --skip-confirmation --set profile=minimal
fi

# Install the Standard Applications
## Install Longhorn for storage
helm upgrade --install longhorn \
    longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace

## Install Prometheus Operator for time series data
### TODO: Customize PromOp further
echo -n "Grafana admin password: "
read -s GRAFANA_ADMIN_PASSWORD
helm upgrade --install prom-op \
    prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --values - <<EOF
grafana:
  adminPassword: $GRAFANA_ADMIN_PASSWORD
EOF

## Install Loki for log aggregation
### TODO: Customize Loki
helm upgrade --install loki \
    grafana/loki-stack \
    --namespace=loki-stack \
    --create-namespace

## Install MetalLB
### Set the MetalLB IP Range
echo -n "MetalLB IP Range: "
read METALLB_IP_RANGE
### TODO: Figure out why it needs to install twice.
### For some reason, this chart's Prometheus settings result in the
### following error:
### Error: roles.rbac.authorization.k8s.io "metallb-prometheus" already exists
### Running the install a second time is successful.
(
helm upgrade --install metallb metallb/metallb \
    --namespace metallb-system \
    --create-namespace\
    --wait \
    --values - <<EOF
prometheus:
  podMonitor:
    enabled: true
  prometheusRule:
    enabled: true
  serviceMonitor:
    enabled: true
  serviceAccount: prom-metallb
  namespace: monitoring
EOF
) || true
helm upgrade --install metallb metallb/metallb \
    --namespace metallb-system \
    --create-namespace\
    --wait \
    --values - <<EOF
prometheus:
  podMonitor:
    enabled: true
  prometheusRule:
    enabled: true
  serviceMonitor:
    enabled: true
  serviceAccount: prom-metallb
  namespace: monitoring
EOF

### The --wait should result in this always being ready, but we need to
### be 100% certain the pod is ready before we create the CR to set the
### IPs for our LoadBalancer or the CR will fail the validatingwebhook.
while kubectl get deploy -n metallb-system metallb-controller -o jsonpath='{.status.readyReplicas}' | grep 0 > /dev/null; do
    sleep 1
done

### Create the IP Address Pool CR for MetalLB to hand out IPs
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: primary-pool
  namespace: metallb-system
spec:
  addresses:
    - $METALLB_IP_RANGE
EOF
### Create the L2Advertisement for the above pool so that MetalLB will
### respond to ARP requests (it won't respond to ARP without this,
### resulting in a broken LoadBalancer!)
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: primary-pool-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - primary-pool
EOF

## Install the nginx ingress controller
helm upgrade --install nginx-ingress \
    nginx-stable/nginx-ingress \
    --set controller.setAsDefaultIngress=true \
    --set controller.enableLatencyMetrics=true \
    --set controller.autoscaling.enabled=true \
    --set prometheus.create=true \
    --namespace nginx-ingress \
    --create-namespace \
    --wait

# Reconfigure systems that depend on CRDs that were deployed previously
# (e.g., Ingress, Prometheus Operator, etc.)
## Create the Ingress for Hubble
## Configure Prometheus monitoring for all Cilium components
echo -n "Hubble UI Ingress Host: "
read HUBBLE_UI_HOST
helm upgrade --install cilium \
  cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --values - <<EOF
hubble:
  ui:
    ingress:
      enabled: true
      annotations:
        kubernetes.io/ingress.class: nginx
      hosts:
        - $HUBBLE_UI_HOST
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true
operator:
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true
prometheus:
  enabled:
    true
  serviceMonitor:
    enabled: true
EOF

## Create the Ingress for Grafana
echo -n "Grafana Ingress Host: "
read GRAFANA_INGRESS_HOST
helm upgrade --install prom-op \
    prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --reuse-values \
    --values - <<EOF
grafana:
  ingress:
    enabled: true
    path: "/"
    hosts:
      - $GRAFANA_INGRESS_HOST
    annotations:
      kubernetes.io/ingress.class: nginx
EOF
