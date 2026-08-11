# Storage layout — where the heavy state goes

Two settings decide whether this deployment fits on its disk. Both are native
options of the components involved; neither is a mount.

## The problem

The usual VM shape is a small root disk and a large data volume:

```
/dev/vda2    30G   /          OS
/dev/vdb    492G   /data      everything we actually write
```

Nothing in k0s or local-path-provisioner knows about that split. Left at their
defaults they write to the **root** disk:

| Path | What lands there | Size |
|---|---|---|
| `/var/lib/k0s` | containerd image store, etcd/kine, kubelet root-dir | GBs of images |
| `/opt/local-path-provisioner` | every PVC | Prometheus 20Gi, Loki 10Gi, Grafana 5Gi, Alertmanager 2Gi, each hosted control plane's etcd |

A 30G root does not hold the container images alone. When it fills, the kubelet
and the API server go down together.

## The setting

One key in the management site file:

```yaml
storage:
  dataRoot: /data      # "" keeps everything on the root filesystem
```

`install.sh` exports it as `DATA_ROOT` and `scripts/01-install-k0s.sh` applies it
in two places:

| Consumer | Mechanism | Result |
|---|---|---|
| k0s | `k0s install controller --data-dir ${DATA_ROOT}/k0s` | containerd, etcd/kine and kubelet all move — k0s puts kubelet under `<data-dir>/kubelet`, so one flag covers all three |
| local-path-provisioner | patch `nodePathMap.paths` in the `local-path-config` ConfigMap | every PVC provisions under `${DATA_ROOT}/local-path` |

SeaweedFS already points at the volume through `seaweedfs.storage.hostPath:
/data/seaweedfs` in the site file, and needs no separate setting.

`scripts/uninstall.sh` reads the same key and passes `--data-dir` to `k0s reset`.
That matters: `k0s reset` defaults the flag to `/var/lib/k0s` **independently of
how the node was installed**, so on a relocated install a bare `k0s reset` cleans
a directory that was never used and leaves the real state behind.

## Both settings are install-time only

- `k0s install --data-dir` is baked into the systemd unit. `k0s install
  controller --help` says outright: *"DO NOT CHANGE for an existing setup,
  things will break!"*
- local-path-provisioner writes the host path into each **PV object**. Changing
  `nodePathMap` later strands existing volumes at the old path.

So `dataRoot` must be set before the first install. `scripts/01-install-k0s.sh`
only applies it inside its `k0s status` / `kubectl get sc local-path` guards,
which means re-running the installer on an existing node leaves the current
layout authoritative rather than half-migrating it.

## Why not bind mounts

Because it was tried, and it cost a node.

The June 2026 deployment of `ais-edge-dev` put the data on `vdb` with two fstab
bind mounts, added by hand four minutes before the install:

```
/data/k0s        /var/lib/k0s                 none bind 0 0
/data/local-path /opt/local-path-provisioner  none bind 0 0
```

The bind **source** lives under `/data`. `scripts/uninstall.sh` deletes `/data`.
Delete a live bind's source and the mount survives in a zombie state —
`findmnt` shows it as:

```
/var/lib/k0s   /dev/vdb[/k0s//deleted]
```

Nothing looks wrong. The cluster is already gone, the teardown reports success,
and the script recommends a reboot. On that reboot `mount -a` fails,
`local-fs.target` fails, and a headless VM drops to an emergency shell **with no
SSH** — recoverable only through the cloud provider's console.

This was caught on `ais-edge-dev` in August 2026 with the reboot already queued.
The recovery was to recreate the deleted source directories and gate the reboot
on `findmnt --verify --fstab`.

The native settings above have no fstab entries and no mounts, so the failure
mode does not exist rather than being defended against. `docs/cai-lfs3-deployment-plan.md`
§3 called this correctly at the time — *"all supported config, not bind-mount
hacks"* — and the bind mounts went in anyway.

## If you inherit a node that already has the bind mounts

They conflict with `--data-dir`: k0s would write to `/data/k0s` through a bind
that also presents as `/var/lib/k0s`. Remove them before installing.

```bash
# 1. Release the mounts BEFORE deleting anything under /data.
sudo umount /var/lib/k0s /opt/local-path-provisioner

# 2. Drop the fstab lines.
sudo sed -i '\|^/data/k0s |d;\|^/data/local-path |d' /etc/fstab

# 3. Prove the node will still boot. Expect "Success, no errors or warnings"
#    and no output at all from the second command.
sudo findmnt --verify --fstab
findmnt -o TARGET,SOURCE | grep -- '//deleted' || echo "no dangling mounts"
```

Run step 3 before **any** reboot of a node whose fstab you have touched. It is
the only check that answers "will this machine come back".

## Known gap: edge workers

`scripts/files/edge-join.sh` runs `k0s install worker` without `--data-dir`, so
an edge node always uses `/var/lib/k0s` on its root disk. Edges with a small
root and a separate data volume need the same treatment; the site value is read
by the management install only. Track this before deploying an edge whose root
disk cannot hold the image store.
