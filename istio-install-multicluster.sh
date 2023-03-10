#!/bin/bash
set -e
set -x
# Make sure we have the tools we need
tools=(helm)
for tool in "${tools}"; do
    if ! which "${tool}" > /dev/null; then
        echo "Unable to find ${tool}, you should install it.  Bye."
        exit 1
    fi
done
echo $CLUSTER_NAMES
# Add the Istio repo
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# Grab the latest Istio tarball to make certs more easily
curl -L https://istio.io/downloadIstio | sh -
pushd istio-1*
mkdir certs
pushd certs
# Make the root CA
make -f ../tools/certs/Makefile.selfsigned.mk root-ca
# Split the CLUSTER_NAMES env var into a shell list
cluster_names_array=(${CLUSTER_NAMES//,/ })
for cluster in "${cluster_names_array[@]}"; do
    # Create the intermediate CA certs
    make -f ../tools/certs/Makefile.selfsigned.mk $cluster-cacerts
    # Set the right kubectl config
    export KUBECONFIG=$HOME/.kcli/clusters/$cluster/auth/kubeconfig
    # Create the namespace where Istio will be installed
    kubectl create namespace istio-system
    # Create the secret that will contain certs for Istio to use
    ls -alhR
    kubectl create secret generic \
        cacerts \
        -n istio-system \
        --from-file=$cluster/ca-cert.pem \
        --from-file=$cluster/ca-key.pem \
        --from-file=$cluster/root-cert.pem \
        --from-file=$cluster/cert-chain.pem
    # Set the network name
    kubectl label namespace \
        istio-system \
        topology.istio.io/network=$cluster
    # Install CRDs
    helm upgrade --install istio-base \
        istio/base \
        --namespace istio-system \
        --wait
    # Install istiod with multi-cluster config
    helm upgrade --install istiod \
        istio/istiod \
        --namespace istio-system \
        --wait \
	--values - <<EOF
global:
  meshID: mc-mesh
  multiCluster:
    enabled: true
    clusterName: $cluster
  network: $cluster
EOF
done
popd
popd
[ ! -z ${ISTIO_CERT_DIR+x} ] && mv istio-1*/certs $ISTIO_CERT_DIR || true
