set -e
set -x

echo -n "PiHole IP: "
read PIHOLE_IP

echo -n "PiHole Password: "
read -s PIHOLE_PASSWORD

# Create the namespace for our external-dns system
kubectl create namespace external-dns
# The Pi-Hole provider needs a password, so create it as a secret to be
# referenced later
kubectl create secret generic \
    pihole-password \
    --from-literal EXTERNAL_DNS_PIHOLE_PASSWORD="${PIHOLE_PASSWORD}" \
    --namespace external-dns

# Create the ServiceAccount, ClusterRole, ClusterRoleBinding, and
# Deployment for external-dns with a Pi-Hole provider.
cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-dns
  namespace: external-dns
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-dns
rules:
- apiGroups: [""]
  resources: ["services","endpoints","pods"]
  verbs: ["get","watch","list"]
- apiGroups: ["extensions","networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get","watch","list"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-dns-viewer
  namespace: external-dns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: external-dns
subjects:
- kind: ServiceAccount
  name: external-dns
  namespace: external-dns
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
  namespace: external-dns
spec:
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: external-dns
  template:
    metadata:
      labels:
        app: external-dns
    spec:
      serviceAccountName: external-dns
      containers:
      - name: external-dns
        image: registry.k8s.io/external-dns/external-dns:v0.13.2
        envFrom:
        - secretRef:
            name: pihole-password
        args:
        # Create records for service and ingress objects
        - --source=service
        - --source=ingress
        # Pihole only supports A/CNAME records so there is no mechanism to track ownership.
        # You don't need to set this flag, but if you leave it unset, you will receive warning
        # logs when ExternalDNS attempts to create TXT records.
        - --registry=noop
        # IMPORTANT: If you have records that you manage manually in Pi-hole, set
        # the policy to upsert-only so they do not get deleted.
        - --policy=upsert-only
        - --provider=pihole
        - --pihole-server=http://$PIHOLE_IP
      securityContext:
        fsGroup: 65534 # For ExternalDNS to be able to read Kubernetes token files
EOF
