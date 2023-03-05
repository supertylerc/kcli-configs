# kcli-configs

This repo is a list of my non-sensitive kcli configs.  Use at
your own risk, no warranty, implied or otherwise, etc. etc. etc.  Ya
know, the usual run-of-the-mill Open Source thing.

## config.yml

You probably don't want/need anything in this.  It's my remote target
configs.

## k3s-plan.yml

This is a plan to create multiple k3s clusters.  You should probably
replace the clusters (i.e., the top-level keys other than `.parameters`)
as well adjust any default values in `.parameters`.  In the individual
cluster configs (i.e., anywhere that is `.*.type: kube`), you should
probalby change the `.nets[]` value to attach the cluster to your
specific libvirt networks.  If you only have one libvirt network, you
can put that in `.parameters.network` and remove the `.*.nets[]` field
completely.

By default, you will get a k3s cluster with the following attributes:
* 6GB RAM
* 4 CPU
* 50GB thin-provisioned disk
* 1 controller node
* 0 worker nodes (the controller will double as a controller)
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
