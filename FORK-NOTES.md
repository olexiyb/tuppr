# Fork notes: olexiyb/tuppr `integration`

Fork-only. This file, `hack/rebuild-integration.sh`, and every commit marked
`(fork only)` live on the `integration` branch and are never proposed
upstream. Upstream PR branches are always based on `origin/main`.

## Branch layout

| Branch        | What it is                                                               |
| ------------- | ------------------------------------------------------------------------ |
| `main` (fork) | Mirror of `home-operations/tuppr` `main`. Never commit to it.            |
| PR branches   | One per upstream PR, based on `origin/main` (see the table below).       |
| `integration` | `origin/main` + every open PR branch merged + the `(fork only)` commits. |

`integration` is rebuilt, not merged forward: upstream squash-merges PRs, so
merging `main` back would conflict on identical code. Rebuild after upstream
moves or a PR branch changes:

```bash
mise exec -- hack/rebuild-integration.sh   # builds integration.new, pushes nothing
mise run test && mise run test-integration && mise run lint && mise run vulncheck
git branch -f integration integration.new && git branch -D integration.new
git push --force-with-lease fork integration
```

The script skips PRs that are merged or closed upstream, merges the rest in
order, and re-applies the `(fork only)` commits (dropping any that became
empty because upstream now has the change). `rerere` is enabled, so a conflict
resolved once is replayed on every rebuild; a new conflict stops the script
for a manual resolution.

After upstream merges one of these PRs (especially with maintainer changes on
top), the recorded resolutions are against the old branch, not the merged
code. Rebuild once with rerere off and check each resolution by hand:

```bash
sed -e '/git config rerere/d' hack/rebuild-integration.sh > /tmp/rebuild.sh
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=rerere.enabled GIT_CONFIG_VALUE_0=false \
  mise exec -- bash /tmp/rebuild.sh
```

A `(fork only)` fix that upstream made obsolete may still apply cleanly but
break the build; drop it with `git rebase --onto <commit>^ <commit>`.

## Image

Every push to `integration` builds and signs
`ghcr.io/olexiyb/tuppr:integration` (linux/amd64 and arm64) through the
upstream `release.yaml`, which a `(fork only)` commit extends to this branch.
CI (`ci.yaml`) does not run on this branch; run the mise tasks above locally
before pushing. A new GHCR package is private: make it public, or give the
cluster a pull secret.

## Open upstream PRs

| PR   | Branch                              | Change                                                                                                                                                                                                               |
| ---- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| #671 | `fix/rebooting-node-verify-errors`  | A rebooting node whose Job is gone keeps waiting on verify errors (e.g. Talos 1.14 `PermissionDenied` window) until the reboot deadline, like the Job path.                                                          |
| #681 | `feat/pre-batch-hooks`              | `spec.hooks.preBatch` (#630): hook Jobs before every batch with `TUPPR_NODES`, retried until `preBatchRetry.timeout` (the deadline holds while other gates hold the run); state in `status.preBatchHooks`. Approved. |
| #682 | `fix/post-hooks-after-failed-batch` | A failed batch runs the post-hooks before `Failed`; reset or spec change deletes the run's hook Jobs; "Upgrade stopped after failures" message.                                                                      |

Merged upstream (2026-11-03/04, with maintainer fixes on top; see each PR's
comments): #668 cluster health gate, #669 control-plane serialization, #672
upgrade-path validation, #683 non-blocking health checks.

### How they interact

- **#681 on `main`:** rebased onto the merged #668, #669 and #683. In
  `processNextBatch`: choose the batch, resume a started one, wait for the
  control-plane slot (#669), check images, the cluster health gate (#668),
  then the pre-batch stage decides whether `spec.healthChecks` run (#683),
  then pre-hooks, pre-batch hooks, drain.
- **#681 and #682** both edit `hooks.go` and `hooks_test.go` (#681 adds
  pre-batch helpers, #682 adds `deleteHookJobs` and the `DeletionTimestamp`
  skip). They merge cleanly; #682's reset cleanup also covers pre-batch Jobs.

## Fork-only commits

- `ci: build the integration branch image`.
- This file and the rebuild script.

## Testing on the cluster

- [ ] Control-plane nodes upgrade one at a time; workers batch up to
      `parallelism`; a mixed batch never forms.
- [ ] Between batches the run waits in `HealthChecking` ("Waiting for cluster
      health: …") until the rebooted node is `Ready` and etcd is healthy.
- [ ] Pre-batch hook (DRBD `UpToDate` check) runs before each batch with the
      right `TUPPR_NODES`; a failing hook retries every `interval`, the health
      checks run before every retry, and the batch is never cordoned while it
      fails.
- [ ] Suspend while a pre-batch hook runs, then resume: the same Job is picked
      up.
- [ ] A failed node runs the post-hooks (e.g. `ceph osd unset noout`) before
      the run turns `Failed`.
- [ ] The webhook rejects an unsupported target (e.g. two minors ahead of the
      oldest node) and warns on a downgrade.
- [ ] A node rebooting through Talos 1.14's `PermissionDenied` window after its
      Job was garbage collected keeps waiting instead of failing.

## Still open (not in any PR)

Ranked by how much damage each can do.

1. **Pre-pull blocks the reconcile worker.** #683 fixed the health checks;
   `prePullInstallerImages` still pulls one node after another, up to 10m
   per node, inside a reconcile. The drain loop and the 2m volume-detach
   wait block too, but for less time. The maintainer also noted that
   `processNextBatch` checks the maintenance window before this slow work.
2. **Upgrade-path check before cordon, in the controller.** #672 checks at
   admission only; a version annotation, a relabel into the selector, or a new
   node after admission aren't re-checked. Talos's installer still refuses a
   bad Talos path, but after tuppr drained the node; a Kubernetes mismatch
   only surfaces after the reboot. Fix: run #672's per-node check just before
   cordon.
3. **A lock between plans (coordination `Lease`).** Closes the race #669
   documents: two plans selecting different control-plane nodes passing the
   cross-plan check within milliseconds. Next to it: an `upgrading` label left
   by a deleted plan still holds other plans' control-plane batches; storing
   the plan name as the label value would let tuppr remove it safely.
4. **Rollback detection.** When a new image fails to boot and Talos rolls
   back, the run waits the full reboot deadline (30m) and reports "did not
   become ready" instead of "rolled back". Reporting only; the run still stops.
5. **Smaller:**
   - `KubernetesUpgrade` targets aren't checked against the nodes' Talos
     versions (`talosctl upgrade-k8s` has its own check);
   - control-plane nodes: compare the apiserver version, which can briefly be
     newer than the kubelet during a Kubernetes upgrade;
   - a built-in postCordon hook (run after cordon, before eviction, so workers
     finish on their own). For now a pre-batch hook can cordon the nodes in
     `TUPPR_NODES` and wait;
   - committed CRDs carry `controller-gen` v0.22.0 while mise pins v0.23.0, so
     `mise run test` rewrites the annotation.
