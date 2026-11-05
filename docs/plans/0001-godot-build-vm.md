# 0001: A Godot build VM on KubeVirt

**Status:** in-progress (steps 1 to 4 committed; step 5, the hand-over, waits on a kubeconfig)

## Goal

A VM called `godot-build` declared in git, so Flux creates it on gandalf and
cloud-init leaves it ready to compile Godot 4.7 and export Windows game builds
the first time I SSH in.

## Context

KubeVirt, CDI, the `longhorn-vm` storage class, the VM UI and the namespace
guardrail are all deployed (see `kubernetes/apps/virtualization/`). The platform
was proven end to end with a throwaway `test1` VM, which commit `7215398`
removed once it had served its purpose. That commit's `vm` app is the template
for this one: a Flux Kustomization, a DataVolume for the disk, and a
VirtualMachine with cloud-init.

What I checked before choosing the OS (all on 2026-11-05):

- Godot 4.7's Linux compile page wants GCC 9+ or Clang 6+, Python 3.9+, SCons
  4.4+, and gives a 14-package apt one-liner for Debian/Ubuntu.
  <https://docs.godotengine.org/en/4.7/_sources/engine_details/development/compiling/compiling_for_linuxbsd.rst.txt>
- The Windows page says cross-compiling from Linux needs `mingw-w64` with the
  posix thread model, GCC 12+, and on Ubuntu the posix alternative has to be
  selected or the build fails.
  <https://docs.godotengine.org/en/4.7/_sources/engine_details/development/compiling/compiling_for_windows.rst.txt>
- Godot's own release containers are Fedora 44 but build Linux with GCC 15.2
  from their buildroot SDK, not Fedora's compiler.
  <https://github.com/godotengine/build-containers>
- Ubuntu 26.04 packages GCC 15.2, SCons 4.8.1 and mingw-w64 13.0, so it matches
  the official toolchain most closely and is an LTS until 2031. Ubuntu 24.04
  (GCC 13.2, SCons 4.5.2) and Debian 13 (GCC 14.2, SCons 4.8.1) also clear the
  floor. We picked 26.04.
- containerdisks publishes `quay.io/containerdisks/ubuntu:26.04-2610230208`.
  The dated tag is a build snapshot that is never republished, so it pins as
  well as a digest without making CDI resolve a manifest list.

Sizing is what Hiemanshu asked for: 36 cores with 2 threads each (72 vCPU),
256 GiB RAM, and a disk that started at 256 GiB and became 100 GiB (see
below). gandalf has 80 threads and 400 GB, so this leaves 8 threads and about
144 GB for everything else on the node. LTO needs about 7 GB per link, so
memory is not the constraint.

The 256 GiB disk never scheduled. The launcher pod sat Pending with "1 node(s)
did not have enough free storage": Longhorn schedules by declared size, not
bytes written, and with `storage-over-provisioning-percentage` at 100 it would
only promise about 222 GiB more on gandalf, where 665 GB of the 957 GB disk was
already spoken for by other replicas. Hiemanshu chose 100 GiB over raising the
over-provisioning setting cluster-wide. At the same time the DataVolume got
`pullMethod: node`, because the default pod pull needs a scratch volume the
same size as the target on the same class and node, which would have doubled
what Longhorn had to find during the import.

The vCPUs are shared, not reserved: an idle VM costs the node almost nothing,
and a build bursts onto whatever is free. Memory is not bursty in the same
way. KubeVirt sets the launcher pod's memory request to the guest size, so the
scheduler counts 256 GiB as taken from the moment the VM runs, whether or not
the guest has touched it.

## Non-goals

- No backup. The disk holds a git checkout and build output, all reproducible,
  so there is no volsync ReplicationSource or ExternalSecret. Add them from the
  `test1` history if that changes.
- No web (Emscripten) or macOS export tooling. Windows is the current target;
  Linux comes free with the editor build.
- No dedicated CPU placement, hugepages or GPU passthrough. Plain shared vCPUs
  are enough for a compile box. Revisit if build times disappoint.
- No static IP or HTTPRoute. The VM is reached over SSH through kubevirt-manager
  or `virtctl`, same as `test1` was.

## What gets built

### `kubernetes/apps/virtualization/vm/ks.yaml`

Flux Kustomization `vm` in namespace `virtualization`, `dependsOn` `cdi`
(virtualization) and `longhorn` (storage), path
`./kubernetes/apps/virtualization/vm/app`, `targetNamespace: virtualization`,
`prune: true`, `wait: false`. Same as the removed one; `wait: false` because a
VM that is still importing its disk must not hold up the Kustomization.

### `kubernetes/apps/virtualization/vm/app/kustomization.yaml`

Lists `datavolume.yaml` and `virtualmachine.yaml`.

### `kubernetes/apps/virtualization/vm/app/datavolume.yaml`

DataVolume `godot-build`, source
`docker://quay.io/containerdisks/ubuntu:26.04-2610230208` with
`pullMethod: node`, storage class `longhorn-vm` set explicitly, request
`100Gi`.

### `kubernetes/apps/virtualization/vm/app/virtualmachine.yaml`

VirtualMachine `godot-build`, `runStrategy: Always`, label
`kubevirt.io/domain: godot-build`, `nodeSelector` `kubernetes.io/hostname: gandalf`.

- `domain.cpu`: `sockets: 1`, `cores: 36`, `threads: 2`.
- `domain.memory.guest: 256Gi` and `resources.requests.memory: 256Gi`.
- One virtio disk `rootdisk` from DataVolume `godot-build`, one masquerade
  interface on the pod network.
- `cloudInitNoCloud.userData`:
  - `package_update: true`, `package_upgrade: true`.
  - `packages:` the 4.7 docs' apt list verbatim (`build-essential scons
    pkg-config libx11-dev libxcursor-dev libxinerama-dev libgl1-mesa-dev
    libglu1-mesa-dev libasound2-dev libpulse-dev libudev-dev libxi-dev
    libxrandr-dev libwayland-dev`) plus `mingw-w64` for Windows templates, and
    `git clang lld` for checkouts and faster link cycles.
  - `ssh_import_id: ["gh:hiemanshu"]`, cloud-init's native way to pull GitHub
    keys for the default `ubuntu` user. No credential in git.
  - `runcmd`: `update-alternatives --set` the four mingw compilers
    (`x86_64-w64-mingw32-gcc`, `-g++`, `i686-w64-mingw32-gcc`, `-g++`) to their
    `-posix` variants, non-interactively.

### `kubernetes/apps/virtualization/vm/app/service.yaml` (added after the first two commits)

Hiemanshu asked for a VIP so the VM has a stable LAN address. This cluster
hands those out with Cilium LB-IPAM plus L2 announcements: a `LoadBalancer`
Service carrying `lbipam.cilium.io/ips: <ip>` from the `192.168.68.0/22` pool,
the same way Plex, k8s-gateway and the two Envoy gateways get theirs
(`.69.2`, `.69.3`, `.69.4`, `.69.6` are taken).

Service `godot-build`, `type: LoadBalancer`, selector
`kubevirt.io/domain: godot-build` (the label on the VMI's launcher pod), port
`22` named `ssh`. Masquerade networking means the guest sits behind the
launcher pod's IP, so a Service on the pod is exactly how traffic reaches it;
no bridge or Multus needed. `externalTrafficPolicy` stays `Cluster`, the
default, because L2 announcement answers from whichever node holds the lease
and the pod is pinned to gandalf anyway.

The IP itself is Hiemanshu's call (open question below).

### `kubernetes/apps/virtualization/kustomization.yaml`

Add `./vm/ks.yaml` to `resources`. Done as its own commit after the app
exists, so a push between the two never leaves Flux pointing at a path that
is not there.

## Steps

1. Write this plan. Commit.
2. Write the four files under `vm/`. Run `kubectl kustomize` on the app
   directory and read the output. Commit as one piece: the app is not
   deployable until step 3, so it is one unit.
3. Add the resource line to the namespace kustomization. Run `kubectl
   kustomize kubernetes/apps/virtualization` and `flux-local test`. Commit.
4. Add `service.yaml` with the VIP, list it in the app kustomization, render
   with `kubectl kustomize`. Commit.
5. Hand over: Hiemanshu pushes, and once a kubeconfig is at hand runs the
   checks below and pastes the output back.

## Test plan

On this machine, no cluster:

- `kubectl kustomize kubernetes/apps/virtualization/vm/app` renders a
  DataVolume and a VirtualMachine with the values above.
- `kubectl kustomize kubernetes/apps/virtualization` renders the new
  Kustomization alongside the existing four.
- The cloud-init block parses as YAML with the four top-level keys
  (`package_update`, `packages`, `ssh_import_id`, `runcmd`).
- `uvx flux-local test --enable-helm --all-namespaces --path
  kubernetes/flux/cluster -v` passes, proving the `dependsOn` targets resolve.
  **Could not run here:** flux-local opens a NamedTemporaryFile and then
  writes to the same path, which Windows refuses, and this machine has no
  docker or WSL to run the CI image. Substituted by hand: both `dependsOn`
  targets exist as Kustomizations `cdi` (virtualization) and `longhorn`
  (storage), the path exists, and kubeconform in strict mode validates the
  Flux Kustomization and Service against the default schemas and the
  VirtualMachine and DataVolume against the datreeio CRDs-catalog schemas
  (the vendored operator manifests only carry the `KubeVirt` and `CDI` CRDs;
  the operators create the rest at runtime). The pull_request workflow runs
  flux-local for real, so open a PR rather than pushing straight to main.

Against the cluster, handed to Hiemanshu:

```sh
flux get kustomizations -n virtualization              # vm: Ready
kubectl get dv -n virtualization godot-build           # phase Succeeded
kubectl get vmi -n virtualization godot-build          # Running, on gandalf
virtctl ssh ubuntu@vmi/godot-build -n virtualization   # or via kubevirt-manager
# inside the VM
cloud-init status --wait --long                        # status: done
nproc; free -g; df -h /                                # 72, ~251, ~97G
gcc --version; scons --version; x86_64-w64-mingw32-gcc --version
x86_64-w64-mingw32-gcc -v 2>&1 | grep -o 'Thread model: posix'
git clone --depth 1 -b 4.7 https://github.com/godotengine/godot && cd godot
scons platform=linuxbsd -j72                            # editor, bin/godot.linuxbsd.editor.x86_64
scons platform=windows target=template_release arch=x86_64 production=yes -j72
```

## Risks

- The VM takes 72 of gandalf's 80 threads with no CPU limit on the pod side,
  so a full-tilt build will contend with whatever else is scheduled there.
  KubeVirt requests the vCPUs but does not reserve cores; if that bites,
  `dedicatedCpuPlacement` is the next step and needs a kubelet CPU manager
  policy change in Talos.
- 256 GiB is reserved for scheduling from the moment the VM runs (see Context),
  so the node's schedulable memory drops by that much even when the guest is
  idle. That leaves about 144 GB, which is enough today.
- `package_upgrade: true` on first boot means cloud-init can take a while
  before SSH keys land. `ssh_import_id` runs late in the boot, after packages,
  so an early SSH attempt will be refused. `cloud-init status --wait` is the
  check.
- A 100Gi thin volume on `longhorn-vm` is single-replica and local to gandalf by
  best effort. If gandalf's disk fills, the VM pauses. Longhorn's own
  over-provisioning setting applies, and it is what capped the first attempt.
- A DataVolume's spec is immutable, so a size change in git does not reach a
  DataVolume that already exists. The Pending one has to be deleted by hand and
  Flux recreates it. Safe while the import has not started; after that it means
  reimporting.
- `ssh_import_id` needs egress to github.com through masquerade networking.
  The `test1` VM curled github.com the same way, so this is known to work.

## Open questions

- Which address from the pool the VIP should use. `.69.5` and `.69.7` upward
  are free as far as git shows; the pool is the whole `/22` so anything not
  handed out by the router works.
- Whether the VIP also wants a DNS name. k8s-gateway watches Services, so it
  may already answer for the Service name under the internal domain; confirm
  what name it uses before relying on it.
- Whether to add `dedicatedCpuPlacement` is a follow-up once the first real
  build has run.
