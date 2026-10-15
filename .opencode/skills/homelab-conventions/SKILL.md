---
name: homelab-conventions
description: Audit the home-k8s GitOps repo against the conventions and decisions we have agreed, and surface drift plus cleanup opportunities. Covers reloader annotations, digest-pinned images, app-template wiring, Authelia rule coverage, volsync and CNPG backup coverage, 1Password-only secrets, mail sender naming, per-namespace isolation, and dead or commented-out config. Use this whenever the user asks to verify, audit, review or sanity-check this repo, asks "is everything consistent", "anything we've missed", "what can we clean up", or has just added/changed an app and wants it checked against the house rules — even if they do not say the word "audit".
license: MIT
metadata:
  audience: homelab-maintainer
  opencode/slash: "true"
---

# Homelab conventions audit

This repo is a `onedr0p/cluster-template` derivative (Talos + Flux + SOPS + 1Password +
Envoy Gateway + Cloudflare Tunnel + Longhorn + Volsync). Over time we settled on a
set of house rules. The value of this skill is catching the moment where a new app
quietly skips one — because the failure mode is silent (no backups, no auth gate, a
stale image pin) rather than loud.

## Working agreement (read this first)

- The agent runs **only `git`** on this machine plus local file edits. Every cluster
  command (`kubectl`, `flux`, `talosctl`) is **handed to the user to run** and its
  output pasted back. Do not run them yourself.
- The agent **commits only**. The user always pushes.
- Never assert a value without checking it. Verify against the **committed** content
  (`git show HEAD:<path>`) and confirm `git status --short` is empty — an unstaged
  edit next to a passing `kubectl kustomize` check has produced a wrong commit here
  before.
- Ask before rework, and prefer a question over an assumption. This repo's history
  includes several confidently-wrong assertions that one check would have caught.

## How to run the audit

1. Run the bundled script — it does the mechanical checks and prints findings:
   ```sh
   bash .opencode/skills/homelab-conventions/scripts/audit.sh
   ```
2. Walk the judgement-based rules below that the script cannot decide.
3. Report findings grouped as **Broken** (a rule is violated), **Drift** (config and
   the decision log disagree), and **Cleanup** (safe to delete or tidy). For each,
   give the file, the rule, and the smallest fix.
4. Anything needing cluster state, list as commands for the user to run.

Do not fix things silently. Propose, then let the user choose — several "obvious"
fixes here have needed a decision first.

## House rules

### App structure

- `kubernetes/apps/<ns>/<app>/ks.yaml` exists and is listed in
  `kubernetes/apps/<ns>/kustomization.yaml`; its `path` is
  `./kubernetes/apps/<ns>/<app>/app`.
- `app/kustomization.yaml` lists every manifest in that directory. A manifest not
  listed is dead config that never deploys — easy to miss because the directory
  still looks populated.
- **Every `kubernetes/apps/<ns>/kustomization.yaml` includes
  `components: [../../components/sops]`.** Not optional, not stylistic: the
  cluster-wide patch in `kubernetes/flux/cluster/ks.yaml` adds a **non-optional**
  `substituteFrom: cluster-secrets` to every child Kustomization, and `substituteFrom`
  resolves that Secret in the Kustomization's **own** namespace. Omit it and the
  namespace's apps fail at post-build with `secrets "cluster-secrets" not found`,
  cascading into everything that `dependsOn` them — this is what took out `kubevirt`,
  `cdi` and `kubevirt-manager` in one go. The audit checks it.
- app-template comes from `OCIRepository` (`oci://ghcr.io/bjw-s-labs/helm/app-template`)
  referenced via `chartRef`, tag matching the version used elsewhere (currently `5.3.0`).
- **Images are pinned with a version *and* the manifest-list digest**
  (`tag: 1.6.2@sha256:…`). Check with
  `crane digest ghcr.io/<org>/<img>:<tag>` — the digest that matches is the
  manifest-list one, not the per-arch one. An unpinned image is drift.
- Use the **latest stable** version. A pin that is already superseded is a chore for
  Renovate, so flag it.

### Cross-cutting app hygiene

- **Every app carries `reloader.stakater.com/auto: "true"`** — proactively, not only
  once something breaks. This is a standing user requirement; a missing annotation is
  a finding even if the app works today.
- Both `liveness` and `readiness` probes, pointing at a real endpoint. Prefer the
  app's own health path over `/` (e.g. Bazarr `/api/system/ping`) — a probe that only
  proves the port is open will happily keep routing to a broken app.
- `resources.requests` set, and a memory `limit`. An app with no memory limit can take
  a node down.
- Container security context: `allowPrivilegeEscalation: false`,
  `readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]`. Pod security context:
  `runAsNonRoot: true` plus explicit `runAsUser`/`runAsGroup`/`fsGroup` and
  `fsGroupChangePolicy: OnRootMismatch`.
  - **Check the image's actual uid before forcing one.** `opencloud` runs as `1000`;
    the *arr images run as `568`. Forcing the wrong uid gives confusing permission
    failures. Read the image config rather than guessing.
  - `readOnlyRootFilesystem: true` means anything the app writes needs a mount. Mount
    `tmp` (emptyDir) by default, and expect to iterate — say so rather than claiming
    it works.

### Auth (Authelia)

- **Every routed hostname has an `access_control` entry.** A route with no rule falls
  through to `default_policy: deny` and silently 403s — which looks like a broken app,
  not a missing rule.
- Two shapes, and they must not be mixed up:
  - **forward-auth apps** → a rule with `subject: group:<tool>` and, for admin
    surfaces, `policy: two_factor`.
  - **OIDC apps** → `policy: bypass` (the app gates itself) **plus** the client in
    `identity_providers.oidc.clients` referencing a named `authorization_policy`.
- OIDC apps must **not** be left on bare `authorization_policy: one_factor`. That
  means "any authenticated user", which silently defeats the tool-scoped groups.
  Every OIDC client should reference a policy that is `default_policy: deny` with a
  group rule — and every one of those policies should also allow `group:admins` so an
  admin can never lock themselves out.
- Admin surfaces are `two_factor`. A passkey login is **one factor**; `two_factor`
  therefore means passkey **plus** password. Do not reach for
  `experimental_enable_passkey_uv_two_factors` — the user rejected experimental
  Authelia features.
- OIDC client secrets are currently **plaintext in the configmap** (known Phase 5
  debt). Note it, don't fix it unprompted.

### Secrets

- Secrets come from **1Password via ExternalSecrets only** (vault `k8s-cluster`).
  No plaintext, and never a new `.sops.*` file for an app — SOPS is for cluster
  bootstrap only.
- CNPG password secrets live in a separate `<name>-secrets` Kustomization that the
  datastore Kustomization `dependsOn`, so passwords exist before the cluster does.
- A shared, generically-named item is preferred over per-app duplication — e.g. one
  `smtp` item (`SMTP_HOST/PORT/USERNAME/PASSWORD`) that every mail-sending app
  references. Names are keyed to the public subdomain, never to the implementation,
  so an app can be swapped underneath a name.

### Storage and backup

- **Every stateful app is backed up by volsync.** The normal path is the
  `components/volsync` component, which requires the app to consume
  `existingClaim: <app>` so the component owns the PVC.
- **Regenerable caches must not be inside a backed-up volume.** MediaCover,
  Plex `Metadata/`/`Cache/`/`Media/`, thumbnails — put them on a separate unbacked
  PVC or emptyDir. Symptom of getting this wrong: one app's replication takes 10+
  minutes while its neighbours take 1–5.
- **Every CNPG `Cluster` needs a backup.** This is the highest-severity check in the
  repo: `auth/postgres` alone holds Authelia's storage *and lldap — every user and
  group*. A database with no `backup`/`ObjectStore`/`ScheduledBackup` is an
  un-rebuildable loss, because unlike everything else here it cannot be restored from
  git.
- Chart-owned PVCs (e.g. `apache/couchdb` creates its own) cannot use the volsync
  component without orphaning existing data. Prefer a bespoke `ReplicationSource`
  pointing at the existing PVC in place — no migration, no data risk.

### Network and DNS

- Per-namespace NetworkPolicy as apps are added; `database` operator namespaces are
  the documented exception.
- Internal apps route on `envoy-internal`, public on `envoy-external`, hostname
  `<subdomain>.${SECRET_DOMAIN}`.
- AdGuard is the source of truth for **internal** DNS; Cloudflare for public and it
  must **not** be changed. external-dns instances use `sources: ["gateway-httproute"]`
  only. Mail records (SPF/DKIM/DMARC/MX) are declarations about the domain, not
  derived from cluster state — they stay manual.

### Mail

- Senders are `no-reply@<subdomain>.<domain>` (e.g. `no-reply@auth.heems.dev`),
  built from `${SECRET_DOMAIN}` rather than stored per app. The domain is the stable
  identifier; the app behind it is swappable.
- Fastmail treats subdomains as separate domains for *receiving*, but sending from one
  works without registering it. A rejected sender shows as `551 5.7.1` and Authelia
  only logs it at send time — its startup check dials but never authenticates, so a
  bad sender cannot crash auth. Do not claim otherwise.

## Known, deliberate exceptions

Do not report these as findings — they are decisions, and re-reporting them each run
trains the user to ignore the audit.

| Thing | Why it is fine |
|---|---|
| `jellyseerr`, `tautulli` commented out | Deferred to Phase 6 on purpose |
| `couchdb` has no volsync component | Its chart owns the PVC; backed up in place instead |
| `immich`'s 1Ti PVC not backed up | It is the NFS library on the NAS — outside the cluster by design |
| MediaCover / Plex cache PVCs unbacked | Regenerable by design |
| `opencloud` is a public OIDC client without PKCE | Accepted risk, see decisions §8.1 |
| Plaintext OIDC client secrets | Known Phase 5 debt |
| `readOnlyRootFilesystem` on an app not yet proven | Convention applied proactively; iterate if it crashloops |
| `obsidian-couchdb` has no `readOnlyRootFilesystem` | The official CouchDB image's entrypoint writes into `/opt/couchdb/etc` at startup |
| `obsidian-couchdb` is a statefulset with a hand-written HTTPRoute | LiveSync's `_changes` feed needs a 300s route timeout, which app-template's `route` block does not expose |
| `longhorn`, `flux-instance` have no reloader annotation | Routed, but infrastructure — nothing of ours to reload, and restarting them on a config change is harmful |
| `node-feature-discovery/app/` has no `kustomization.yaml` | kustomize builds a directory implicitly; the file is optional |

## Cleanup sweep

Beyond rule violations, look for:

- Manifests present but not listed in a `kustomization.yaml`, and `ks.yaml` not listed
  in its namespace kustomization.
- `OCIRepository`/`HelmRepository` referenced by no HelmRelease.
- App directories with no `ks.yaml`, or `ks.yaml` with no `app/` directory.
- PVCs and cache PVCs with no consumer.
- Stale or duplicated `.taskfiles/` targets, and `scripts/` entries nothing calls.
- Decision-log drift: `~/.opencode/plan/homelab-stack-decisions.md` and
  `homelab-implementation-plan.md` still marked open for things now built (or
  claiming something verified that the evidence no longer supports).

## Debugging traps in this repo

Learned the hard way; check these before assuming a fix "didn't work".

- **A crashlooping app rejects its own fix.** Flux's HelmRelease waits for
  resources to become Ready, and `upgrade.remediation.retries` + `cleanupOnFail`
  means a failed upgrade gets **rolled back** to the previous revision. So a fix
  for a broken app never lands: the app stays broken, so the upgrade keeps
  failing, so the fix keeps getting reverted. Escape by forcing an *install*
  (`kubectl delete hr <name> -n <ns>` — the install path has `retries: -1` and no
  rollback, and any PVC owned by the volsync component survives), or by setting
  `disableWait: true` on that release. If a change appears not to apply, check
  `flux get hr` for a failed/stalled state *before* debugging the manifest.
- **`Completed` / exit code 0 with a suspiciously exact restart interval is a
  failing liveness probe**, not a crash. Kubelet sends SIGTERM, a well-behaved
  app exits 0, and the interval equals `initialDelaySeconds + failureThreshold ×
  periodSeconds`. Confirm with `kubectl describe pod` → `Last State`, then check
  whether the probe path is reachable without credentials.
- **Never put an HTTP probe on an endpoint that requires auth.** CouchDB's
  `/_up` answers `401` under `require_valid_user` (the auth check runs before the
  path-based bypass in `chttpd_auth_request`), and returns `404` while
  `mem3_seeds` is seeding on a fresh volume. Use `tcpSocket` for a liveness check
  — it asserts what you actually mean ("the process is listening").
- **Check the image's uid and what its entrypoint writes before forcing
  securityContext values.** `opencloud` runs as `1000`; the *arr images as `568`;
  CouchDB's entrypoint writes `local.d/docker.ini` under `set -e`, so that
  directory must stay writable — mount config as a `subPath` *file*, not over the
  directory.
- **Reconcile every affected Kustomization.** Each app has its own, so
  `flux reconcile ks <one>` does not cover another namespace.
- **`postBuild.substituteFrom` resolves the Secret in the Kustomization's OWN
  namespace.** A Secret that exists only in `flux-system` is invisible to a
  Kustomization elsewhere — which is why `cluster-secrets` is injected into every
  namespace by the `components/sops` component rather than living in one place.
  Any shared substitution source must be a component added per namespace. And be
  careful with `optional: true`: it turns "the Secret is missing" into a silent
  no-op, so the manifest is applied with a literal `${VAR}` in it. That is exactly
  how a CNPG `ObjectStore` was once rejected by CRD validation with no error
  anywhere except the object simply not existing.
  - **The failure mode to recognise:**
    `post build failed for '<Kind>/<name>': substitute from 'Secret/cluster-secrets'
    error: secrets "cluster-secrets" not found`. That is a missing `components/sops`
    in *that namespace's* kustomization, never a problem with the app itself. Because
    `dependsOn` chains, several Kustomizations report `dependency ... is not ready` at
    the same time and only the first one is the real failure — read past the cascade.
- **The Homepage dashboard is hand-maintained**, so it drifts as apps are added —
  a new app is invisible on the dashboard until someone adds a card. Check it
  after every new app.
- **A `tag` digest is only correct for charts that put it there.** app-template
  does (`repository` + `tag: 1.2.3@sha256:…`), and most of the *arr apps are pinned
  that way. But a chart that composes the image from `registry` + `repository` +
  `tag` — forgejo's does — needs the digest in its own `image.digest` field;
  appending `@sha256:` to the tag produces a reference kubelet rejects with
  `Init:InvalidImageName`, and the app simply won't start. Check the chart's
  values before pinning, and never call a digest change "zero-risk" without
  confirming which shape the chart expects.
- **Restoring a CNPG cluster with the barman plugin needs the SOURCE server name
  in the plugin parameters, not the ObjectStore.** The plugin resolves it as
  `externalClusters[].plugin.parameters.serverName`, falling back to the *target*
  cluster's name (`internal/cnpgi/restore/restore.go`). The ObjectStore's
  `configuration.serverName` is not consulted on this path. Get it wrong and the
  plugin lists the bucket successfully, reports `backupCatalog:[]` and fails with
  `no target backup found` — which reads exactly like the backups don't exist,
  when really it looked in a folder named after the cluster being created.
  Since barman folders are named after the source cluster, a restore into a
  differently-named cluster always needs this.

## Reporting

Lead with the highest-severity finding, not the first one you found. Severity order:
un-backed-up data > missing auth rule > missing reloader/backup component >
pin/version drift > hygiene > cosmetic cleanup.

For each finding give: what, where, why it matters, the smallest fix, and whether it
needs a decision from the user. Then list anything you need the user to run. Finish
with what you checked and found clean — silence on a rule is ambiguous otherwise.
