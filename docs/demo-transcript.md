# `lab demo` transcript

Captured from a real interactive run of `scripts/ssm.sh demo` on the air-gapped lab node (Zarf v0.88.0, Longhorn
1.12.1 → 1.13.0, about 15 minutes). Output is verbatim except the S3 bucket name and node IP, which are
replaced with placeholders. Long Zarf logs are collapsed.

```console
==> Versions: install 1.12.1 -> upgrade 1.13.0

Longhorn x Zarf live demo: install 1.12.1, GitOps app, upgrade to 1.13.0
  Tip: on your laptop, scripts/ssm.sh ui (Longhorn UI :8080) and scripts/ssm.sh podinfo (:9898)
```

## Step 1: Proof: this node is air-gapped

The VPC route table has no internet route. GitHub, Docker Hub, GHCR and the Longhorn chart repo are unreachable; only AWS SSM and S3 VPC endpoints remain.

```console
$ lab airgap-check
  blocked    https://github.com
  blocked    https://registry-1.docker.io/v2/
  blocked    https://ghcr.io/v2/
  blocked    https://charts.longhorn.io
  blocked    https://archive.ubuntu.com
  reachable  s3://jdoe-longhorn-zarf-airgap-lab-xxxxxxxx (VPC gateway endpoint)

==> AIR-GAPPED: no internet access
```

## Step 2: The air-gapped starting point

Single-node K3s initialized by Zarf: an in-cluster registry, Gitea, and the Zarf agent, which rewrites image and git references to point at them.

```console
$ kubectl get nodes; zarf package list
NAME             STATUS   ROLES           AGE   VERSION        INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION   CONTAINER-RUNTIME
ip-10-250-0-10   Ready    control-plane   12m   v1.34.3+k3s1   10.250.0.10   <none>        Ubuntu 24.04.5 LTS   7.0.0-1014-aws   containerd://2.1.5-k3s1
2026-10-19 14:24:56 INF waiting for cluster connection

     Package | Namespace Override | Version | Connectivity | Components
     init    |                    | v0.88.0 | airgap       | [k3s zarf-injector zarf-seed-registry zarf-registry zarf-agent git-server]

NAME                                    READY   STATUS    RESTARTS   AGE
agent-hook-64f6676b9d-c9s4b             1/1     Running   0          11m
agent-hook-64f6676b9d-rm78q             1/1     Running   0          11m
zarf-docker-registry-786d6455b5-72vnr   1/1     Running   0          12m
zarf-gitea-8447d49f74-8sp2p             1/1     Running   0          11m
```

## Step 3: What's inside the Longhorn package

One self-contained archive: the chart, every image, longhornctl, and lifecycle hooks (preflight install/check, readiness via longhornctl diagnose, V2 disk registration, safe uninstall).

```console
$ zarf package inspect definition|images zarf-package-longhorn-lab-amd64-1.12.1.tar.zst
component: longhorn-preflight
files:
  - /usr/local/bin/longhornctl
deployHooks:
  - longhornctl install preflight (V1 + V2/SPDK prerequisites)
  - Wait for API server and hugepages-2Mi to be advertised after the kubelet restart
  - longhornctl check preflight (exits 0 even on failure, so grep the per-node error list)
  - Declare Longhorn default disks on the node (V1 /var/lib/longhorn + V2 raw block disk)
removeHooks:
  - Delete longhorn-system (Zarf leaves namespaces behind)
component: longhorn-diagnose
files:
  - /usr/local/bin/longhornctl-diagnose
deployHooks: []
removeHooks: []
component: longhorn
files: []
deployHooks:
  - Longhorn readiness (longhornctl diagnose if present, else Zarf waits)
  - Wait for the V2 block disk (created from the node annotation; patched in if the node already had disks, e.g. after a Helm takeover)
  - Make longhorn-v2 the only default StorageClass (K3s marks local-path as default)
removeHooks:
  - Refuse to uninstall while Longhorn volumes exist (set LAB_FORCE_REMOVE=true to override)
  - Allow the chart's pre-delete uninstall job to proceed
  - Restore local-path as the default StorageClass
  - Optionally wipe host disks (LAB_WIPE_DISKS=true)

- longhornio/longhorn-cli:v1.12.1
- longhornio/backing-image-manager:v1.12.1
- longhornio/longhorn-engine:v1.12.1
- longhornio/longhorn-instance-manager:v1.12.1
- longhornio/longhorn-manager:v1.12.1
- longhornio/longhorn-share-manager:v1.12.1
- longhornio/longhorn-ui:v1.12.1
- longhornio/csi-attacher:v4.12.0
- longhornio/csi-provisioner:v5.3.0
- longhornio/csi-resizer:v2.2.1
- longhornio/csi-snapshotter:v8.6.0
- longhornio/csi-node-driver-registrar:v2.17.0
- longhornio/livenessprobe:v2.19.0
- longhornio/support-bundle-kit:v0.0.92
```

## Step 4: Install Longhorn 1.12.1

Zarf pushes the images to its registry, runs longhornctl install/check preflight (V1 + V2/SPDK), installs the chart, then blocks until longhornctl diagnose reports healthy.

```console
$ zarf package deploy zarf-package-longhorn-lab-amd64-1.12.1.tar.zst --confirm
```

<details><summary>Output (584 lines)</summary>

```console
==> zarf package deploy longhorn-lab 1.12.1
2026-10-19 14:26:45 WRN package signature not verified; continuing reason=package is not signed - verification cannot be performed: no verification material available

kind: ZarfPackageConfig
metadata:
  name: longhorn-lab
  description: Longhorn
  version: 1.12.1
  architecture: amd64
  aggregateChecksum: 1e973add6598bb14f001dba96b553a342e953297a50bc4a3ca74a1326f9f2c20
  allowNamespaceOverride: true
build:
  architecture: amd64
  timestamp: Mon, 19 Oct 2026 14:13:52 +0000
  version: v0.88.0
  migrations:
  - scripts-to-actions
  - pluralize-set-variable
  signed: false
  provenanceFiles:
  - checksums.txt
components:
- name: longhorn-preflight
  required: true
  manifests:
  - name: longhorn-namespace
    namespace: longhorn-system
    files:
    - manifests/lab-marker.yaml
    template: false
  files:
  - source: https://github.com/longhorn/cli/releases/download/v1.12.1/longhornctl-linux-amd64
    target: /usr/local/bin/longhornctl
    executable: true
    template: false
  images:
  - longhornio/longhorn-cli:v1.12.1
  actions:
    onDeploy:
      defaults:
        maxTotalSeconds: 1800
        shell:
          linux: bash
      after:
      - cmd: "set -euo pipefail\nexport KUBECONFIG=\"${KUBECONFIG:-/root/.kube/config}\"\n# On K3s the kubelet restart also restarts the API server, so the first run may lose\n# its connection. The installer is idempotent: wait for the API and retry.\nfor attempt in 1 2 3; do\n  if /usr/local/bin/longhornctl install preflight \\\n    --image longhornio/longhorn-cli:v1.12.1 \\\n    --enable-spdk --huge-page-size 2048 --spdk-options PERSIST_HUGE=yes \\\n    --restart-kubelet --restart-kubelet-window 10s; then\n    exit 0\n  fi\n  echo \"install preflight attempt $attempt failed; waiting for API server\" >&2\n  sleep 15\n  for i in $(seq 1 60); do\n    ./zarf tools kubectl get --raw=/readyz >/dev/null 2>&1 && break\n    sleep 5\n  done\ndone\nexit 1\n"
        description: longhornctl install preflight (V1 + V2/SPDK prerequisites)
        template: false
      - cmd: "set -euo pipefail\nexport KUBECONFIG=\"${KUBECONFIG:-/root/.kube/config}\"\nfor i in $(seq 1 90); do\n  if hp=$(./zarf tools kubectl get nodes -o jsonpath='{.items[0].status.allocatable.hugepages-2Mi}' 2>/dev/null) \\\n     && [[ -n \"$hp\" && \"$hp\" != \"0\" ]]; then\n    echo \"hugepages-2Mi allocatable: $hp\"; exit 0\n  fi\n  sleep 5\ndone\necho \"hugepages-2Mi never became allocatable\" >&2; exit 1\n"
        description: Wait for API server and hugepages-2Mi to be advertised after the kubelet restart
        template: false
      - cmd: "set -euo pipefail\nexport KUBECONFIG=\"${KUBECONFIG:-/root/.kube/config}\"\nout=$(/usr/local/bin/longhornctl check preflight \\\n  --image longhornio/longhorn-cli:v1.12.1 \\\n  --enable-spdk --huge-page-size 2048 2>&1)\necho \"$out\"\nif grep -qE '^  error:' <<<\"$out\"; then\n  echo \"longhornctl check preflight reported errors\" >&2; exit 1\nfi\n"
        description: longhornctl check preflight (exits 0 even on failure, so grep the per-node error list)
        template: false
      - cmd: "set -euo pipefail\nexport KUBECONFIG=\"${KUBECONFIG:-/root/.kube/config}\"\n# Used by create-default-disk-labeled-nodes only while the Longhorn node has no disks,\n# i.e. on first install. Upgrades leave existing disks alone.\ndisks='[{\"path\":\"/var/lib/longhorn\",\"allowScheduling\":true}'\nif [[ -n \"${ZARF_VAR_V2_DISK_PATH:-}\" ]]; then\n  disks+=',{\"name\":\"v2disk\",\"path\":\"'\"$ZARF_VAR_V2_DISK_PATH\"'\",\"diskType\":\"block\",\"diskDriver\":\"aio\",\"allowScheduling\":true}'\nfi\ndisks+=']'\nnode=$(./zarf tools kubectl get nodes -o jsonpath='{.items[0].metadata.name}')\n./zarf tools kubectl label node \"$node\" node.longhorn.io/create-default-disk=config --overwrite\n./zarf tools kubectl annotate node \"$node\" node.longhorn.io/default-disks-config=\"$disks\" --overwrite\n"
        description: Declare Longhorn default disks on the node (V1 /var/lib/longhorn + V2 raw block disk)
        template: false
    onRemove:
      defaults:
        shell:
          linux: bash
      after:
      - cmd: |
          set -euo pipefail
          if ./zarf tools kubectl get crd settings.longhorn.io >/dev/null 2>&1; then
            echo "Longhorn is still installed; remove the 'longhorn' component first" >&2; exit 1
          fi
          ./zarf tools kubectl delete namespace longhorn-system --ignore-not-found --wait=true --timeout=5m
        description: Delete longhorn-system (Zarf leaves namespaces behind)
        template: false
- name: longhorn-diagnose
  default: true
  required: false
  files:
  - source: bin/longhornctl-diagnose
    target: /usr/local/bin/longhornctl-diagnose
    executable: true
    template: false
- name: longhorn
  required: true
  manifests:
  - name: longhorn-lab-extras
    namespace: longhorn-system
    files:
    - manifests/storageclass-v2.yaml
    - manifests/connect.yaml
    template: false
  charts:
  - name: longhorn
    version: 1.12.1
    url: https://charts.longhorn.io
    namespace: longhorn-system
    releaseName: longhorn
    valuesFiles:
    - values-lab.yaml
    schemaValidation: true
  images:
  - longhornio/backing-image-manager:v1.12.1
  - longhornio/longhorn-engine:v1.12.1
  - longhornio/longhorn-instance-manager:v1.12.1
  - longhornio/longhorn-manager:v1.12.1
  - longhornio/longhorn-share-manager:v1.12.1
  - longhornio/longhorn-ui:v1.12.1
  - longhornio/csi-attacher:v4.12.0
  - longhornio/csi-provisioner:v5.3.0
  - longhornio/csi-resizer:v2.2.1
  - longhornio/csi-snapshotter:v8.6.0
  - longhornio/csi-node-driver-registrar:v2.17.0
  - longhornio/livenessprobe:v2.19.0
  - longhornio/support-bundle-kit:v0.0.92
  actions:
    onDeploy:
      defaults:
        shell:
          linux: bash
      after:
      - maxTotalSeconds: 1200
        cmd: |
          set -uo pipefail
          export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
          if [[ -x /usr/local/bin/longhornctl-diagnose ]]; then
            for i in $(seq 1 60); do
              if /usr/local/bin/longhornctl-diagnose diagnose; then exit 0; fi
              echo "diagnose not healthy yet (attempt $i), retrying in 15s"; sleep 15
            done
            exit 1
          fi
          set -e
          ./zarf tools wait-for resource daemonset longhorn-manager '{.status.numberReady}'=1 -n longhorn-system --timeout 10m
          ./zarf tools wait-for resource deployment longhorn-driver-deployer Available -n longhorn-system --timeout 10m
          ./zarf tools wait-for resource daemonset longhorn-csi-plugin '{.status.numberReady}'=1 -n longhorn-system --timeout 10m
          node=$(./zarf tools kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
          ./zarf tools wait-for resource nodes.longhorn.io "$node" '{.status.conditions[?(@.type=="Ready")].status}'=True -n longhorn-system --timeout 10m
        description: Longhorn readiness (longhornctl diagnose if present, else Zarf waits)
        template: false
      - maxTotalSeconds: 600
        cmd: "set -euo pipefail\nexport KUBECONFIG=\"${KUBECONFIG:-/root/.kube/config}\"\ndisk=\"${ZARF_VAR_V2_DISK_PATH:-}\"\nif [[ -z \"$disk\" ]]; then echo \"V2_DISK_PATH empty, skipping\"; exit 0; fi\nnode=$(./zarf tools kubectl get nodes -o jsonpath='{.items[0].metadata.name}')\npatch=\"{\\\"spec\\\":{\\\"disks\\\":{\\\"v2disk\\\":{\n    \\\"path\\\":\\\"$disk\\\",\\\"diskType\\\":\\\"block\\\",\\\"diskDriver\\\":\\\"aio\\\",\n    \\\"allowScheduling\\\":true,\\\"evictionRequested\\\":false,\\\"storageReserved\\\":0,\\\"tags\\\":[]}}}}\"\n# The Longhorn webhook rejects disk edits while disk spec/status is still syncing.\nfor i in $(seq 1 30); do\n  ./zarf tools kubectl -n longhorn-system patch nodes.longhorn.io \"$node\" --type merge -p \"$patch\" && break\n  [[ $i -eq 30 ]] && exit 1\n  sleep 10\ndone\n./zarf tools wait-for resource nodes.longhorn.io \"$node\" \\\n  '{.status.diskStatus.v2disk.conditions[?(@.type==\"Ready\")].status}'=True \\\n  -n longhorn-system --timeout 8m\n"
        description: Wait for the V2 block disk (created from the node annotation; patched in if the node already had disks, e.g. after a Helm takeover)
        template: false
      - cmd: |
          if ./zarf tools kubectl get storageclass local-path >/dev/null 2>&1; then
            ./zarf tools kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=false --overwrite
          fi
        description: Make longhorn-v2 the only default StorageClass (K3s marks local-path as default)
        template: false
    onRemove:
      defaults:
        shell:
          linux: bash
      before:
      - cmd: |
          set -euo pipefail
          n=$(./zarf tools kubectl get volumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null | wc -l)
          if [[ "$n" -gt 0 && "${LAB_FORCE_REMOVE:-false}" != "true" ]]; then
            ./zarf tools kubectl get volumes.longhorn.io -n longhorn-system
            echo "$n Longhorn volume(s) still exist; remove workloads/PVCs first" >&2; exit 1
          fi
        description: Refuse to uninstall while Longhorn volumes exist (set LAB_FORCE_REMOVE=true to override)
        template: false
      - cmd: "set -euo pipefail\n./zarf tools kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag \\\n  --type merge -p '{\"value\":\"true\"}'\n# The uninstall job reads the flag from an informer (apiserver watch cache), which can lag\n# behind the write, e.g. right after CRDs were deleted. Wait until the cached view agrees.\nurl=/apis/longhorn.io/v1beta2/namespaces/longhorn-system/settings/deleting-confirmation-flag?resourceVersion=0\nfor i in $(seq 1 30); do\n  ./zarf tools kubectl get --raw \"$url\" | grep -q '\"value\":\"true\"' && exit 0\n  sleep 2\ndone\necho \"deleting-confirmation-flag not visible in the watch cache\" >&2; exit 1\n"
        description: Allow the chart's pre-delete uninstall job to proceed
        template: false
      after:
      - cmd: |
          if ./zarf tools kubectl get storageclass local-path >/dev/null 2>&1; then
            ./zarf tools kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite
          fi
        description: Restore local-path as the default StorageClass
        template: false
      - cmd: "set -euo pipefail\n[[ \"${LAB_WIPE_DISKS:-false}\" == \"true\" ]] || exit 0\nsource /etc/longhorn-lab.env\nfind /var/lib/longhorn -mindepth 1 -maxdepth 1 -exec rm -rf {} +\n[[ -n \"${V2_DISK_PATH:-}\" ]] && wipefs -a \"$V2_DISK_PATH\" && \\\n  dd if=/dev/zero of=\"$V2_DISK_PATH\" bs=1M count=64 oflag=direct status=none\necho \"disks wiped\"\n"
        description: Optionally wipe host disks (LAB_WIPE_DISKS=true)
        template: false
variables:
- name: V2_DISK_PATH  currently set to '/dev/disk/by-id/n...'
  description: Raw block device registered as a V2 (SPDK aio) disk. Empty = skip.
- name: STORAGE_CLASS_REPLICAS  currently set to '1' (default)
  description: numberOfReplicas for the lab StorageClasses (single node = 1)
  default: "1"
2026-10-19 14:26:45 WRN this package does NOT contain an SBOM. If you require an SBOM, the package must be built without the --skip-sbom flag
2026-10-19 14:26:45 INF starting deploy package=longhorn-lab
2026-10-19 14:26:45 INF waiting for cluster connection
2026-10-19 14:26:45 INF deploying component name=longhorn-preflight
2026-10-19 14:26:45 INF copying files count=1
2026-10-19 14:26:45 INF loading file name=/usr/local/bin/longhornctl
2026-10-19 14:26:45 INF pushing image name=docker.io/longhornio/longhorn-cli:v1.12.1 count=1/1
2026-10-19 14:26:46 INF done pushing images count=1 duration=1.4s
2026-10-19 14:26:46 INF processing Helm chart name=raw-longhorn-lab-longhorn-preflight-longhorn-namespace source=Zarf-generated
2026-10-19 14:26:46 INF performing Helm install chart=raw-longhorn-lab-longhorn-preflight-longhorn-namespace
2026-10-19 14:26:47 INF running health checks chart=raw-longhorn-lab-longhorn-preflight-longhorn-namespace
2026-10-19 14:26:47 INF running command cmd=longhornctl install preflight (V1 + V2/SPDK prerequisites)
2026-10-19 14:26:47 INF waiting for action cmd=longhornctl install preflight (V1 + V2/SPDK prerequisites) timeout=1800 seconds
time="2026-10-19T14:26:47Z" level=info msg="Initializing preflight installer"
time="2026-10-19T14:26:47Z" level=info msg="Cleaning up preflight installer"
time="2026-10-19T14:26:47Z" level=info msg="Running preflight installer"
time="2026-10-19T14:26:47Z" level=info msg="Installing dependencies with package manager"
time="2026-10-19T14:26:47Z" level=info msg="Kubelet services will be restarted within 10s (if needed)"
time="2026-10-19T14:27:37Z" level=error msg="Failed to run preflight installer: failed to install dependencies with package manager: failed to get DaemonSet pods container logs: Get \"https://127.0.0.1:6443/api/v1/namespaces/longhorn-system/pods?labelSelector=app%3Dlonghorn-preflight-installer\": dial tcp 127.0.0.1:6443: connect: connection refused"
install preflight attempt 1 failed; waiting for API server
time="2026-10-19T14:27:52Z" level=info msg="Initializing preflight installer"
time="2026-10-19T14:27:52Z" level=info msg="Cleaning up preflight installer"
time="2026-10-19T14:27:52Z" level=info msg="Running preflight installer"
time="2026-10-19T14:27:52Z" level=info msg="Installing dependencies with package manager"
time="2026-10-19T14:27:52Z" level=info msg="Kubelet services will be restarted within 10s (if needed)"
time="2026-10-19T14:28:36Z" level=info msg="Installed dependencies with package manager"
time="2026-10-19T14:28:36Z" level=info msg="Retrieved preflight installer result:\nip-10-250-0-10:\n  info:\n  - Successfully probed module nfs\n  - Successfully probed module dm_crypt\n  - Successfully started service iscsid\n  - Successfully probed module nvme_tcp\n  - Successfully probed module uio_pci_generic\n  - Successfully probed module vfio_pci\n  - Successfully probed module ublk_drv\n  - Successfully configured SPDK environment\n  warn:\n  - \"Failed to install package linux-modules-extra-7.0.0-1014-aws: failed to execute: nsenter [--mount=/host/proc/8933/ns/mnt --net=/host/proc/8933/ns/net apt install linux-modules-extra-7.0.0-1014-aws -y], output Reading package lists...\\nBuilding dependency tree...\\nReading state information...\\n, stderr \\nWARNING: apt does not have a stable CLI interface. Use with caution in scripts.\\nE: Unable to locate package linux-modules-extra-7.0.0-1014-aws\\nE: Couldn't find any package by glob 'linux-modules-extra-7.0.0-1014-aws': exit status 100\"\n"
time="2026-10-19T14:28:36Z" level=info msg="Cleaning up preflight installer"
time="2026-10-19T14:28:36Z" level=info msg="Completed preflight installer. Use 'longhornctl check preflight' to check the result (on some os a reboot and a new install execution is required first)"
2026-10-19 14:28:36 INF action succeeded cmd=longhornctl install preflight (V1 + V2/SPDK prerequisites)
2026-10-19 14:28:36 INF running command cmd=Wait for API server and hugepages-2Mi to be advertised after the kubelet restart
2026-10-19 14:28:36 INF waiting for action cmd=Wait for API server and hugepages-2Mi to be advertised after the kubelet restart timeout=1800 seconds
hugepages-2Mi allocatable: 2Gi
2026-10-19 14:28:36 INF action succeeded cmd=Wait for API server and hugepages-2Mi to be advertised after the kubelet restart
2026-10-19 14:28:36 INF running command cmd=longhornctl check preflight (exits 0 even on failure, so grep the per-node error list)
2026-10-19 14:28:36 INF waiting for action cmd=longhornctl check preflight (exits 0 even on failure, so grep the per-node error list) timeout=1800 seconds
time="2026-10-19T14:28:36Z" level=info msg="Initializing preflight checker"
time="2026-10-19T14:28:36Z" level=info msg="Cleaning up preflight checker"
time="2026-10-19T14:28:36Z" level=info msg="Running preflight checker"
time="2026-10-19T14:28:39Z" level=info msg="Retrieved preflight checker result:\nip-10-250-0-10:\n  info:\n  - '[IscsidService] Service iscsid is running'\n  - '[NFSv4] NFS4 is supported'\n  - '[Packages] nfs-common is installed'\n  - '[Packages] open-iscsi is installed'\n  - '[Packages] cryptsetup is installed'\n  - '[Packages] dmsetup is installed'\n  - '[KernelModules] nfs is loaded'\n  - '[KernelModules] dm_crypt is loaded'\n  - '[HugePages] HugePages is enabled'\n  - '[HugePages] Node CR has enough hugepages-2Mi capacity'\n  - '[SPDK][CPUInstructionSet] sse4_2 is supported'\n  - '[SPDK][KernelModules] nvme_tcp is loaded'\n  - '[SPDK][KernelModules] uio_pci_generic is loaded'\n  - '[SPDK][KernelModules] vfio_pci is loaded'\n  - '[SPDK][KernelModules] ublk_drv is loaded'\n  warn:\n  - '[KubeDNS] Kube DNS \"coredns\" is set with fewer than 2 replicas; consider increasing replica count for high availability'\n  - '[MultipathService] multipathd.service is running. Please refer to https://longhorn.io/kb/troubleshooting-volume-with-multipath/ for more information.'\n"
time="2026-10-19T14:28:39Z" level=info msg="Cleaning up preflight checker"
time="2026-10-19T14:28:39Z" level=info msg="Completed preflight checker"
2026-10-19 14:28:39 INF action succeeded cmd=longhornctl check preflight (exits 0 even on failure, so grep the per-node error list)
2026-10-19 14:28:39 INF running command cmd=Declare Longhorn default disks on the node (V1 /var/lib/longhorn + V2 raw block disk)
2026-10-19 14:28:39 INF waiting for action cmd=Declare Longhorn default disks on the node (V1 /var/lib/longhorn + V2 raw block disk) timeout=1800 seconds
node/ip-10-250-0-10 labeled
node/ip-10-250-0-10 annotated
2026-10-19 14:28:39 INF action succeeded cmd=Declare Longhorn default disks on the node (V1 /var/lib/longhorn + V2 raw block disk)
2026-10-19 14:28:39 INF deploying component name=longhorn-diagnose
2026-10-19 14:28:39 INF copying files count=1
2026-10-19 14:28:39 INF loading file name=/usr/local/bin/longhornctl-diagnose
2026-10-19 14:28:39 INF deploying component name=longhorn
2026-10-19 14:28:39 INF pushing image name=docker.io/longhornio/csi-attacher:v4.12.0 count=1/13
2026-10-19 14:28:41 INF pushing image name=docker.io/longhornio/csi-provisioner:v5.3.0 count=2/13
2026-10-19 14:28:43 INF pushing image name=docker.io/longhornio/csi-resizer:v2.2.1 count=3/13
2026-10-19 14:28:45 INF pushing image name=docker.io/longhornio/support-bundle-kit:v0.0.92 count=4/13
2026-10-19 14:28:46 INF pushing image name=docker.io/longhornio/backing-image-manager:v1.12.1 count=5/13
2026-10-19 14:28:48 INF pushing image name=docker.io/longhornio/longhorn-instance-manager:v1.12.1 count=6/13
2026-10-19 14:28:53 INF pushing image name=docker.io/longhornio/longhorn-manager:v1.12.1 count=7/13
2026-10-19 14:28:54 INF pushing image name=docker.io/longhornio/longhorn-share-manager:v1.12.1 count=8/13
2026-10-19 14:28:57 INF pushing image name=docker.io/longhornio/longhorn-ui:v1.12.1 count=9/13
2026-10-19 14:28:58 INF pushing image name=docker.io/longhornio/csi-snapshotter:v8.6.0 count=10/13
2026-10-19 14:29:00 INF pushing image name=docker.io/longhornio/csi-node-driver-registrar:v2.17.0 count=11/13
2026-10-19 14:29:02 INF pushing image name=docker.io/longhornio/livenessprobe:v2.19.0 count=12/13
2026-10-19 14:29:03 INF pushing image name=docker.io/longhornio/longhorn-engine:v1.12.1 count=13/13
2026-10-19 14:29:05 INF done pushing images count=13 duration=25.9s
2026-10-19 14:29:05 INF processing Helm chart name=longhorn source=https://charts.longhorn.io
2026-10-19 14:29:05 INF performing Helm install chart=longhorn
I1019 14:29:06.572668    7866 warnings.go:107] "Warning: unrecognized format \"int64\""
I1019 14:29:06.594530    7866 warnings.go:107] "Warning: unrecognized format \"int64\""
I1019 14:29:06.595214    7866 warnings.go:107] "Warning: unrecognized format \"int64\""
I1019 14:29:06.630103    7866 warnings.go:107] "Warning: unrecognized format \"int64\""
I1019 14:29:06.631027    7866 warnings.go:107] "Warning: unrecognized format \"int64\""
I1019 14:29:06.666095    7866 warnings.go:107] "Warning: unrecognized format \"int64\""
2026-10-19 14:29:35 INF running health checks chart=longhorn
2026-10-19 14:29:35 INF processing Helm chart name=raw-longhorn-lab-longhorn-longhorn-lab-extras source=Zarf-generated
2026-10-19 14:29:35 INF performing Helm install chart=raw-longhorn-lab-longhorn-longhorn-lab-extras
2026-10-19 14:29:35 INF running health checks chart=raw-longhorn-lab-longhorn-longhorn-lab-extras
2026-10-19 14:29:35 INF running command cmd=Longhorn readiness (longhornctl diagnose if present, else Zarf waits)
2026-10-19 14:29:35 INF waiting for action cmd=Longhorn readiness (longhornctl diagnose if present, else Zarf waits) timeout=1200 seconds
time="2026-10-19T14:29:35Z" level=info msg="Initializing Longhorn diagnoser"
time="2026-10-19T14:29:35Z" level=info msg="Running Longhorn diagnoser"
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=LonghornManager
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=LonghornBackend
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=LonghornNodes
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=EngineImages
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=InstanceManagers
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=CSIDriver
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=CSIPlugin
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=CSIAttacher
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=CSIProvisioner
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=CSIResizer
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=CSISnapshotter
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=LonghornUI
time="2026-10-19T14:29:35Z" level=info msg="Running check" check=Volumes
- name: LonghornManager
  status: pass
  info:
  - DaemonSet longhorn-manager has 1/1 pods ready
- name: LonghornBackend
  status: pass
  info:
  - Service longhorn-backend has 1 ready endpoints
- name: LonghornNodes
  status: pass
  info:
  - 1/1 nodes are ready
- name: EngineImages
  status: fail
  error:
  - EngineImage ei-2e494080 (127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1) is deploying, not deployed on nodes [ip-10-250-0-10]
- name: InstanceManagers
  status: fail
  error:
  - InstanceManager instance-manager-829b70083c9df12d0ed5a63712b97815 on node ip-10-250-0-10 is starting
  - InstanceManager instance-manager-963e65c34047421d7c7bd1cf1c6d5161 on node ip-10-250-0-10 is starting
  info:
  - 0/2 instance managers are running
- name: CSIDriver
  status: fail
  error:
  - 'failed to get CSIDriver driver.longhorn.io: csidrivers.storage.k8s.io "driver.longhorn.io" not found'
- name: CSIPlugin
  status: fail
  error:
  - 'failed to get DaemonSet longhorn-csi-plugin: daemonsets.apps "longhorn-csi-plugin" not found'
- name: CSIAttacher
  status: fail
  error:
  - 'failed to get Deployment csi-attacher: deployments.apps "csi-attacher" not found'
- name: CSIProvisioner
  status: fail
  error:
  - 'failed to get Deployment csi-provisioner: deployments.apps "csi-provisioner" not found'
- name: CSIResizer
  status: fail
  error:
  - 'failed to get Deployment csi-resizer: deployments.apps "csi-resizer" not found'
- name: CSISnapshotter
  status: fail
  error:
  - 'failed to get Deployment csi-snapshotter: deployments.apps "csi-snapshotter" not found'
- name: LonghornUI
  status: pass
  info:
  - Deployment longhorn-ui has 2/2 pods ready
- name: Volumes
  status: pass
  info:
  - 0 volumes are found, 0 degraded, 0 faulted
time="2026-10-19T14:29:35Z" level=error msg="Longhorn system is unhealthy, failed checks: EngineImages, InstanceManagers, CSIDriver, CSIPlugin, CSIAttacher, CSIProvisioner, CSIResizer, CSISnapshotter"
diagnose not healthy yet (attempt 1), retrying in 15s
time="2026-10-19T14:29:50Z" level=info msg="Initializing Longhorn diagnoser"
time="2026-10-19T14:29:50Z" level=info msg="Running Longhorn diagnoser"
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=LonghornManager
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=LonghornBackend
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=LonghornNodes
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=EngineImages
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=InstanceManagers
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=CSIDriver
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=CSIPlugin
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=CSIAttacher
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=CSIProvisioner
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=CSIResizer
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=CSISnapshotter
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=LonghornUI
time="2026-10-19T14:29:50Z" level=info msg="Running check" check=Volumes
- name: LonghornManager
  status: pass
  info:
  - DaemonSet longhorn-manager has 1/1 pods ready
- name: LonghornBackend
  status: pass
  info:
  - Service longhorn-backend has 1 ready endpoints
- name: LonghornNodes
  status: pass
  info:
  - 1/1 nodes are ready
- name: EngineImages
  status: pass
  info:
  - EngineImage ei-2e494080 (127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1) is deployed
- name: InstanceManagers
  status: pass
  info:
  - 2/2 instance managers are running
- name: CSIDriver
  status: fail
  error:
  - 'failed to get CSIDriver driver.longhorn.io: csidrivers.storage.k8s.io "driver.longhorn.io" not found'
- name: CSIPlugin
  status: fail
  error:
  - 'failed to get DaemonSet longhorn-csi-plugin: daemonsets.apps "longhorn-csi-plugin" not found'
- name: CSIAttacher
  status: fail
  error:
  - 'failed to get Deployment csi-attacher: deployments.apps "csi-attacher" not found'
- name: CSIProvisioner
  status: fail
  error:
  - 'failed to get Deployment csi-provisioner: deployments.apps "csi-provisioner" not found'
- name: CSIResizer
  status: fail
  error:
  - 'failed to get Deployment csi-resizer: deployments.apps "csi-resizer" not found'
- name: CSISnapshotter
  status: fail
  error:
  - 'failed to get Deployment csi-snapshotter: deployments.apps "csi-snapshotter" not found'
- name: LonghornUI
  status: pass
  info:
  - Deployment longhorn-ui has 2/2 pods ready
- name: Volumes
  status: pass
  info:
  - 0 volumes are found, 0 degraded, 0 faulted
time="2026-10-19T14:29:50Z" level=error msg="Longhorn system is unhealthy, failed checks: CSIDriver, CSIPlugin, CSIAttacher, CSIProvisioner, CSIResizer, CSISnapshotter"
diagnose not healthy yet (attempt 2), retrying in 15s
time="2026-10-19T14:30:05Z" level=info msg="Initializing Longhorn diagnoser"
time="2026-10-19T14:30:05Z" level=info msg="Running Longhorn diagnoser"
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=LonghornManager
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=LonghornBackend
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=LonghornNodes
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=EngineImages
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=InstanceManagers
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=CSIDriver
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=CSIPlugin
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=CSIAttacher
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=CSIProvisioner
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=CSIResizer
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=CSISnapshotter
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=LonghornUI
time="2026-10-19T14:30:05Z" level=info msg="Running check" check=Volumes
time="2026-10-19T14:30:05Z" level=error msg="Longhorn system is unhealthy, failed checks: CSIDriver, CSIPlugin, CSIAttacher, CSIProvisioner, CSIResizer, CSISnapshotter"
- name: LonghornManager
  status: pass
  info:
  - DaemonSet longhorn-manager has 1/1 pods ready
- name: LonghornBackend
  status: pass
  info:
  - Service longhorn-backend has 1 ready endpoints
- name: LonghornNodes
  status: warn
  info:
  - 1/1 nodes are ready
  warn:
  - 'Node ip-10-250-0-10 condition Multipathd is false: multipathd is running with a known issue that affects Longhorn. See description and solution at https://longhorn.io/kb/troubleshooting-volume-with-multipath'
  - 'Disk v2disk on node ip-10-250-0-10 is not ready: Disk v2disk(/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol050960e6165b3f216) on node ip-10-250-0-10 is not ready: errors: disk is not in ready state, current state: creating'
- name: EngineImages
  status: pass
  info:
  - EngineImage ei-2e494080 (127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1) is deployed
- name: InstanceManagers
  status: pass
  info:
  - 2/2 instance managers are running
- name: CSIDriver
  status: fail
  error:
  - 'failed to get CSIDriver driver.longhorn.io: csidrivers.storage.k8s.io "driver.longhorn.io" not found'
- name: CSIPlugin
  status: fail
  error:
  - 'failed to get DaemonSet longhorn-csi-plugin: daemonsets.apps "longhorn-csi-plugin" not found'
- name: CSIAttacher
  status: fail
  error:
  - 'failed to get Deployment csi-attacher: deployments.apps "csi-attacher" not found'
- name: CSIProvisioner
  status: fail
  error:
  - 'failed to get Deployment csi-provisioner: deployments.apps "csi-provisioner" not found'
- name: CSIResizer
  status: fail
  error:
  - 'failed to get Deployment csi-resizer: deployments.apps "csi-resizer" not found'
- name: CSISnapshotter
  status: fail
  error:
  - 'failed to get Deployment csi-snapshotter: deployments.apps "csi-snapshotter" not found'
- name: LonghornUI
  status: pass
  info:
  - Deployment longhorn-ui has 2/2 pods ready
- name: Volumes
  status: pass
  info:
  - 0 volumes are found, 0 degraded, 0 faulted
diagnose not healthy yet (attempt 3), retrying in 15s
time="2026-10-19T14:30:20Z" level=info msg="Initializing Longhorn diagnoser"
time="2026-10-19T14:30:20Z" level=info msg="Running Longhorn diagnoser"
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=LonghornManager
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=LonghornBackend
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=LonghornNodes
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=EngineImages
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=InstanceManagers
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=CSIDriver
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=CSIPlugin
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=CSIAttacher
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=CSIProvisioner
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=CSIResizer
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=CSISnapshotter
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=LonghornUI
time="2026-10-19T14:30:20Z" level=info msg="Running check" check=Volumes
- name: LonghornManager
  status: pass
  info:
  - DaemonSet longhorn-manager has 1/1 pods ready
- name: LonghornBackend
  status: pass
  info:
  - Service longhorn-backend has 1 ready endpoints
- name: LonghornNodes
  status: warn
  info:
  - 1/1 nodes are ready
  warn:
  - 'Node ip-10-250-0-10 condition Multipathd is false: multipathd is running with a known issue that affects Longhorn. See description and solution at https://longhorn.io/kb/troubleshooting-volume-with-multipath'
  - 'Disk v2disk on node ip-10-250-0-10 is not ready: Disk v2disk(/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol050960e6165b3f216) on node ip-10-250-0-10 is not ready: errors: disk is not in ready state, current state: creating'
- name: EngineImages
  status: pass
  info:
  - EngineImage ei-2e494080 (127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1) is deployed
- name: InstanceManagers
  status: pass
  info:
  - 2/2 instance managers are running
- name: CSIDriver
  status: pass
  info:
  - CSIDriver driver.longhorn.io is registered
- name: CSIPlugin
  status: pass
  info:
  - DaemonSet longhorn-csi-plugin has 1/1 pods ready
- name: CSIAttacher
  status: pass
  info:
  - Deployment csi-attacher has 3/3 pods ready
- name: CSIProvisioner
  status: pass
  info:
  - Deployment csi-provisioner has 3/3 pods ready
- name: CSIResizer
  status: pass
  info:
  - Deployment csi-resizer has 3/3 pods ready
- name: CSISnapshotter
  status: pass
  info:
  - Deployment csi-snapshotter has 3/3 pods ready
- name: LonghornUI
  status: pass
  info:
  - Deployment longhorn-ui has 2/2 pods ready
- name: Volumes
  status: pass
  info:
  - 0 volumes are found, 0 degraded, 0 faulted
time="2026-10-19T14:30:20Z" level=info msg="Longhorn system is healthy"
2026-10-19 14:30:20 INF action succeeded cmd=Longhorn readiness (longhornctl diagnose if present, else Zarf waits)
2026-10-19 14:30:20 INF running command cmd=Wait for the V2 block disk (created from the node annotation; patched in if the node already had disks, e.g. after a Helm takeover)
2026-10-19 14:30:20 INF waiting for action cmd=Wait for the V2 block disk (created from the node annotation; patched in if the node already had disks, e.g. after a Helm takeover) timeout=600 seconds
node.longhorn.io/ip-10-250-0-10 patched
2026-10-19 14:30:21 INF waiting for resource kind=Node.longhorn.io identifier=ip-10-250-0-10 condition=jsonpath={.status.diskStatus.v2disk.conditions[?(@.type=="Ready")].status}=True namespace=longhorn-system
2026-10-19 14:30:25 INF wait-for condition met kind=Node.longhorn.io identifier=ip-10-250-0-10 condition=jsonpath={.status.diskStatus.v2disk.conditions[?(@.type=="Ready")].status}=True namespace=longhorn-system
2026-10-19 14:30:25 INF action succeeded cmd=Wait for the V2 block disk (created from the node annotation; patched in if the node already had disks, e.g. after a Helm takeover)
2026-10-19 14:30:25 INF running command cmd=Make longhorn-v2 the only default StorageClass (K3s marks local-path as default)
2026-10-19 14:30:25 INF waiting for action (no timeout) cmd=Make longhorn-v2 the only default StorageClass (K3s marks local-path as default)
storageclass.storage.k8s.io/local-path annotated
2026-10-19 14:30:26 INF action succeeded cmd=Make longhorn-v2 the only default StorageClass (K3s marks local-path as default)

     Connect Command          | Description
     zarf connect longhorn-ui | Connect to the Longhorn User Interface


==> Longhorn state
NAME                                            NAMESPACE       REVISION        UPDATED                                 STATUS         CHART                                                                   APP VERSION
longhorn                                        longhorn-system 1               2026-10-19 14:29:05.753722687 +0000 UTC deployed       longhorn-1.12.1                                                         v1.12.1
zarf-1676a4a93e6e0def8bcff1b3d37d6fe5e59c16d6   longhorn-system 1               2026-10-19 14:26:46.920388078 +0000 UTC deployed       raw-longhorn-lab-longhorn-preflight-longhorn-namespace-0.1.1792420001
zarf-613764d665189e32bed4a78527dd10f4ffae5ba0   longhorn-system 1               2026-10-19 14:29:35.558958289 +0000 UTC deployed       raw-longhorn-lab-longhorn-longhorn-lab-extras-0.1.1792420001
NAME              STATUS   AGE     LABELS
longhorn-system   Active   3m41s   app.kubernetes.io/managed-by=zarf,kubernetes.io/metadata.name=longhorn-system,zarf.dev/agent=mutate
NAME                                  INCOMPATIBLE   STATE      IMAGE                                                REFCOUNT   BUILDDATE   AGE
engineimage.longhorn.io/ei-2e494080   false          deployed   127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1   0          67d         62s

NAME                                                                            DATA ENGINE   STATE     TYPE   NODE             AGE
instancemanager.longhorn.io/instance-manager-829b70083c9df12d0ed5a63712b97815   v2            running   aio    ip-10-250-0-10   61s
instancemanager.longhorn.io/instance-manager-963e65c34047421d7c7bd1cf1c6d5161   v1            running   aio    ip-10-250-0-10   62s
NAME   ENGINE   STATE   ROBUST   IMAGE
ip-10-250-0-10
  filesystem /var/lib/longhorn ready=True
  block /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol050960e6165b3f216 ready=True
NAME                       IMAGE
engine-image-ei-2e494080   127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1
longhorn-csi-plugin        127.0.0.1:31999/longhornio/csi-node-driver-registrar:v2.17.0
longhorn-manager           127.0.0.1:31999/longhornio/longhorn-manager:v1.12.1
csi-attacher               127.0.0.1:31999/longhornio/csi-attacher:v4.12.0
csi-provisioner            127.0.0.1:31999/longhornio/csi-provisioner:v5.3.0
csi-resizer                127.0.0.1:31999/longhornio/csi-resizer:v2.2.1
csi-snapshotter            127.0.0.1:31999/longhornio/csi-snapshotter:v8.6.0
longhorn-driver-deployer   127.0.0.1:31999/longhornio/longhorn-manager:v1.12.1
longhorn-ui                127.0.0.1:31999/longhornio/longhorn-ui:v1.12.1
```

</details>

## Step 5: Health check

longhornctl diagnose (v1.14.0-dev, longhorn/longhorn#3355) checks managers, instance managers, CSI, engine images and volumes in one shot.

```console
$ longhornctl diagnose
```

<details><summary>Output (70 lines)</summary>

```console
INFO[2026-10-19T14:30:35Z] Initializing Longhorn diagnoser
INFO[2026-10-19T14:30:35Z] Running Longhorn diagnoser
INFO[2026-10-19T14:30:35Z] Running check                                 check=LonghornManager
INFO[2026-10-19T14:30:35Z] Running check                                 check=LonghornBackend
INFO[2026-10-19T14:30:35Z] Running check                                 check=LonghornNodes
INFO[2026-10-19T14:30:35Z] Running check                                 check=EngineImages
INFO[2026-10-19T14:30:35Z] Running check                                 check=InstanceManagers
INFO[2026-10-19T14:30:35Z] Running check                                 check=CSIDriver
INFO[2026-10-19T14:30:35Z] Running check                                 check=CSIPlugin
INFO[2026-10-19T14:30:35Z] Running check                                 check=CSIAttacher
INFO[2026-10-19T14:30:35Z] Running check                                 check=CSIProvisioner
INFO[2026-10-19T14:30:35Z] Running check                                 check=CSIResizer
INFO[2026-10-19T14:30:35Z] Running check                                 check=CSISnapshotter
INFO[2026-10-19T14:30:35Z] Running check                                 check=LonghornUI
INFO[2026-10-19T14:30:35Z] Running check                                 check=Volumes
- name: LonghornManager
  status: pass
  info:
  - DaemonSet longhorn-manager has 1/1 pods ready
- name: LonghornBackend
  status: pass
  info:
  - Service longhorn-backend has 1 ready endpoints
- name: LonghornNodes
  status: warn
  info:
  - 1/1 nodes are ready
  warn:
  - 'Node ip-10-250-0-10 condition Multipathd is false: multipathd is running with a known issue that affects Longhorn. See description and solution at https://longhorn.io/kb/troubleshooting-volume-with-multipath'
- name: EngineImages
  status: pass
  info:
  - EngineImage ei-2e494080 (127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1) is deployed
- name: InstanceManagers
  status: pass
  info:
  - 2/2 instance managers are running
- name: CSIDriver
  status: pass
  info:
  - CSIDriver driver.longhorn.io is registered
- name: CSIPlugin
  status: pass
  info:
  - DaemonSet longhorn-csi-plugin has 1/1 pods ready
- name: CSIAttacher
  status: pass
  info:
  - Deployment csi-attacher has 3/3 pods ready
- name: CSIProvisioner
  status: pass
  info:
  - Deployment csi-provisioner has 3/3 pods ready
- name: CSIResizer
  status: pass
  info:
  - Deployment csi-resizer has 3/3 pods ready
- name: CSISnapshotter
  status: pass
  info:
  - Deployment csi-snapshotter has 3/3 pods ready
- name: LonghornUI
  status: pass
  info:
  - Deployment longhorn-ui has 2/2 pods ready
- name: Volumes
  status: pass
  info:
  - 0 volumes are found, 0 degraded, 0 faulted
INFO[2026-10-19T14:30:35Z] Longhorn system is healthy
```

</details>

## Step 6: GitOps: Flux deploys podinfo from Gitea

The demo package mirrors the podinfo git repo into Gitea. Flux reconciles it, and the app's data lives on a Longhorn PVC. Note the rewritten git URL and image.

```console
$ zarf package deploy zarf-package-gitops-demo-amd64-0.1.0.tar.zst --confirm
```

<details><summary>Output (170 lines)</summary>

```console
==> Deploying GitOps demo (StorageClass=longhorn)
2026-10-19 14:30:50 WRN package signature not verified; continuing reason=package is not signed - verification cannot be performed: no verification material available

kind: ZarfPackageConfig
metadata:
  name: gitops-demo
  description: Flux pulls podinfo from the in-cluster Gitea (pushed by Zarf) and runs it on a Longhorn PVC
  version: 0.1.0
  architecture: amd64
  aggregateChecksum: 8adfeeac80d2ccf06a2d31eee2569bad07c70b81c052dbc142c9245aa6fee2d2
  allowNamespaceOverride: true
build:
  architecture: amd64
  timestamp: Mon, 19 Oct 2026 14:14:34 +0000
  version: v0.88.0
  migrations:
  - scripts-to-actions
  - pluralize-set-variable
  signed: false
  provenanceFiles:
  - checksums.txt
components:
- name: flux
  required: true
  manifests:
  - name: flux-install
    namespace: flux-system
    files:
    - https://github.com/fluxcd/flux2/releases/download/v2.9.6/install.yaml
    template: false
  images:
  - ghcr.io/fluxcd/helm-controller:v1.6.5
  - ghcr.io/fluxcd/image-automation-controller:v1.2.5
  - ghcr.io/fluxcd/image-reflector-controller:v1.2.5
  - ghcr.io/fluxcd/kustomize-controller:v1.9.6
  - ghcr.io/fluxcd/notification-controller:v1.9.4
  - ghcr.io/fluxcd/source-controller:v1.9.6
  - ghcr.io/fluxcd/source-watcher:v2.2.4
  actions:
    onDeploy:
      after:
      - wait:
          cluster:
            kind: deployment
            name: source-controller
            namespace: flux-system
            condition: Available
        template: false
      - wait:
          cluster:
            kind: deployment
            name: kustomize-controller
            namespace: flux-system
            condition: Available
        template: false
- name: podinfo
  required: true
  manifests:
  - name: podinfo-gitops
    namespace: podinfo
    files:
    - manifests/pvc.yaml
    - manifests/gitrepository.yaml
    - manifests/kustomization.yaml
    - manifests/service.yaml
    template: false
  images:
  - ghcr.io/stefanprodan/podinfo:6.15.0
  - busybox:1.37
  repos:
  - https://github.com/stefanprodan/podinfo.git@6.15.0
  actions:
    onDeploy:
      defaults:
        shell:
          linux: bash
      after:
      - cmd: "./zarf tools kubectl -n podinfo get gitrepository podinfo -o jsonpath='{.spec.url}{\"\\n\"}'"
        description: Show the Gitea URL the agent wrote into the GitRepository
        template: false
      - maxTotalSeconds: 600
        wait:
          cluster:
            kind: kustomizations.kustomize.toolkit.fluxcd.io
            name: podinfo
            namespace: podinfo
            condition: Ready
        template: false
      - maxTotalSeconds: 600
        wait:
          cluster:
            kind: deployment
            name: podinfo
            namespace: podinfo
            condition: Available
        template: false
    onRemove:
      defaults:
        shell:
          linux: bash
      after:
      - maxTotalSeconds: 600
        cmd: |
          ./zarf tools kubectl delete namespace podinfo --ignore-not-found --wait=true --timeout=5m
          for i in $(seq 1 60); do
            n=$(./zarf tools kubectl get volumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null | wc -l)
            [[ "$n" -eq 0 ]] && exit 0
            sleep 5
          done
          echo "Longhorn volumes still present" >&2; exit 1
        description: Delete the podinfo namespace and wait for the Longhorn volume to be released
        template: false
variables:
- name: STORAGE_CLASS  currently set to 'longhorn'
  description: StorageClass for the podinfo /data PVC (longhorn = V1, longhorn-v2 = V2)
  default: longhorn
2026-10-19 14:30:50 WRN this package does NOT contain an SBOM. If you require an SBOM, the package must be built without the --skip-sbom flag
2026-10-19 14:30:50 INF starting deploy package=gitops-demo
2026-10-19 14:30:50 INF waiting for cluster connection
2026-10-19 14:30:50 INF deploying component name=flux
2026-10-19 14:30:50 INF pushing image name=ghcr.io/fluxcd/source-controller:v1.9.6 count=1/7
2026-10-19 14:30:52 INF pushing image name=ghcr.io/fluxcd/source-watcher:v2.2.4 count=2/7
2026-10-19 14:30:53 INF pushing image name=ghcr.io/fluxcd/helm-controller:v1.6.5 count=3/7
2026-10-19 14:30:54 INF pushing image name=ghcr.io/fluxcd/image-automation-controller:v1.2.5 count=4/7
2026-10-19 14:30:55 INF pushing image name=ghcr.io/fluxcd/image-reflector-controller:v1.2.5 count=5/7
2026-10-19 14:30:57 INF pushing image name=ghcr.io/fluxcd/kustomize-controller:v1.9.6 count=6/7
2026-10-19 14:30:59 INF pushing image name=ghcr.io/fluxcd/notification-controller:v1.9.4 count=7/7
2026-10-19 14:31:01 INF done pushing images count=7 duration=10.5s
2026-10-19 14:31:01 INF processing Helm chart name=raw-gitops-demo-flux-flux-install source=Zarf-generated
2026-10-19 14:31:01 INF performing Helm install chart=raw-gitops-demo-flux-flux-install
2026-10-19 14:31:14 INF running health checks chart=raw-gitops-demo-flux-flux-install
2026-10-19 14:31:15 INF running wait action description=wait for deployment/source-controller to be Available
2026-10-19 14:31:15 INF waiting for resource kind=Deployment.apps identifier=source-controller condition=condition=Available namespace=flux-system
2026-10-19 14:31:15 INF wait-for condition met kind=Deployment.apps identifier=source-controller condition=condition=Available namespace=flux-system
2026-10-19 14:31:15 INF running wait action description=wait for deployment/kustomize-controller to be Available
2026-10-19 14:31:15 INF waiting for resource kind=Deployment.apps identifier=kustomize-controller condition=condition=Available namespace=flux-system
2026-10-19 14:31:15 INF wait-for condition met kind=Deployment.apps identifier=kustomize-controller condition=condition=Available namespace=flux-system
2026-10-19 14:31:15 INF deploying component name=podinfo
2026-10-19 14:31:15 INF pushing image name=ghcr.io/stefanprodan/podinfo:6.15.0 count=1/2
2026-10-19 14:31:17 INF pushing image name=docker.io/library/busybox:1.37 count=2/2
2026-10-19 14:31:18 INF done pushing images count=2 duration=2.6s
2026-10-19 14:31:18 INF pushing repository to server repo=https://github.com/stefanprodan/podinfo.git server=http://127.0.0.1:39587
2026-10-19 14:31:29 INF processing Helm chart name=raw-gitops-demo-podinfo-podinfo-gitops source=Zarf-generated
2026-10-19 14:31:29 INF performing Helm install chart=raw-gitops-demo-podinfo-podinfo-gitops
2026-10-19 14:31:34 INF running health checks chart=raw-gitops-demo-podinfo-podinfo-gitops
2026-10-19 14:32:01 INF running command cmd=Show the Gitea URL the agent wrote into the GitRepository
2026-10-19 14:32:01 INF waiting for action (no timeout) cmd=Show the Gitea URL the agent wrote into the GitRepository
http://zarf-gitea-http.zarf.svc.cluster.local:3000/zarf-git-user/podinfo-1646971829.git
2026-10-19 14:32:02 INF action succeeded cmd=Show the Gitea URL the agent wrote into the GitRepository
2026-10-19 14:32:02 INF running wait action description=wait for kustomizations.kustomize.toolkit.fluxcd.io/podinfo to be Ready
2026-10-19 14:32:02 INF waiting for resource kind=Kustomization.kustomize.toolkit.fluxcd.io identifier=podinfo condition=condition=Ready namespace=podinfo
2026-10-19 14:32:02 INF wait-for condition met kind=Kustomization.kustomize.toolkit.fluxcd.io identifier=podinfo condition=condition=Ready namespace=podinfo
2026-10-19 14:32:02 INF running wait action description=wait for deployment/podinfo to be Available
2026-10-19 14:32:02 INF waiting for resource kind=Deployment.apps identifier=podinfo condition=condition=Available namespace=podinfo
2026-10-19 14:32:02 INF wait-for condition met kind=Deployment.apps identifier=podinfo condition=condition=Available namespace=podinfo

     Connect Command      | Description
     zarf connect podinfo | podinfo deployed by Flux from Gitea

NAME                                             URL                                                                                       AGE   READY   STATUS
gitrepository.source.toolkit.fluxcd.io/podinfo   http://zarf-gitea-http.zarf.svc.cluster.local:3000/zarf-git-user/podinfo-1646971829.git   32s   True    stored artifact for revision '6.15.0@sha1:dd507173b7b75b2312a36cabe0de5f09c1ce69c8'

NAME                                                AGE   READY   STATUS
kustomization.kustomize.toolkit.fluxcd.io/podinfo   32s   True    Applied revision: 6.15.0@sha1:dd507173b7b75b2312a36cabe0de5f09c1ce69c8

NAME                                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/podinfo-data   Bound    pvc-cb7942d7-2e12-46f1-a1d3-74d276ce241a   1Gi        RWO            longhorn       <unset>                 33s

NAME                           READY   STATUS    RESTARTS   AGE
pod/podinfo-6dc4779c94-jz4dj   1/1     Running   0          31s
```

</details>

## Step 7: Inspect the GitOps wiring

No internet involved: the git source, the image and the volume all come from inside the cluster.

```console
$ kubectl -n podinfo get gitrepository,kustomization,pvc
GitRepository URL (rewritten by the Zarf agent to the in-cluster Gitea):
  http://zarf-gitea-http.zarf.svc.cluster.local:3000/zarf-git-user/podinfo-1646971829.git
NAME                                             URL                                                                                       AGE   READY   STATUS
gitrepository.source.toolkit.fluxcd.io/podinfo   http://zarf-gitea-http.zarf.svc.cluster.local:3000/zarf-git-user/podinfo-1646971829.git   69s   True    stored artifact for revision '6.15.0@sha1:dd507173b7b75b2312a36cabe0de5f09c1ce69c8'

NAME                                                AGE   READY   STATUS
kustomization.kustomize.toolkit.fluxcd.io/podinfo   69s   True    Applied revision: 6.15.0@sha1:dd507173b7b75b2312a36cabe0de5f09c1ce69c8
PVC            SC         STATUS   VOLUME
podinfo-data   longhorn   Bound    pvc-cb7942d7-2e12-46f1-a1d3-74d276ce241a

podinfo image (rewritten to the Zarf registry):
  ghcr.io/stefanprodan/podinfo:6.15.0
```

## Step 8: Write data

Store a payload through the podinfo API (V1 volume) and write the same payload to a V2 (SPDK) volume.

```console
$ curl -X POST :30898/store -d <payload>
==> podinfo stored 'lab-1792420363-25062' as 0212eb3c4792f5e37d7ccbad965083874a6ad278
namespace/v2-test created
secret/private-registry created
statefulset.apps/v2-writer created
Waiting for 1 pods to be ready...
partitioned roll out complete: 1 new pods have been updated...
da49e5120624f375fcfdfc3e3a31b99a  /data/payload
```

## Step 9: Upgrade Longhorn to 1.13.0

Same command as the install, just a newer package. Zarf upgrades the Helm release in place, and the hooks re-run preflight and diagnose.

```console
$ zarf package deploy zarf-package-longhorn-lab-amd64-1.13.0.tar.zst --confirm
```

<details><summary>Output (364 lines)</summary>

```console
==> zarf package deploy longhorn-lab 1.13.0
2026-10-19 14:33:22 WRN package signature not verified; continuing reason=package is not signed - verification cannot be performed: no verification material available

kind: ZarfPackageConfig
metadata:
  name: longhorn-lab
  description: Longhorn
  version: 1.13.0
  architecture: amd64
  aggregateChecksum: cf0af3ad29c880298077ddf0ed221fa22941ad77e49a46bde0ddba7e2ab82fd0
  allowNamespaceOverride: true
build:
  architecture: amd64
  timestamp: Mon, 19 Oct 2026 14:14:14 +0000
  version: v0.88.0
  migrations:
  - scripts-to-actions
  - pluralize-set-variable
  signed: false
  provenanceFiles:
  - checksums.txt
components:
- name: longhorn-preflight
  required: true
  manifests:
  - name: longhorn-namespace
    namespace: longhorn-system
    files:
    - manifests/lab-marker.yaml
    template: false
  files:
  - source: https://github.com/longhorn/cli/releases/download/v1.13.0/longhornctl-linux-amd64
    target: /usr/local/bin/longhornctl
    executable: true
    template: false
  images:
  - longhornio/longhorn-cli:v1.13.0
  actions:
    onDeploy:
      defaults:
        maxTotalSeconds: 1800
        shell:
          linux: bash
      after:
      - cmd: "set -euo pipefail\nexport KUBECONFIG=\"${KUBECONFIG:-/root/.kube/config}\"\n# On K3s the kubelet restart also restarts the API server, so the first run may lose\n# its connection. The installer is idempotent: wait for the API and retry.\nfor attempt in 1 2 3; do\n  if /usr/local/bin/longhornctl install preflight \\\n    --image longhornio/longhorn-cli:v1.13.0 \\\n    --enable-spdk --huge-page-size 2048 --spdk-options PERSIST_HUGE=yes \\\n    --restart-kubelet --restart-kubelet-window 10s; then\n    exit 0\n  fi\n  echo \"install preflight attempt $attempt failed; waiting for API server\" >&2\n  sleep 15\n  for i in $(seq 1 60); do\n    ./zarf tools kubectl get --raw=/readyz >/dev/null 2>&1 && break\n    sleep 5\n  done\ndone\nexit 1\n"
        description: longhornctl install preflight (V1 + V2/SPDK prerequisites)
        template: false
      - cmd: "set -euo pipefail\nexport KUBECONFIG=\"${KUBECONFIG:-/root/.kube/config}\"\nfor i in $(seq 1 90); do\n  if hp=$(./zarf tools kubectl get nodes -o jsonpath='{.items[0].status.allocatable.hugepages-2Mi}' 2>/dev/null) \\\n     && [[ -n \"$hp\" && \"$hp\" != \"0\" ]]; then\n    echo \"hugepages-2Mi allocatable: $hp\"; exit 0\n  fi\n  sleep 5\ndone\necho \"hugepages-2Mi never became allocatable\" >&2; exit 1\n"
        description: Wait for API server and hugepages-2Mi to be advertised after the kubelet restart
        template: false
      - cmd: "set -euo pipefail\nexport KUBECONFIG=\"${KUBECONFIG:-/root/.kube/config}\"\nout=$(/usr/local/bin/longhornctl check preflight \\\n  --image longhornio/longhorn-cli:v1.13.0 \\\n  --enable-spdk --huge-page-size 2048 2>&1)\necho \"$out\"\nif grep -qE '^  error:' <<<\"$out\"; then\n  echo \"longhornctl check preflight reported errors\" >&2; exit 1\nfi\n"
        description: longhornctl check preflight (exits 0 even on failure, so grep the per-node error list)
        template: false
      - cmd: "set -euo pipefail\nexport KUBECONFIG=\"${KUBECONFIG:-/root/.kube/config}\"\n# Used by create-default-disk-labeled-nodes only while the Longhorn node has no disks,\n# i.e. on first install. Upgrades leave existing disks alone.\ndisks='[{\"path\":\"/var/lib/longhorn\",\"allowScheduling\":true}'\nif [[ -n \"${ZARF_VAR_V2_DISK_PATH:-}\" ]]; then\n  disks+=',{\"name\":\"v2disk\",\"path\":\"'\"$ZARF_VAR_V2_DISK_PATH\"'\",\"diskType\":\"block\",\"diskDriver\":\"aio\",\"allowScheduling\":true}'\nfi\ndisks+=']'\nnode=$(./zarf tools kubectl get nodes -o jsonpath='{.items[0].metadata.name}')\n./zarf tools kubectl label node \"$node\" node.longhorn.io/create-default-disk=config --overwrite\n./zarf tools kubectl annotate node \"$node\" node.longhorn.io/default-disks-config=\"$disks\" --overwrite\n"
        description: Declare Longhorn default disks on the node (V1 /var/lib/longhorn + V2 raw block disk)
        template: false
    onRemove:
      defaults:
        shell:
          linux: bash
      after:
      - cmd: |
          set -euo pipefail
          if ./zarf tools kubectl get crd settings.longhorn.io >/dev/null 2>&1; then
            echo "Longhorn is still installed; remove the 'longhorn' component first" >&2; exit 1
          fi
          ./zarf tools kubectl delete namespace longhorn-system --ignore-not-found --wait=true --timeout=5m
        description: Delete longhorn-system (Zarf leaves namespaces behind)
        template: false
- name: longhorn-diagnose
  default: true
  required: false
  files:
  - source: bin/longhornctl-diagnose
    target: /usr/local/bin/longhornctl-diagnose
    executable: true
    template: false
- name: longhorn
  required: true
  manifests:
  - name: longhorn-lab-extras
    namespace: longhorn-system
    files:
    - manifests/storageclass-v2.yaml
    - manifests/connect.yaml
    template: false
  charts:
  - name: longhorn
    version: 1.13.0
    url: https://charts.longhorn.io
    namespace: longhorn-system
    releaseName: longhorn
    valuesFiles:
    - values-lab.yaml
    schemaValidation: true
  images:
  - longhornio/backing-image-manager:v1.13.0
  - longhornio/longhorn-engine:v1.13.0
  - longhornio/longhorn-instance-manager:v1.13.0
  - longhornio/longhorn-manager:v1.13.0
  - longhornio/longhorn-share-manager:v1.13.0
  - longhornio/longhorn-ui:v1.13.0
  - longhornio/csi-attacher:v4.13.0
  - longhornio/csi-provisioner:v6.3.0
  - longhornio/csi-resizer:v2.2.1
  - longhornio/csi-snapshotter:v8.6.0
  - longhornio/csi-node-driver-registrar:v2.18.0
  - longhornio/livenessprobe:v2.20.0
  - longhornio/support-bundle-kit:v0.0.98
  actions:
    onDeploy:
      defaults:
        shell:
          linux: bash
      after:
      - maxTotalSeconds: 1200
        cmd: |
          set -uo pipefail
          export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
          if [[ -x /usr/local/bin/longhornctl-diagnose ]]; then
            for i in $(seq 1 60); do
              if /usr/local/bin/longhornctl-diagnose diagnose; then exit 0; fi
              echo "diagnose not healthy yet (attempt $i), retrying in 15s"; sleep 15
            done
            exit 1
          fi
          set -e
          ./zarf tools wait-for resource daemonset longhorn-manager '{.status.numberReady}'=1 -n longhorn-system --timeout 10m
          ./zarf tools wait-for resource deployment longhorn-driver-deployer Available -n longhorn-system --timeout 10m
          ./zarf tools wait-for resource daemonset longhorn-csi-plugin '{.status.numberReady}'=1 -n longhorn-system --timeout 10m
          node=$(./zarf tools kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
          ./zarf tools wait-for resource nodes.longhorn.io "$node" '{.status.conditions[?(@.type=="Ready")].status}'=True -n longhorn-system --timeout 10m
        description: Longhorn readiness (longhornctl diagnose if present, else Zarf waits)
        template: false
      - maxTotalSeconds: 600
        cmd: "set -euo pipefail\nexport KUBECONFIG=\"${KUBECONFIG:-/root/.kube/config}\"\ndisk=\"${ZARF_VAR_V2_DISK_PATH:-}\"\nif [[ -z \"$disk\" ]]; then echo \"V2_DISK_PATH empty, skipping\"; exit 0; fi\nnode=$(./zarf tools kubectl get nodes -o jsonpath='{.items[0].metadata.name}')\npatch=\"{\\\"spec\\\":{\\\"disks\\\":{\\\"v2disk\\\":{\n    \\\"path\\\":\\\"$disk\\\",\\\"diskType\\\":\\\"block\\\",\\\"diskDriver\\\":\\\"aio\\\",\n    \\\"allowScheduling\\\":true,\\\"evictionRequested\\\":false,\\\"storageReserved\\\":0,\\\"tags\\\":[]}}}}\"\n# The Longhorn webhook rejects disk edits while disk spec/status is still syncing.\nfor i in $(seq 1 30); do\n  ./zarf tools kubectl -n longhorn-system patch nodes.longhorn.io \"$node\" --type merge -p \"$patch\" && break\n  [[ $i -eq 30 ]] && exit 1\n  sleep 10\ndone\n./zarf tools wait-for resource nodes.longhorn.io \"$node\" \\\n  '{.status.diskStatus.v2disk.conditions[?(@.type==\"Ready\")].status}'=True \\\n  -n longhorn-system --timeout 8m\n"
        description: Wait for the V2 block disk (created from the node annotation; patched in if the node already had disks, e.g. after a Helm takeover)
        template: false
      - cmd: |
          if ./zarf tools kubectl get storageclass local-path >/dev/null 2>&1; then
            ./zarf tools kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=false --overwrite
          fi
        description: Make longhorn-v2 the only default StorageClass (K3s marks local-path as default)
        template: false
    onRemove:
      defaults:
        shell:
          linux: bash
      before:
      - cmd: |
          set -euo pipefail
          n=$(./zarf tools kubectl get volumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null | wc -l)
          if [[ "$n" -gt 0 && "${LAB_FORCE_REMOVE:-false}" != "true" ]]; then
            ./zarf tools kubectl get volumes.longhorn.io -n longhorn-system
            echo "$n Longhorn volume(s) still exist; remove workloads/PVCs first" >&2; exit 1
          fi
        description: Refuse to uninstall while Longhorn volumes exist (set LAB_FORCE_REMOVE=true to override)
        template: false
      - cmd: "set -euo pipefail\n./zarf tools kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag \\\n  --type merge -p '{\"value\":\"true\"}'\n# The uninstall job reads the flag from an informer (apiserver watch cache), which can lag\n# behind the write, e.g. right after CRDs were deleted. Wait until the cached view agrees.\nurl=/apis/longhorn.io/v1beta2/namespaces/longhorn-system/settings/deleting-confirmation-flag?resourceVersion=0\nfor i in $(seq 1 30); do\n  ./zarf tools kubectl get --raw \"$url\" | grep -q '\"value\":\"true\"' && exit 0\n  sleep 2\ndone\necho \"deleting-confirmation-flag not visible in the watch cache\" >&2; exit 1\n"
        description: Allow the chart's pre-delete uninstall job to proceed
        template: false
      after:
      - cmd: |
          if ./zarf tools kubectl get storageclass local-path >/dev/null 2>&1; then
            ./zarf tools kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite
          fi
        description: Restore local-path as the default StorageClass
        template: false
      - cmd: "set -euo pipefail\n[[ \"${LAB_WIPE_DISKS:-false}\" == \"true\" ]] || exit 0\nsource /etc/longhorn-lab.env\nfind /var/lib/longhorn -mindepth 1 -maxdepth 1 -exec rm -rf {} +\n[[ -n \"${V2_DISK_PATH:-}\" ]] && wipefs -a \"$V2_DISK_PATH\" && \\\n  dd if=/dev/zero of=\"$V2_DISK_PATH\" bs=1M count=64 oflag=direct status=none\necho \"disks wiped\"\n"
        description: Optionally wipe host disks (LAB_WIPE_DISKS=true)
        template: false
variables:
- name: V2_DISK_PATH  currently set to '/dev/disk/by-id/n...'
  description: Raw block device registered as a V2 (SPDK aio) disk. Empty = skip.
- name: STORAGE_CLASS_REPLICAS  currently set to '1' (default)
  description: numberOfReplicas for the lab StorageClasses (single node = 1)
  default: "1"
2026-10-19 14:33:22 WRN this package does NOT contain an SBOM. If you require an SBOM, the package must be built without the --skip-sbom flag
2026-10-19 14:33:22 INF starting deploy package=longhorn-lab
2026-10-19 14:33:22 INF waiting for cluster connection
2026-10-19 14:33:22 INF deploying component name=longhorn-preflight
2026-10-19 14:33:22 INF copying files count=1
2026-10-19 14:33:22 INF loading file name=/usr/local/bin/longhornctl
2026-10-19 14:33:22 INF pushing image name=docker.io/longhornio/longhorn-cli:v1.13.0 count=1/1
2026-10-19 14:33:24 INF done pushing images count=1 duration=2s
2026-10-19 14:33:24 INF processing Helm chart name=raw-longhorn-lab-longhorn-preflight-longhorn-namespace source=Zarf-generated
2026-10-19 14:33:24 INF performing Helm upgrade chart=raw-longhorn-lab-longhorn-preflight-longhorn-namespace
2026-10-19 14:33:24 INF running health checks chart=raw-longhorn-lab-longhorn-preflight-longhorn-namespace
2026-10-19 14:33:24 INF running command cmd=longhornctl install preflight (V1 + V2/SPDK prerequisites)
2026-10-19 14:33:24 INF waiting for action cmd=longhornctl install preflight (V1 + V2/SPDK prerequisites) timeout=1800 seconds
time="2026-10-19T14:33:24Z" level=info msg="Initializing preflight installer"
time="2026-10-19T14:33:24Z" level=info msg="Cleaning up preflight installer"
time="2026-10-19T14:33:24Z" level=info msg="Running preflight installer"
time="2026-10-19T14:33:24Z" level=info msg="Installing dependencies with package manager"
time="2026-10-19T14:33:24Z" level=info msg="Kubelet services will be restarted within 10s (if needed)"
time="2026-10-19T14:34:18Z" level=info msg="Installed dependencies with package manager"
time="2026-10-19T14:34:18Z" level=info msg="Retrieved preflight installer result:\nip-10-250-0-10:\n  info:\n  - Successfully probed module nfs\n  - Successfully probed module dm_crypt\n  - Successfully started service iscsid\n  - Successfully probed module nvme_tcp\n  - Successfully probed module uio_pci_generic\n  - Successfully probed module vfio_pci\n  - Successfully probed module ublk_drv\n  - Successfully configured SPDK environment\n  warn:\n  - \"Failed to install package linux-modules-extra-7.0.0-1014-aws: failed after 10 attempts to refresh stale namespace directory: failed to execute: nsenter [--mount=/host/proc/25069/ns/mnt --net=/host/proc/25069/ns/net apt install linux-modules-extra-7.0.0-1014-aws -y], output Reading package lists...\\nBuilding dependency tree...\\nReading state information...\\n, stderr \\nWARNING: apt does not have a stable CLI interface. Use with caution in scripts.\\nE: Unable to locate package linux-modules-extra-7.0.0-1014-aws\\nE: Couldn't find any package by glob 'linux-modules-extra-7.0.0-1014-aws': exit status 100\"\n"
time="2026-10-19T14:34:18Z" level=info msg="Cleaning up preflight installer"
time="2026-10-19T14:34:18Z" level=info msg="Completed preflight installer. Use 'longhornctl check preflight' to check the result (on some os a reboot and a new install execution is required first)"
2026-10-19 14:34:18 INF action succeeded cmd=longhornctl install preflight (V1 + V2/SPDK prerequisites)
2026-10-19 14:34:18 INF running command cmd=Wait for API server and hugepages-2Mi to be advertised after the kubelet restart
2026-10-19 14:34:18 INF waiting for action cmd=Wait for API server and hugepages-2Mi to be advertised after the kubelet restart timeout=1800 seconds
hugepages-2Mi allocatable: 2Gi
2026-10-19 14:34:19 INF action succeeded cmd=Wait for API server and hugepages-2Mi to be advertised after the kubelet restart
2026-10-19 14:34:19 INF running command cmd=longhornctl check preflight (exits 0 even on failure, so grep the per-node error list)
2026-10-19 14:34:19 INF waiting for action cmd=longhornctl check preflight (exits 0 even on failure, so grep the per-node error list) timeout=1800 seconds
time="2026-10-19T14:34:19Z" level=info msg="Initializing preflight checker"
time="2026-10-19T14:34:19Z" level=info msg="Cleaning up preflight checker"
time="2026-10-19T14:34:19Z" level=info msg="Running preflight checker"
time="2026-10-19T14:34:22Z" level=info msg="Retrieved preflight checker result:\nip-10-250-0-10:\n  error:\n  - '[IOMMU] IOMMU is not enabled: no groups found under /sys/kernel/iommu_groups'\n  info:\n  - '[IscsidService] Service iscsid is running'\n  - '[NFSv4] NFS4 is supported'\n  - '[Packages] nfs-common is installed'\n  - '[Packages] open-iscsi is installed'\n  - '[Packages] cryptsetup is installed'\n  - '[Packages] dmsetup is installed'\n  - '[KernelModules] nfs is loaded'\n  - '[KernelModules] dm_crypt is loaded'\n  - '[HugePages] HugePages is enabled'\n  - '[HugePages] Node CR has enough hugepages-2Mi capacity'\n  - '[SPDK][CPUInstructionSet] sse4_2 is supported'\n  - '[SPDK][KernelModules] nvme_tcp is loaded'\n  - '[SPDK][KernelModules] uio_pci_generic is loaded'\n  - '[SPDK][KernelModules] vfio_pci is loaded'\n  - '[SPDK][KernelModules] ublk_drv is loaded'\n  warn:\n  - '[KubeDNS] Kube DNS \"coredns\" is set with fewer than 2 replicas; consider increasing replica count for high availability'\n  - '[MultipathService] multipathd.service is running. Please refer to https://longhorn.io/kb/troubleshooting-volume-with-multipath/ for more information.'\n"
time="2026-10-19T14:34:22Z" level=info msg="Cleaning up preflight checker"
time="2026-10-19T14:34:22Z" level=info msg="Completed preflight checker"
2026-10-19 14:34:22 INF action succeeded cmd=longhornctl check preflight (exits 0 even on failure, so grep the per-node error list)
2026-10-19 14:34:22 INF running command cmd=Declare Longhorn default disks on the node (V1 /var/lib/longhorn + V2 raw block disk)
2026-10-19 14:34:22 INF waiting for action cmd=Declare Longhorn default disks on the node (V1 /var/lib/longhorn + V2 raw block disk) timeout=1800 seconds
node/ip-10-250-0-10 not labeled
node/ip-10-250-0-10 annotated
2026-10-19 14:34:22 INF action succeeded cmd=Declare Longhorn default disks on the node (V1 /var/lib/longhorn + V2 raw block disk)
2026-10-19 14:34:22 INF deploying component name=longhorn-diagnose
2026-10-19 14:34:22 INF copying files count=1
2026-10-19 14:34:23 INF loading file name=/usr/local/bin/longhornctl-diagnose
2026-10-19 14:34:23 INF deploying component name=longhorn
2026-10-19 14:34:23 INF pushing image name=docker.io/longhornio/csi-provisioner:v6.3.0 count=1/13
2026-10-19 14:34:26 INF pushing image name=docker.io/longhornio/csi-resizer:v2.2.1 count=2/13
2026-10-19 14:34:26 INF pushing image name=docker.io/longhornio/longhorn-share-manager:v1.13.0 count=3/13
2026-10-19 14:34:29 INF pushing image name=docker.io/longhornio/csi-attacher:v4.13.0 count=4/13
2026-10-19 14:34:31 INF pushing image name=docker.io/longhornio/csi-snapshotter:v8.6.0 count=5/13
2026-10-19 14:34:31 INF pushing image name=docker.io/longhornio/csi-node-driver-registrar:v2.18.0 count=6/13
2026-10-19 14:34:33 INF pushing image name=docker.io/longhornio/livenessprobe:v2.20.0 count=7/13
2026-10-19 14:34:34 INF pushing image name=docker.io/longhornio/support-bundle-kit:v0.0.98 count=8/13
2026-10-19 14:34:37 INF pushing image name=docker.io/longhornio/backing-image-manager:v1.13.0 count=9/13
2026-10-19 14:34:39 INF pushing image name=docker.io/longhornio/longhorn-engine:v1.13.0 count=10/13
2026-10-19 14:34:42 INF pushing image name=docker.io/longhornio/longhorn-instance-manager:v1.13.0 count=11/13
2026-10-19 14:34:47 INF image push in progress name=docker.io/longhornio/longhorn-instance-manager:v1.13.0 complete=92.8% remaining=35.25 MBs
2026-10-19 14:34:49 INF pushing image name=docker.io/longhornio/longhorn-manager:v1.13.0 count=12/13
2026-10-19 14:34:51 INF pushing image name=docker.io/longhornio/longhorn-ui:v1.13.0 count=13/13
2026-10-19 14:34:53 INF done pushing images count=13 duration=30.1s
2026-10-19 14:34:53 INF processing Helm chart name=longhorn source=https://charts.longhorn.io
2026-10-19 14:34:53 INF performing Helm upgrade chart=longhorn
2026-10-19 14:36:03 INF running health checks chart=longhorn
2026-10-19 14:36:03 INF processing Helm chart name=raw-longhorn-lab-longhorn-longhorn-lab-extras source=Zarf-generated
2026-10-19 14:36:03 INF performing Helm upgrade chart=raw-longhorn-lab-longhorn-longhorn-lab-extras
2026-10-19 14:36:04 INF running health checks chart=raw-longhorn-lab-longhorn-longhorn-lab-extras
2026-10-19 14:36:04 INF running command cmd=Longhorn readiness (longhornctl diagnose if present, else Zarf waits)
2026-10-19 14:36:04 INF waiting for action cmd=Longhorn readiness (longhornctl diagnose if present, else Zarf waits) timeout=1200 seconds
time="2026-10-19T14:36:04Z" level=info msg="Initializing Longhorn diagnoser"
time="2026-10-19T14:36:04Z" level=info msg="Running Longhorn diagnoser"
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=LonghornManager
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=LonghornBackend
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=LonghornNodes
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=EngineImages
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=InstanceManagers
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=CSIDriver
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=CSIPlugin
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=CSIAttacher
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=CSIProvisioner
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=CSIResizer
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=CSISnapshotter
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=LonghornUI
time="2026-10-19T14:36:04Z" level=info msg="Running check" check=Volumes
- name: LonghornManager
  status: pass
  info:
  - DaemonSet longhorn-manager has 1/1 pods ready
- name: LonghornBackend
  status: pass
  info:
  - Service longhorn-backend has 1 ready endpoints
- name: LonghornNodes
  status: warn
  info:
  - 1/1 nodes are ready
  warn:
  - 'Node ip-10-250-0-10 condition Multipathd is false: multipathd is running with a known issue that affects Longhorn. See description and solution at https://longhorn.io/kb/troubleshooting-volume-with-multipath'
- name: EngineImages
  status: pass
  info:
  - EngineImage ei-2e494080 (127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1) is deployed
  - EngineImage ei-50da42d0 (127.0.0.1:31999/longhornio/longhorn-engine:v1.13.0) is deployed
- name: InstanceManagers
  status: pass
  info:
  - 2/2 instance managers are running
- name: CSIDriver
  status: pass
  info:
  - CSIDriver driver.longhorn.io is registered
- name: CSIPlugin
  status: pass
  info:
  - DaemonSet longhorn-csi-plugin has 1/1 pods ready
- name: CSIAttacher
  status: warn
  warn:
  - Deployment csi-attacher has 2/3 pods ready
- name: CSIProvisioner
  status: warn
  warn:
  - Deployment csi-provisioner has 2/3 pods ready
- name: CSIResizer
  status: warn
  warn:
  - Deployment csi-resizer has 2/3 pods ready
- name: CSISnapshotter
  status: warn
  warn:
  - Deployment csi-snapshotter has 2/3 pods ready
- name: LonghornUI
  status: pass
  info:
  - Deployment longhorn-ui has 2/2 pods ready
- name: Volumes
  status: pass
  info:
  - 2 volumes are found, 0 degraded, 0 faulted
time="2026-10-19T14:36:04Z" level=info msg="Longhorn system is healthy"
2026-10-19 14:36:04 INF action succeeded cmd=Longhorn readiness (longhornctl diagnose if present, else Zarf waits)
2026-10-19 14:36:04 INF running command cmd=Wait for the V2 block disk (created from the node annotation; patched in if the node already had disks, e.g. after a Helm takeover)
2026-10-19 14:36:04 INF waiting for action cmd=Wait for the V2 block disk (created from the node annotation; patched in if the node already had disks, e.g. after a Helm takeover) timeout=600 seconds
node.longhorn.io/ip-10-250-0-10 patched (no change)
2026-10-19 14:36:06 INF waiting for resource kind=Node.longhorn.io identifier=ip-10-250-0-10 condition=jsonpath={.status.diskStatus.v2disk.conditions[?(@.type=="Ready")].status}=True namespace=longhorn-system
2026-10-19 14:36:06 INF wait-for condition met kind=Node.longhorn.io identifier=ip-10-250-0-10 condition=jsonpath={.status.diskStatus.v2disk.conditions[?(@.type=="Ready")].status}=True namespace=longhorn-system
2026-10-19 14:36:06 INF action succeeded cmd=Wait for the V2 block disk (created from the node annotation; patched in if the node already had disks, e.g. after a Helm takeover)
2026-10-19 14:36:06 INF running command cmd=Make longhorn-v2 the only default StorageClass (K3s marks local-path as default)
2026-10-19 14:36:06 INF waiting for action (no timeout) cmd=Make longhorn-v2 the only default StorageClass (K3s marks local-path as default)
storageclass.storage.k8s.io/local-path annotated
2026-10-19 14:36:07 INF action succeeded cmd=Make longhorn-v2 the only default StorageClass (K3s marks local-path as default)

     Connect Command          | Description
     zarf connect longhorn-ui | Connect to the Longhorn User Interface


==> Longhorn state
NAME                                            NAMESPACE       REVISION        UPDATED                                 STATUS  CHART                                                                    APP VERSION
longhorn                                        longhorn-system 2               2026-10-19 14:34:54.747305509 +0000 UTC deployedlonghorn-1.13.0                                                          v1.13.0
zarf-1676a4a93e6e0def8bcff1b3d37d6fe5e59c16d6   longhorn-system 2               2026-10-19 14:33:24.499899767 +0000 UTC deployedraw-longhorn-lab-longhorn-preflight-longhorn-namespace-0.1.1792420397
zarf-613764d665189e32bed4a78527dd10f4ffae5ba0   longhorn-system 2               2026-10-19 14:36:03.430101406 +0000 UTC deployedraw-longhorn-lab-longhorn-longhorn-lab-extras-0.1.1792420397
NAME              STATUS   AGE     LABELS
longhorn-system   Active   9m23s   app.kubernetes.io/managed-by=zarf,kubernetes.io/metadata.name=longhorn-system,zarf.dev/agent=mutate
NAME                                  INCOMPATIBLE   STATE      IMAGE                                                REFCOUNT   BUILDDATE   AGE
engineimage.longhorn.io/ei-2e494080   false          deployed   127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1   3          67d         6m45s
engineimage.longhorn.io/ei-50da42d0   false          deployed   127.0.0.1:31999/longhornio/longhorn-engine:v1.13.0   2          20d         24s

NAME                                                                            DATA ENGINE   STATE     TYPE   NODE             AGE
instancemanager.longhorn.io/instance-manager-829b70083c9df12d0ed5a63712b97815   v2            running   aio    ip-10-250-0-10   6m44s
instancemanager.longhorn.io/instance-manager-963e65c34047421d7c7bd1cf1c6d5161   v1            running   aio    ip-10-250-0-10   6m45s
NAME                                       ENGINE   STATE      ROBUST    IMAGE
pvc-79d208f3-08d4-46e2-9fa3-f7a0c55b0d75   v2       attached   healthy   127.0.0.1:31999/longhornio/longhorn-instance-manager:v1.12.1
pvc-cb7942d7-2e12-46f1-a1d3-74d276ce241a   v1       attached   healthy   127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1
ip-10-250-0-10
  filesystem /var/lib/longhorn ready=True
  block /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol050960e6165b3f216 ready=True
NAME                       IMAGE
engine-image-ei-2e494080   127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1
engine-image-ei-50da42d0   127.0.0.1:31999/longhornio/longhorn-engine:v1.13.0
longhorn-csi-plugin        127.0.0.1:31999/longhornio/csi-node-driver-registrar:v2.18.0
longhorn-manager           127.0.0.1:31999/longhornio/longhorn-manager:v1.13.0
csi-attacher               127.0.0.1:31999/longhornio/csi-attacher:v4.13.0
csi-provisioner            127.0.0.1:31999/longhornio/csi-provisioner:v6.3.0
csi-resizer                127.0.0.1:31999/longhornio/csi-resizer:v2.2.1
csi-snapshotter            127.0.0.1:31999/longhornio/csi-snapshotter:v8.6.0
longhorn-driver-deployer   127.0.0.1:31999/longhornio/longhorn-manager:v1.13.0
longhorn-global-manager    127.0.0.1:31999/longhornio/longhorn-manager:v1.13.0
longhorn-ui                127.0.0.1:31999/longhornio/longhorn-ui:v1.13.0
```

</details>

## Step 10: Engine images after the upgrade

The new engine image is deployed alongside the old one; volumes move over through automatic engine upgrade.

```console
$ kubectl -n longhorn-system get engineimages,volumes
NAME          INCOMPATIBLE   STATE      IMAGE                                                REFCOUNT   BUILDDATE   AGE
ei-2e494080   false          deployed   127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1   3          67d         7m7s
ei-50da42d0   false          deployed   127.0.0.1:31999/longhornio/longhorn-engine:v1.13.0   2          20d         46s
NAME                                       ENGINE   STATE      IMAGE
pvc-79d208f3-08d4-46e2-9fa3-f7a0c55b0d75   v2       attached   127.0.0.1:31999/longhornio/longhorn-instance-manager:v1.12.1
pvc-cb7942d7-2e12-46f1-a1d3-74d276ce241a   v1       attached   127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1
```

## Step 11: Verify data survived

Restart podinfo and re-read the payload; read it back from the V2 volume too.

```console
$ curl :30898/store/<hash>
==> Restarting podinfo to prove data is on the Longhorn volume
deployment.apps/podinfo restarted
Waiting for deployment "podinfo" rollout to finish: 0 out of 1 new replicas have been updated...
Waiting for deployment "podinfo" rollout to finish: 0 out of 1 new replicas have been updated...
Waiting for deployment "podinfo" rollout to finish: 0 out of 1 new replicas have been updated...
Waiting for deployment "podinfo" rollout to finish: 0 of 1 updated replicas are available...
Waiting for deployment "podinfo" rollout to finish: 0 of 1 updated replicas are available...
deployment "podinfo" successfully rolled out
podinfo OK: lab-1792420363-25062
statefulset.apps/v2-writer scaled
partitioned roll out complete: 1 new pods have been updated...
V2 volume OK: lab-1792420363-25062
```

## Step 12: Final health check

Everything should pass on 1.13.0.

```console
$ longhornctl diagnose
```

<details><summary>Output (73 lines)</summary>

```console
INFO[2026-10-19T14:38:00Z] Initializing Longhorn diagnoser
INFO[2026-10-19T14:38:00Z] Running Longhorn diagnoser
INFO[2026-10-19T14:38:00Z] Running check                                 check=LonghornManager
INFO[2026-10-19T14:38:00Z] Running check                                 check=LonghornBackend
INFO[2026-10-19T14:38:00Z] Running check                                 check=LonghornNodes
INFO[2026-10-19T14:38:00Z] Running check                                 check=EngineImages
INFO[2026-10-19T14:38:00Z] Running check                                 check=InstanceManagers
INFO[2026-10-19T14:38:00Z] Running check                                 check=CSIDriver
INFO[2026-10-19T14:38:00Z] Running check                                 check=CSIPlugin
INFO[2026-10-19T14:38:00Z] Running check                                 check=CSIAttacher
INFO[2026-10-19T14:38:00Z] Running check                                 check=CSIProvisioner
INFO[2026-10-19T14:38:00Z] Running check                                 check=CSIResizer
INFO[2026-10-19T14:38:00Z] Running check                                 check=CSISnapshotter
INFO[2026-10-19T14:38:00Z] Running check                                 check=LonghornUI
INFO[2026-10-19T14:38:00Z] Running check                                 check=Volumes
- name: LonghornManager
  status: pass
  info:
  - DaemonSet longhorn-manager has 1/1 pods ready
- name: LonghornBackend
  status: pass
  info:
  - Service longhorn-backend has 1 ready endpoints
- name: LonghornNodes
  status: warn
  info:
  - 1/1 nodes are ready
  warn:
  - 'Node ip-10-250-0-10 condition Multipathd is false: multipathd is running with a known issue that affects Longhorn. See description and solution at https://longhorn.io/kb/troubleshooting-volume-with-multipath'
- name: EngineImages
  status: pass
  info:
  - EngineImage ei-2e494080 (127.0.0.1:31999/longhornio/longhorn-engine:v1.12.1) is deployed
  - EngineImage ei-50da42d0 (127.0.0.1:31999/longhornio/longhorn-engine:v1.13.0) is deployed
- name: InstanceManagers
  status: pass
  info:
  - 3/3 instance managers are running
- name: CSIDriver
  status: pass
  info:
  - CSIDriver driver.longhorn.io is registered
- name: CSIPlugin
  status: pass
  info:
  - DaemonSet longhorn-csi-plugin has 1/1 pods ready
- name: CSIAttacher
  status: pass
  info:
  - Deployment csi-attacher has 3/3 pods ready
- name: CSIProvisioner
  status: pass
  info:
  - Deployment csi-provisioner has 3/3 pods ready
- name: CSIResizer
  status: pass
  info:
  - Deployment csi-resizer has 3/3 pods ready
- name: CSISnapshotter
  status: pass
  info:
  - Deployment csi-snapshotter has 3/3 pods ready
- name: LonghornUI
  status: pass
  info:
  - Deployment longhorn-ui has 2/2 pods ready
- name: Volumes
  status: pass
  info:
  - 2 volumes are found, 0 degraded, 0 faulted
INFO[2026-10-19T14:38:00Z] Longhorn system is healthy

Demo complete. Reset for the next run: LAB_WIPE_DISKS=true lab s5
```

</details>
