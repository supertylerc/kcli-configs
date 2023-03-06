# kcli-configs

This repo is a list of my non-sensitive kcli configs.  Use at
your own risk, no warranty, implied or otherwise, etc. etc. etc.  Ya
know, the usual run-of-the-mill Open Source thing.

> This repo is tested with libvirt networks that use a bridge and are
> configured with a forwarding mode of `route`.  However, it should work
> with any libvirt network that is not NAT or Isolated (i.e., you can
> communicate with the VMs' IP addresses directly from your laptop).
> Additionally, this repo assumes that you're creating your libvirt
> networks outside of `kcli`.  This is because `kcli` doesn't support
> creating libvirt networks that are routed.

## config.yml

You probably don't want/need anything in this.  It's my remote target
configs.

## k3s-plan.yml

This is a plan to create multiple k3s clusters.  You should probably
replace the clusters (i.e., the top-level keys other than `.parameters`)
as well adjust any default values in `.parameters`.  In the individual
cluster configs (i.e., anywhere that is `.*.type: kube`), you should
probalby change the `.nets[]` and `.network value to attach the cluster
to your specific libvirt networks.  If you only have one libvirt
network, you can put that in `.parameters.network`.

> I'm not sure yet if `.nets[]` works in a `.type=kube`, so this param
> might be redundant.

By default, you will get a k3s cluster with the following attributes:
* RAM
  * Control Plane: 2GB
  * Worker Node: 4GB
  * Note: If only 1 node cluster, 6GB RAM is recommended
* CPU
  * Control Plane: 1
  * Worker Node: 2
  * Note: If only 1 node cluster, 4 CPUs are recommended
* 50GB thin-provisioned disk
* kcli controller/worker defaults
  * Two clusters exist in this repo that override this to 1/2 ctl/wrk
* Ubuntu 22.04 (for cgroupsv2 goodness)
* `helm`, `istioctl`, and `cilium` installed
* BPF settings necessary for running Cilium configured
* snapd completely disabled/removed
  * Seems like a weird callout, but in my clusters snapd was eating CPU
    like crazy despite not using it for anything
* cgroupsv1 completely disabled (you will need to reboot)
* The following changes to the default k3s install:
  * traefik disabled (I use nginx later)
  * servicelb disabled (I use metallb later)
  * flannel disabled (I use Cilium later)
  * networkpolicy disabled (Cilium will do networkpolicy later)

To create your cluster(s), run:

```bash
$ kcli create plan -f k3s-plan.yml
```

Once your cluster is created, log into every node and reboot the node to
ensure cgroupsv1 is completely disabled.

> I'm not _entirely_ sure if this is necessary in Ubuntu 22.04, but
> we're replacing kube-proxy, and for Cilium to _completely_ replace
> kube-proxy, there can be no support for cgroupsv1 in the kernel at
> all.

At this point, you will have Kubernetes clusters, but no pods will come
because there will be no CNI.  We solve this in the next step by running
the `cluster-infra-workflow-plan.yml` plan against each cluster.

## cluster-infra-workflow-plan.yml

This plan is just a workflow that executes the following scripts:

* infrastructure.sh
* pihole.sh

> Remove pihole.sh if you don't have Pi-Hole

In order to run this workflow, you must have the following CLI tools installed:

* kubectl
* cilium
* istioctl
* helm

To install them on Linux (verified on Ubuntu):

```bash
# kubectl
sudo apt-get update
sudo apt-get install -y ca-certificates curl apt-transport-https
sudo curl -fsSLo /etc/apt/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubectl

# Cilium
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# istioctl
curl -L https://istio.io/downloadIstio | sh -

# helm
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
sudo apt-get install apt-transport-https --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm
```

Run this plan with:

```bash
$ kcli create plan -f cluster-infra-workflow-plan.yml
```

This plan will do the following:

* install Cilium with Hubble enabled for CNI (verified)
* run Cilium's connectivity tests, which test actual data plane flow
  and NetworkPolicy enforcement (verified)
* install istiod for service mesh (currently unverified)
* install longhorn for storage (currently unverified)
* install Prometheus Operator for time series monitoring (verified)
* install Loki for log aggregation (currently unverified)
* install MetalLB for implementing the Kubernetes LoadBalancer service
  type (verified)
* install nginx as an ingress controller (verified)
* update Cilium deployment to enable Prometheus scraping
* update Cilium deployment to expose Hubble UI behind an Ingress
* update Prometheus Operator deployment to expose Grafana behind an
  Ingress
* Create an external-dns deployment with Pi-Hole as a provider
  * You must have an existing Pi-Hole server for this

At various points, this plan will ask you for some inputs:

* The IP range for MetalLB LoadBalancer IPs
  * This must be the within the same subnet as your Kubernetes cluster's
    node addresses and outside of a DHCP scope (or be familiar with how
    to deal with DHCP and Static IP collisions)
    * For example, if your worker node's IP is `192.0.2.37/24`, then you
      must specific a range within `192.0.2.0/24` for your MetalLB IP
      Range.  You would specify this as, for example,
      `192.0.2.140-192.0.2.150` when prompted.
* The Grafana admin password
* The Grafana ingress hostname (e.g., `grafana.k3s.local`)
* The Hubble UI ingress hostname (e.g., `hubble.k3s.local`)
* Your Pi-Hole server's IP address
  * This IP must be accessible by the Kubernetes cluster
* Your Pi-Hole server's Pi-Hole password

> If you're not using Pi-Hole, edit the plan and remove the reference to
> the script.  You won't get automagic DNS for your Ingress objects in
> this case.

After your cluster is created and the infrastructure plan is run, you
should be able to log into Grafana and see the cluster CPU, memory,
disk, etc. utilization via the default dashboards.  You should be able
to visit `$GRAFANA_INGRESS_HOST` to see this if you're using a Pi-Hole.
Additionally, you can see a mapping of network flows within your cluster
by visiting `http://HUBBLE_UI_HOST`.
