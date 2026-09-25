# Rollback branch recipe (prepare at T-1, LOCAL ONLY, not pushed unless needed)

A `git revert` is **not** a rollback (runbook §5, trap R-6): it restores a stock claim with no `volumeName`, so the old namespace re-provisions and restores an older snapshot into a NEW volume while the retained PV (holding the newer data) is orphaned. The way back is a **forward commit** that puts the app back in `<OLD>` *with* the kind-targeted `volumeName` patch.
**Status: UNTESTED at real size** (the equivalent forward rollback was TESTED on the 1 MiB fixture [Rh-4]).

## Build (mirror image of commit 1), on top of commit 2
```bash
cd <WORKTREE> && git checkout -q -b <APP>-move-rollback <APP>-move        # commit 2 is the tip of <APP>-move
git mv kubernetes/apps/<NEW>/<APP> kubernetes/apps/<OLD>/<APP>
# ks.yaml: path -> ./kubernetes/apps/<OLD>/<APP>/app, targetNamespace: <OLD>, NS: <OLD>; restore its ORIGINAL shape (interval/retryInterval/timeout) from <BASE_SHA>:kubernetes/apps/<OLD>/<APP>/ks.yaml
# app/kustomization.yaml: KEEP the PersistentVolumeClaim volumeName patch; REMOVE the ReplicationDestination sourceNamespace patch
#   (the RD is in the series' own namespace again, so it must NOT carry sourceNamespace)
# app/helmrelease.yaml: controllers.<CONTROLLER>.replicas: 0 ; drop the temporary spec.timeout if the original had none
# httproute.yaml gatus group / homepage group and README -n <OLD>: back to the originals
# apps/<OLD>/kustomization.yaml: re-add ./<APP>/ks.yaml (alphabetical) ; apps/<NEW>/kustomization.yaml: remove it
MOVE_COAUTHOR='<Co-Authored-By value>' CLAUDE_SESSION_URL=<url> MOVE_CONF=<conf> hm 'COMMIT "<scope>: move <APP> back to <OLD> (rollback)"'
MOVE_CONF=<conf> hm 'move_gate <OLD> 1 zero'                                # want GATE PASS: exactly 1 line (volumeName), ns <OLD>, parent child "<OLD> <APP> ./kubernetes/apps/<OLD>/<APP>/app <OLD>"
git checkout -q <APP>-move
```
Not reverted on purpose: comment-only edits elsewhere (harmless prose).

## Use (only if the human says roll back)
1. Pod running in `<NEW>`: suspend HR, scale 0, no pod references the PVC, resume ks (`workflow.md` W-13 rollback row).
2. Push the branch, open a PR (new PR under time pressure), CI, merge (`MERGE` checkpoint), then wait for the PV `Released`.
3. `hm 'pv_repoint $PV <OLD>'`; wait `Bound`; **content check against the baseline** (`data_check` + `data_compare`); then a second commit dropping `replicas: 0`.
4. Data written since the start lives **on the PV**; the newest snapshot is `<APP>@<NEW>`, which the forward path never reads — take a fresh backup in `<NEW>` first if that work matters.
5. Clean the trap-7 orphans left in `<NEW>` (suspended HR) **before** any later move.
