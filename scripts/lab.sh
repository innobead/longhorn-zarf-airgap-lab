#!/usr/bin/env bash
# Longhorn x Zarf lab driver. Runs on the EC2 node as root (re-execs with sudo).
set -euo pipefail

[[ $EUID -eq 0 ]] || exec sudo -i "$(readlink -f "$0")" "$@"

LAB_DIR=${LAB_DIR:-/opt/lab}
WORK=${WORK:-/var/lib/lab}
BUILD=$WORK/build
OUT=$WORK/out
STATE=$WORK/state
mkdir -p "$BUILD" "$OUT" "$STATE"

export HOME=${HOME:-/root}
export KUBECONFIG=${KUBECONFIG:-/root/.kube/config}
export PATH=$PATH:/usr/sbin:/usr/local/bin
[[ -f /etc/longhorn-lab.env ]] && source /etc/longhorn-lab.env

# Install = latest stable 1.12.x, upgrade = latest stable 1.13.x (resolved from GitHub releases
# by `lab prep`, then pinned in $STATE/versions.env so nothing needs GitHub once air-gapped).
# Set LH_FROM / LH_TO to pin exact versions instead.
LH_FROM_MINOR=${LH_FROM_MINOR:-1.12}
LH_TO_MINOR=${LH_TO_MINOR:-1.13}
LH_FROM_FALLBACK=1.12.1
LH_TO_FALLBACK=1.13.0
# longhorn/longhorn#3355: `longhornctl diagnose`, planned for v1.14.0. Set empty to skip.
DIAGNOSE_IMAGE=${DIAGNOSE_IMAGE-longhornio/longhorn-cli:v1.14.0-dev-20261004}
DEMO_SC=${DEMO_SC:-longhorn}
TIMEOUT=${TIMEOUT:-20m}

case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac

k() { zarf tools kubectl "$@"; }
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
pkg_longhorn() { echo "$OUT/zarf-package-longhorn-lab-$ARCH-$1.tar.zst"; }
pkg_demo() { echo "$OUT/zarf-package-gitops-demo-$ARCH-0.1.0.tar.zst"; }

url_ok() { curl -fsIL -o /dev/null --retry 2 "$1"; }
online() { curl -fsS -o /dev/null -m 5 https://github.com 2>/dev/null; }

# Packages are built online by `lab prep`; once air-gapped a missing one is fatal.
ensure_pkg() {   # ensure_pkg <file> <build fn> [args...]
  local f=$1; shift
  [[ -f "$f" ]] && return 0
  online || die "$(basename "$f") was not built before the air gap; reconnect (airgap = false) and run 'lab prep'"
  "$@"
}

# Namespaces Zarf did not create have no registry pull secret; copy Zarf's (as Zarf would).
copy_pull_secret() {
  k -n zarf get secret private-registry -o json \
    | jq --arg ns "$1" '{apiVersion, kind, type, data,
        metadata: {name: .metadata.name, namespace: $ns, labels: .metadata.labels}}' \
    | k apply -f -
}

# Newest stable X.Y.Z for a minor that also has its chart and longhornctl published.
latest_patch() {
  local minor=$1 fallback=$2 v
  local tags
  tags=$(curl -fsSL --retry 3 "https://api.github.com/repos/longhorn/longhorn/releases?per_page=100" 2>/dev/null \
    | jq -r '.[] | select(.draft==false and .prerelease==false) | .tag_name' 2>/dev/null \
    | sed 's/^v//' | grep -E "^${minor//./\\.}\.[0-9]+$" | sort -rV) || true
  for v in $tags; do
    if url_ok "https://github.com/longhorn/charts/releases/download/longhorn-$v/longhorn-$v.tgz" \
       && url_ok "https://github.com/longhorn/cli/releases/download/v$v/longhornctl-linux-$ARCH"; then
      echo "$v"; return
    fi
    echo "skip $v: chart or longhornctl not published" >&2
  done
  echo "WARN: could not resolve latest $minor.x, using $fallback" >&2
  echo "$fallback"
}

resolve_versions() {
  if [[ -f "$STATE/versions.env" ]]; then
    local f t; f=$(. "$STATE/versions.env"; echo "$LH_FROM"); t=$(. "$STATE/versions.env"; echo "$LH_TO")
    LH_FROM=${LH_FROM:-$f}; LH_TO=${LH_TO:-$t}
  fi
  LH_FROM=${LH_FROM:-$(latest_patch "$LH_FROM_MINOR" "$LH_FROM_FALLBACK")}
  LH_TO=${LH_TO:-$(latest_patch "$LH_TO_MINOR" "$LH_TO_FALLBACK")}
  log "Versions: install $LH_FROM -> upgrade $LH_TO"
}

# --- init / build ---------------------------------------------------------------

cmd_init() {
  if k get ns zarf >/dev/null 2>&1; then log "Zarf already initialized"; return; fi
  mkdir -p /opt/zarf-init && cd /opt/zarf-init
  if [[ -z "$(ls zarf-init-*.tar.zst 2>/dev/null)" ]]; then
    online || die "no init package in /opt/zarf-init and no internet"
    zarf tools download-init -o /opt/zarf-init
  fi
  zarf init --confirm --components k3s,git-server
}

cmd_build() {
  local ver=${1:?version}; shift || true
  local diag=$DIAGNOSE_IMAGE
  [[ "${1:-}" == "--no-diagnose" ]] && diag=""
  local dir=$BUILD/longhorn-$ver
  log "Building Longhorn $ver package ($dir)"
  rm -rf "$dir" && cp -r "$LAB_DIR/packages/longhorn" "$dir" && cd "$dir"

  curl -fsSL -o images.txt "https://github.com/longhorn/longhorn/releases/download/v$ver/longhorn-images.txt"
  grep -v -e '^\s*$' -e 'longhorn-cli:' images.txt | sed 's/^/- /' > images.yaml
  yq -i '(.components[] | select(.name == "longhorn") | .images) = load("images.yaml")' zarf.yaml

  if [[ -n "$diag" ]]; then
    log "Extracting longhornctl (diagnose) from $diag"
    mkdir -p bin tmp
    zarf tools registry export --platform "linux/$ARCH" "$diag" - | tar -xf - -C tmp usr/local/bin/longhornctl
    mv tmp/usr/local/bin/longhornctl bin/longhornctl-diagnose && rm -rf tmp
    chmod +x bin/longhornctl-diagnose
    bin/longhornctl-diagnose diagnose --help >/dev/null || die "$diag has no 'diagnose' subcommand"
  else
    yq -i 'del(.components[] | select(.name == "longhorn-diagnose"))' zarf.yaml
  fi

  zarf package create . --confirm --skip-sbom -o "$OUT" \
    --set LONGHORN_VERSION="$ver" --set ARCH="$ARCH"
  ls -lh "$(pkg_longhorn "$ver")"
}

cmd_build_demo() {
  log "Building GitOps demo package"
  zarf package create "$LAB_DIR/packages/gitops-demo" --confirm --skip-sbom -o "$OUT" --set ARCH="$ARCH"
}

# --- deploy / remove --------------------------------------------------------------

cmd_deploy() {
  local ver=${1:?version}; shift || true
  local pkg; pkg=$(pkg_longhorn "$ver")
  ensure_pkg "$pkg" cmd_build "$ver"
  log "zarf package deploy longhorn-lab $ver $*"
  zarf package deploy "$pkg" --confirm --timeout "$TIMEOUT" \
    --set-variables V2_DISK_PATH="${V2_DISK_PATH:-}" "$@"
  cmd_info
}

cmd_deploy_demo() {
  local sc=${1:-$DEMO_SC}
  ensure_pkg "$(pkg_demo)" cmd_build_demo
  log "Deploying GitOps demo (StorageClass=$sc)"
  zarf package deploy "$(pkg_demo)" --confirm --timeout "$TIMEOUT" --set-variables STORAGE_CLASS="$sc"
  k -n podinfo get gitrepository,kustomization,pvc,pod
}

cmd_remove_demo() {
  log "Removing GitOps demo"
  zarf package remove gitops-demo --confirm || true
}

# The chart's uninstall job reads deleting-confirmation-flag from an informer (apiserver watch
# cache), which can lag behind the write, e.g. right after the demo's Flux CRDs were deleted.
confirm_deleting() {
  k -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag --type merge -p '{"value":"true"}'
  local url=/apis/longhorn.io/v1beta2/namespaces/longhorn-system/settings/deleting-confirmation-flag?resourceVersion=0
  for _ in $(seq 1 30); do
    k get --raw "$url" | grep -q '"value":"true"' && return 0
    sleep 2
  done
  die "deleting-confirmation-flag not visible in the watch cache"
}

cmd_remove() {
  log "Removing Longhorn (LAB_WIPE_DISKS=${LAB_WIPE_DISKS:-false})"
  if zarf package list 2>/dev/null | grep -q longhorn-lab; then
    confirm_deleting
    zarf package remove longhorn-lab --confirm
  elif helm status longhorn -n longhorn-system >/dev/null 2>&1; then
    confirm_deleting
    helm uninstall longhorn -n longhorn-system --wait --timeout 10m
    k delete ns longhorn-system --ignore-not-found --wait=true
  fi
  log "Leftovers check"
  k get crd -o name | grep longhorn.io && echo "WARN: Longhorn CRDs remain" || echo "no Longhorn CRDs"
  k get ns longhorn-system 2>/dev/null && echo "WARN: namespace remains" || echo "longhorn-system gone"
}

# Inputs for the plain-Helm path (s3): the chart and longhornctl, fetched by `lab prep`.
helm_chart() { echo "$OUT/longhorn-$1.tgz"; }
helm_ctl() { echo "$OUT/longhornctl-$1"; }
stage_helm_assets() {
  local ver=$1
  log "Staging Helm chart + longhornctl $ver"
  curl -fsSL -o "$(helm_chart "$ver")" "https://github.com/longhorn/charts/releases/download/longhorn-$ver/longhorn-$ver.tgz"
  curl -fsSL -o "$(helm_ctl "$ver")" "https://github.com/longhorn/cli/releases/download/v$ver/longhornctl-linux-$ARCH"
  chmod +x "$(helm_ctl "$ver")"
}

# Plain Helm install (not Zarf), the way a site with a private registry would do it: images
# are pushed to the registry first (`zarf package mirror-resources`), then the stock chart is
# installed. The Zarf agent rewrites image refs to that registry, so nothing is pulled from
# the internet.
cmd_helm_install() {
  local ver=${1:?version}
  local pkg; pkg=$(pkg_longhorn "$ver")
  ensure_pkg "$pkg" cmd_build "$ver"
  ensure_pkg "$(helm_chart "$ver")" stage_helm_assets "$ver"
  log "Plain Helm install of Longhorn $ver"
  k get ns longhorn-system >/dev/null 2>&1 && die "longhorn-system exists; run 'lab remove' first"

  log "Mirroring the $ver images into the in-cluster registry"
  zarf package mirror-resources "$pkg" --images --confirm
  k create ns longhorn-system
  copy_pull_secret longhorn-system

  install -m 0755 "$(helm_ctl "$ver")" /usr/local/bin/longhornctl
  longhornctl install preflight --image "longhornio/longhorn-cli:v$ver" \
    --enable-spdk --huge-page-size 2048 --spdk-options PERSIST_HUGE=yes \
    --restart-kubelet --restart-kubelet-window 10s
  until k get --raw /readyz >/dev/null 2>&1; do sleep 3; done
  longhornctl check preflight --image "longhornio/longhorn-cli:v$ver" --enable-spdk --huge-page-size 2048

  # Like a typical existing Helm install: no node label, so Longhorn creates the usual default
  # disk and the V2 disk is patched in. The Zarf takeover then exercises its patch fallback.
  # Point the chart at the registry, as a site would with its private registry. Relying on the
  # Zarf agent to rewrite images breaks Longhorn: the manager compares its pod image with the
  # unrewritten --manager-image arg and waits forever for "old" managers (itself) to go away.
  local registry
  registry=$(k -n zarf get secret zarf-state -o jsonpath='{.data.state}' | base64 -d | jq -r .registryInfo.address)
  REGISTRY=$registry yq 'del(.global) | .global.imageRegistry = strenv(REGISTRY)
      | del(.defaultSettings.createDefaultDiskLabeledNodes)' \
    "$LAB_DIR/packages/longhorn/values-lab.yaml" > "$BUILD/values-plain.yaml"
  helm install longhorn "$(helm_chart "$ver")" \
    -n longhorn-system -f "$BUILD/values-plain.yaml" --wait --timeout 15m
  sed 's/###ZARF_VAR_STORAGE_CLASS_REPLICAS###/1/' "$LAB_DIR/packages/longhorn/manifests/storageclass-v2.yaml" | k apply -f -
  k annotate storageclass local-path storageclass.kubernetes.io/is-default-class=false --overwrite
  add_v2_disk
  cmd_info
}

add_v2_disk() {
  [[ -n "${V2_DISK_PATH:-}" ]] || { echo "no V2 disk"; return; }
  local node; node=$(k get nodes -o jsonpath='{.items[0].metadata.name}')
  zarf tools wait-for resource nodes.longhorn.io "$node" '{.status.conditions[?(@.type=="Ready")].status}'=True -n longhorn-system --timeout 10m
  local patch="{\"spec\":{\"disks\":{\"v2disk\":{
    \"path\":\"$V2_DISK_PATH\",\"diskType\":\"block\",\"diskDriver\":\"aio\",
    \"allowScheduling\":true,\"evictionRequested\":false,\"storageReserved\":0,\"tags\":[]}}}}"
  # The Longhorn webhook rejects disk edits while the node's disk spec/status is still syncing.
  local i
  for i in $(seq 1 30); do
    k -n longhorn-system patch nodes.longhorn.io "$node" --type merge -p "$patch" && break
    [[ $i -eq 30 ]] && die "failed to add V2 disk"
    sleep 10
  done
  zarf tools wait-for resource nodes.longhorn.io "$node" \
    '{.status.diskStatus.v2disk.conditions[?(@.type=="Ready")].status}'=True -n longhorn-system --timeout 8m
}

# --- checks -----------------------------------------------------------------------

cmd_diagnose() {
  if [[ -x /usr/local/bin/longhornctl-diagnose ]]; then
    # After an upgrade or workload restart, new instance managers may still be starting.
    local i
    for i in $(seq 1 "${LAB_DIAG_RETRIES:-40}"); do
      /usr/local/bin/longhornctl-diagnose diagnose "$@" && return 0
      echo "diagnose not healthy yet (attempt $i), retrying in 15s"; sleep 15
    done
    die "longhornctl diagnose still unhealthy"
  else
    echo "longhornctl-diagnose not installed (build without --no-diagnose)"; k -n longhorn-system get pods
  fi
}

cmd_info() {
  log "Longhorn state"
  helm list -n longhorn-system || true
  k get ns longhorn-system --show-labels 2>/dev/null || true
  k -n longhorn-system get engineimages.longhorn.io,instancemanagers.longhorn.io 2>/dev/null || true
  k -n longhorn-system get volumes.longhorn.io \
    -o custom-columns=NAME:.metadata.name,ENGINE:.spec.dataEngine,STATE:.status.state,ROBUST:.status.robustness,IMAGE:.status.currentImage 2>/dev/null || true
  k -n longhorn-system get nodes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.diskStatus.*}{"  "}{.diskType}{" "}{.diskPath}{" ready="}{.conditions[?(@.type=="Ready")].status}{"\n"}{end}{end}' 2>/dev/null || true
  k -n longhorn-system get ds,deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image 2>/dev/null || true
}

podinfo() { curl -fsS --retry 30 --retry-delay 5 --retry-all-errors "http://127.0.0.1:30898$1" "${@:2}"; }

cmd_write() {
  local payload="lab-$(date +%s)-$RANDOM"
  local hash; hash=$(podinfo /store -X POST -d "$payload" | jq -r .hash)
  echo "$payload" > "$STATE/podinfo.payload"; echo "$hash" > "$STATE/podinfo.hash"
  log "podinfo stored '$payload' as $hash"

  if [[ -n "${V2_DISK_PATH:-}" ]]; then
    # busybox ships in the gitops-demo package; the agent rewrites it to the Zarf registry.
    k create ns v2-test --dry-run=client -o yaml | k apply -f -
    copy_pull_secret v2-test
    k apply -f "$LAB_DIR/tests/v2-workload.yaml"
    k -n v2-test rollout status sts/v2-writer --timeout 10m
    k -n v2-test exec v2-writer-0 -- sh -c "echo $payload > /data/payload && sync && md5sum /data/payload"
  fi
}

cmd_verify() {
  local hash payload got
  hash=$(cat "$STATE/podinfo.hash"); payload=$(cat "$STATE/podinfo.payload")
  log "Restarting podinfo to prove data is on the Longhorn volume"
  k -n podinfo rollout restart deploy/podinfo && k -n podinfo rollout status deploy/podinfo --timeout 10m
  got=$(podinfo "/store/$hash")
  [[ "$got" == "$payload" ]] && echo "podinfo OK: $got" || die "podinfo data mismatch: '$got' != '$payload'"

  if k get ns v2-test >/dev/null 2>&1; then
    k -n v2-test scale sts/v2-writer --replicas 1
    k -n v2-test rollout status sts/v2-writer --timeout 10m
    got=$(k -n v2-test exec v2-writer-0 -- cat /data/payload)
    [[ "$got" == "$payload" ]] && echo "V2 volume OK: $got" || die "V2 data mismatch"
  fi
}

# V2 live engine upgrade support varies by release; LAB_DETACH_V2=true detaches first.
detach_v2() {
  [[ "${LAB_DETACH_V2:-false}" == "true" ]] && k get ns v2-test >/dev/null 2>&1 || return 0
  log "Detaching V2 workload before upgrade"
  k -n v2-test scale sts/v2-writer --replicas 0
  k -n v2-test wait --for=delete pod/v2-writer-0 --timeout 5m || true
}

# --- prep (online) / air-gap check -------------------------------------------------

cmd_prep() {
  online || die "lab prep needs internet; set airgap = false and terraform apply"
  rm -f "$STATE/versions.env"
  resolve_versions
  printf 'LH_FROM=%s\nLH_TO=%s\n' "$LH_FROM" "$LH_TO" > "$STATE/versions.env"
  cmd_init
  [[ -f "$(pkg_longhorn "$LH_FROM")" ]] || cmd_build "$LH_FROM"
  [[ -f "$(pkg_longhorn "$LH_TO")" ]] || cmd_build "$LH_TO"
  [[ -f "$(pkg_demo)" ]] || cmd_build_demo
  [[ -f "$(helm_chart "$LH_FROM")" ]] || stage_helm_assets "$LH_FROM"
  log "Prep done ($LH_FROM -> $LH_TO). Everything below is all the node needs:"
  ls -lh "$OUT" /opt/zarf-init
  echo
  echo "Cut the cord: set airgap = true in terraform.tfvars, then terraform apply."
}

# Exit 0 only when the internet is unreachable. SSM and S3 stay reachable via VPC endpoints.
cmd_airgap_check() {
  local u blocked=0 open=0
  for u in https://github.com https://registry-1.docker.io/v2/ https://ghcr.io/v2/ \
           https://charts.longhorn.io https://archive.ubuntu.com; do
    if curl -sS -o /dev/null -m 5 "$u" 2>/dev/null; then
      printf '  \033[1;31mREACHABLE\033[0m  %s\n' "$u"; open=$((open + 1))
    else
      printf '  \033[1;32mblocked\033[0m    %s\n' "$u"; blocked=$((blocked + 1))
    fi
  done
  if aws s3 ls --region "$LAB_REGION" "s3://$LAB_BUCKET/" >/dev/null 2>&1; then
    echo "  reachable  s3://$LAB_BUCKET (VPC gateway endpoint)"
  fi
  if [[ $open -eq 0 ]]; then
    log "AIR-GAPPED: no internet access"
  else
    printf '\033[1;33mCONNECTED: %d of %d internet endpoints reachable\033[0m\n' "$open" $((open + blocked))
    return 1
  fi
}

# Scenarios only prove something when run offline. LAB_ALLOW_ONLINE=true overrides.
require_airgap() {
  [[ "${LAB_ALLOW_ONLINE:-false}" == "true" ]] && return 0
  cmd_airgap_check || die "node is online; cut the cord first (airgap = true, terraform apply) or set LAB_ALLOW_ONLINE=true"
}

# --- scenarios ---------------------------------------------------------------------

cmd_s1() {   # Zarf install + GitOps demo
  require_airgap
  cmd_init
  cmd_deploy "$LH_FROM"
  cmd_deploy_demo
  cmd_write
  cmd_diagnose
}

cmd_s2() {   # Zarf upgrade (one minor at a time)
  detach_v2
  cmd_deploy "$LH_TO"
  cmd_verify
  cmd_diagnose
}

cmd_s3() {   # Plain Helm install, then Zarf takes ownership at the same version
  require_airgap
  cmd_helm_install "$LH_FROM"
  cmd_deploy_demo
  cmd_write
  k -n longhorn-system get engineimages.longhorn.io -o wide | tee "$STATE/engineimages.before"
  # If the takeover changes image refs, Longhorn starts new instance managers, and a new V2
  # IM cannot start while the old one still serves an attached V2 volume. Detach to be safe.
  LAB_DETACH_V2=true detach_v2
  log "Zarf takeover (--take-ownership --force-conflicts) of the Helm release"
  # The Helm 4 CLI installs with server-side apply under the "helm" field manager; Zarf's
  # SSA upgrade conflicts on those fields unless it is allowed to take them over.
  cmd_deploy "$LH_FROM" --take-ownership --force-conflicts
  k -n longhorn-system get engineimages.longhorn.io -o wide | tee "$STATE/engineimages.after"
  cmd_verify
  cmd_diagnose
}

cmd_s4() {   # upgrade the taken-over release
  # The "helm" field manager still co-owns fields (e.g. helm.sh/chart labels) after the
  # takeover, so the first SSA upgrade through Zarf needs --force-conflicts too.
  detach_v2
  cmd_deploy "$LH_TO" --force-conflicts
  cmd_verify
  cmd_diagnose
}

cmd_s5() {   # uninstall
  k delete ns v2-test --ignore-not-found --wait=true
  cmd_remove_demo
  cmd_remove
}

cmd_all() {
  cmd_s1; cmd_s2; LAB_WIPE_DISKS=true cmd_s5
  cmd_s3; cmd_s4; LAB_WIPE_DISKS=true cmd_s5
  log "All scenarios passed"
}

# --- interactive live demo -----------------------------------------------------------
# Needs `lab prep` (online) and an air-gapped node. `lab demo` walks through air-gap proof ->
# install -> diagnose -> GitOps -> write -> upgrade -> verify, pausing before each step.
# DEMO_AUTO=true runs without pauses (rehearsal).

DEMO_N=0

demo_pause() {
  [[ "${DEMO_AUTO:-false}" == "true" || ! -t 0 ]] && return 0
  local a
  read -r -p $'\033[2m  [Enter] run · s skip · q quit > \033[0m' a
  case "$a" in s|S) return 1 ;; q|Q) echo "bye"; exit 0 ;; esac
}

# step <title> <why> <shown command> <function> [args...]
demo_step() {
  local title=$1 why=$2 shown=$3; shift 3
  DEMO_N=$((DEMO_N + 1))
  printf '\n\033[1;35m━━━ Step %d: %s ━━━\033[0m\n' "$DEMO_N" "$title"
  printf '%s\n' "$why" | fold -s -w 100 | sed 's/^/  /'
  printf '\033[1;33m  $ %s\033[0m\n' "$shown"
  demo_pause || { echo "  (skipped)"; return 0; }
  "$@"
}

demo_airgap() {
  if [[ "${LAB_ALLOW_ONLINE:-false}" == "true" ]]; then cmd_airgap_check || true; else cmd_airgap_check; fi
}

demo_show_cluster() {
  k get nodes -o wide
  zarf package list
  k -n zarf get pods
}

demo_show_package() {
  local pkg; pkg=$(pkg_longhorn "$LH_FROM")
  zarf package inspect definition "$pkg" --no-color 2>/dev/null | yq '.components[] | {
    "component": .name,
    "files": [(.files // [])[].target],
    "deployHooks": [(.actions.onDeploy.after // [])[].description],
    "removeHooks": [(.actions.onRemove.before // [])[].description, (.actions.onRemove.after // [])[].description]
  }'
  echo; zarf package inspect images "$pkg" --no-color 2>/dev/null
}

demo_show_gitops() {
  echo "GitRepository URL (rewritten by the Zarf agent to the in-cluster Gitea):"
  k -n podinfo get gitrepository podinfo -o jsonpath='  {.spec.url}{"\n"}'
  k -n podinfo get gitrepository,kustomization
  k -n podinfo get pvc -o custom-columns=PVC:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase,VOLUME:.spec.volumeName
  echo; echo "podinfo image: the Deployment keeps the upstream reference; the Zarf agent rewrites the Pod to its registry:"
  k -n podinfo get deploy podinfo -o jsonpath='  Deployment: {.spec.template.spec.containers[0].image}{"\n"}'
  k -n podinfo get pod -l app=podinfo -o jsonpath='  Pod:        {.items[0].spec.containers[0].image}{"\n"}'
}

demo_show_engines() {
  k -n longhorn-system get engineimages.longhorn.io
  k -n longhorn-system get volumes.longhorn.io \
    -o custom-columns=NAME:.metadata.name,ENGINE:.spec.dataEngine,STATE:.status.state,IMAGE:.status.currentImage
}

cmd_demo() {
  [[ -f "$(pkg_longhorn "$LH_FROM")" && -f "$(pkg_longhorn "$LH_TO")" && -f "$(pkg_demo)" ]] \
    || die "packages not built; reconnect and run 'lab prep' first"
  k get ns longhorn-system >/dev/null 2>&1 \
    && die "Longhorn already installed; reset with: LAB_FORCE_REMOVE=true LAB_WIPE_DISKS=true lab s5"

  printf '\n\033[1mLonghorn x Zarf live demo: install %s, GitOps app, upgrade to %s\033[0m\n' "$LH_FROM" "$LH_TO"
  printf '  Tip: on your laptop, scripts/ssm.sh ui (Longhorn UI :8080) and scripts/ssm.sh podinfo (:9898)\n'

  demo_step "Proof: this node is air-gapped" \
    "The VPC route table has no internet route. GitHub, Docker Hub, GHCR and the Longhorn chart repo are unreachable; only AWS SSM and S3 VPC endpoints remain." \
    "lab airgap-check" demo_airgap
  demo_step "The air-gapped starting point" \
    "Single-node K3s initialized by Zarf: an in-cluster registry, Gitea, and the Zarf agent, which rewrites image and git references to point at them." \
    "kubectl get nodes; zarf package list" demo_show_cluster
  demo_step "What's inside the Longhorn package" \
    "One self-contained archive: the chart, every image, longhornctl, and lifecycle hooks (preflight install/check, readiness via longhornctl diagnose, V2 disk registration, safe uninstall)." \
    "zarf package inspect definition|images $(basename "$(pkg_longhorn "$LH_FROM")")" demo_show_package
  demo_step "Install Longhorn $LH_FROM" \
    "Zarf pushes the images to its registry, runs longhornctl install/check preflight (V1 + V2/SPDK), installs the chart, then blocks until longhornctl diagnose reports healthy." \
    "zarf package deploy $(basename "$(pkg_longhorn "$LH_FROM")") --confirm" cmd_deploy "$LH_FROM"
  demo_step "Health check" \
    "longhornctl diagnose (v1.14.0-dev, longhorn/longhorn#3355) checks managers, instance managers, CSI, engine images and volumes in one shot." \
    "longhornctl diagnose" cmd_diagnose
  demo_step "GitOps: Flux deploys podinfo from Gitea" \
    "The demo package mirrors the podinfo git repo into Gitea. Flux reconciles it, and the app's data lives on a Longhorn PVC. Note the rewritten git URL and image." \
    "zarf package deploy $(basename "$(pkg_demo)") --confirm" cmd_deploy_demo
  demo_step "Inspect the GitOps wiring" \
    "No internet involved: the git source, the image and the volume all come from inside the cluster." \
    "kubectl -n podinfo get gitrepository,kustomization,pvc" demo_show_gitops
  demo_step "Write data" \
    "Store a payload through the podinfo API (V1 volume) and write the same payload to a V2 (SPDK) volume." \
    "curl -X POST :30898/store -d <payload>" cmd_write
  demo_step "Upgrade Longhorn to $LH_TO" \
    "Same command as the install, just a newer package. Zarf upgrades the Helm release in place, and the hooks re-run preflight and diagnose." \
    "zarf package deploy $(basename "$(pkg_longhorn "$LH_TO")") --confirm" cmd_deploy "$LH_TO"
  demo_step "Engine images after the upgrade" \
    "The new engine image is deployed alongside the old one; volumes move over through automatic engine upgrade." \
    "kubectl -n longhorn-system get engineimages,volumes" demo_show_engines
  demo_step "Verify data survived" \
    "Restart podinfo and re-read the payload; read it back from the V2 volume too." \
    "curl :30898/store/<hash>" cmd_verify
  demo_step "Final health check" "Everything should pass on $LH_TO." "longhornctl diagnose" cmd_diagnose

  printf '\n\033[1;32mDemo complete.\033[0m Reset for the next run: LAB_WIPE_DISKS=true lab s5\n'
}

cmd_sync() {
  aws s3 sync --region "$LAB_REGION" --delete "s3://$LAB_BUCKET/" "$LAB_DIR/"
  chmod +x "$LAB_DIR"/scripts/*.sh
}

usage() {
  cat <<EOF
usage: lab <command> [args]
  init                      zarf init (k3s + registry + gitea) if needed
  build <ver> [--no-diagnose]   build Longhorn package (images from longhorn-images.txt)
  build-demo                build Flux + podinfo GitOps package
  deploy <ver> [zarf flags] deploy/upgrade Longhorn via Zarf (e.g. --take-ownership)
  helm-install <ver>        plain Helm install (images via mirror-resources + the Zarf agent)
  deploy-demo [sc]          deploy GitOps demo (sc: longhorn | longhorn-v2)
  write | verify            write data / restart + verify data
  diagnose | info           longhornctl diagnose / show Longhorn state
  remove-demo | remove      uninstall demo / Longhorn (LAB_WIPE_DISKS=true wipes disks)
  versions                  show resolved install/upgrade versions
  s1..s5 | all              scenarios: install latest $LH_FROM_MINOR.x, upgrade to latest $LH_TO_MINOR.x
                            (<ver> args also accept 'from' / 'to'; pin with LH_FROM=/LH_TO=)
  prep                      ONLINE: zarf init, pin versions, build all packages + Helm assets
  airgap-check              prove the internet is unreachable (scenarios require it;
                            LAB_ALLOW_ONLINE=true to bypass)
  demo                      interactive live demo (DEMO_AUTO=true: no pauses)
  sync                      re-pull lab files from S3
EOF
}

cmd=${1:-help}; shift || true
case "$cmd" in
  s1|s2|s3|s4|s5|all|versions|demo) resolve_versions ;;
  build|deploy|helm-install)
    case "${1:-}" in
      from) resolve_versions; set -- "$LH_FROM" "${@:2}" ;;
      to)   resolve_versions; set -- "$LH_TO" "${@:2}" ;;
    esac ;;
esac
case "$cmd" in
  versions) ;;
  init|build|deploy|diagnose|info|write|verify|remove|sync|s1|s2|s3|s4|s5|all) "cmd_$cmd" "$@" ;;
  build-demo) cmd_build_demo ;;
  prep) cmd_prep ;;
  airgap-check) cmd_airgap_check ;;
  demo) cmd_demo ;;
  deploy-demo) cmd_deploy_demo "$@" ;;
  remove-demo) cmd_remove_demo ;;
  helm-install) cmd_helm_install "$@" ;;
  *) usage ;;
esac
