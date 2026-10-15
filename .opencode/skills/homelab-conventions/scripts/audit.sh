#!/usr/bin/env bash
# Mechanical checks for the home-k8s house rules. Report-only: never edits, never
# touches the cluster. Uses git/grep/sed/awk only, because the working agreement
# says the agent runs no cluster commands.
#
# Design note: a noisy audit gets ignored, so each check is scoped to what the rule
# actually means. The reloader rule is about user-facing apps (routes), not cluster
# infrastructure; the Authelia rule only binds routes that are actually behind
# forward-auth (envoy-internal).
#
# Usage: bash .opencode/skills/homelab-conventions/scripts/audit.sh
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1
APPS="kubernetes/apps"
AUTHELIA="$APPS/auth/authelia/app/configmap.yaml"
findings=0

head_() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
find_() { findings=$((findings + 1)); printf '  FINDING  %s\n' "$*"; }
ok_()   { printf '  ok       %s\n' "$*"; }
note_() { printf '  note     %s\n' "$*"; }
lines() { printf '%s\n' "$1" | sed '/^$/d'; }

# --- exception lists (keep in sync with SKILL.md "known deliberate exceptions") ---
VOLSYNC_EXEMPT="couchdb immich"
DISABLED_APPS="jellyseerr tautulli"
BACKUP_NOT_NEEDED="postgres postgres-secrets gitea-mirror"
# Routed, but not application-like: they consume none of our config, and restarting
# them on a config change is actively unhelpful (longhorn-manager, flux's webhook
# receiver). Infrastructure that happens to publish a route.
RELOADER_EXEMPT="longhorn flux-instance"

app_dirs() {
  for d in "$APPS"/*/*/; do
    [ -d "$d" ] || continue
    case "$d" in */components/*|*/namespace*) continue;; esac
    [ -f "$d/ks.yaml" ] && printf '%s\n' "${d%/}"
  done
}
app_name() { basename "$1"; }
ns_of()    { basename "$(dirname "$1")"; }
is_exempt() { for e in $2; do [ "$1" = "$e" ] && return 0; done; return 1; }
rel() { printf '%s' "${1#kubernetes/apps/}"; }

# A "user-facing app" = a HelmRelease that publishes a route. That is the scope of
# the reloader rule; operators and infrastructure (cilium, coredns, cert-manager,
# flux, external-secrets...) do not consume our config and are deliberately out.
routed_apps() {
  for d in $(app_dirs); do
    hr="$d/app/helmrelease.yaml"
    if [ -f "$hr" ] && grep -q '^\s*route:' "$hr"; then printf '%s\n' "$d"; continue; fi
    if ls "$d"/app/*httproute*.yaml >/dev/null 2>&1; then printf '%s\n' "$d"; fi
  done
}

head_ "1. reloader annotation on every user-facing app (apps with a route)"
for d in $(routed_apps); do
  hr="$d/app/helmrelease.yaml"
  [ -f "$hr" ] || continue
  is_exempt "$(app_name "$d")" "$RELOADER_EXEMPT" && continue
  grep -q 'reloader.stakater.com/auto' "$hr" || \
    find_ "$(rel "$d")/app/helmrelease.yaml: no reloader.stakater.com/auto"
done
note_ "checked $(routed_apps | wc -l | tr -d ' ') routed apps (infrastructure is out of scope by design)"

head_ "2. images pinned with a version AND a manifest-list digest"
unpinned=""
for hr in $(find "$APPS" -name helmrelease.yaml -path '*/app/*' 2>/dev/null | sort); do
  # A chart may take the digest in its own `digest:` field rather than appended to
  # the tag (forgejo's does). Either counts as pinned.
  if grep -qE '^\s+digest: sha256:' "$hr"; then
    continue
  fi
  # Only consider `tag:` lines that belong to an image block. A `tag:` under
  # `ref:` is an OCIRepository chart reference, not a container image -- e.g.
  # storage/volsync, whose helmrelease.yaml also carries its OCIRepository.
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    case "$tag" in
      *@sha256:*) : ;;
      *) unpinned="$unpinned$(rel "$hr")  $tag"$'\n' ;;
    esac
  done < <(awk '
      /^[[:space:]]*(repository|image):/ { prev="image"; next }
      /^[[:space:]]*ref:/                { prev="ref";   next }
      /^[[:space:]]*tag:/ {
        if (prev == "image") { sub(/^[[:space:]]*tag:[[:space:]]*/, ""); print }
        next
      }
      /^[[:space:]]*$/ { next }
      { prev="other" }
    ' "$hr")
done
if [ -n "$unpinned" ]; then
  n=$(lines "$unpinned" | wc -l | tr -d ' ')
  find_ "$n image(s) pin a version but not a digest (the repo's stated convention is version@sha256:...)"
  lines "$unpinned" | sed 's/^/             /'
else
  ok_ "all app images carry a digest"
fi

head_ "3. namespace kustomizations: every app listed, and components/sops present"
for d in $(app_dirs); do
  n="$(app_name "$d")"; ns="$(ns_of "$d")"
  is_exempt "$n" "$DISABLED_APPS" && continue
  grep -q "\./$n/ks.yaml" "$APPS/$ns/kustomization.yaml" 2>/dev/null || \
    find_ "$ns/$n: ks.yaml exists but is not listed in $APPS/$ns/kustomization.yaml"
  if [ -d "$d/app" ] && [ ! -f "$d/app/kustomization.yaml" ]; then
    note_ "$ns/$n: app/ has no kustomization.yaml (kustomize builds it implicitly; every other app has one)"
  fi
done
# Missing components/sops is a BUILD FAILURE, not a style issue, which is why it lives
# here rather than in the cleanup sweep. kubernetes/flux/cluster/ks.yaml patches a
# NON-optional substituteFrom: cluster-secrets onto every child Kustomization, and
# substituteFrom resolves that Secret in the Kustomization's OWN namespace. Without
# the component the namespace's apps fail post-build with
# 'secrets "cluster-secrets" not found', and every Kustomization depending on them
# cascades off it. This is exactly how virtualization/kubevirt, cdi and
# kubevirt-manager all failed at once.
for k in "$APPS"/*/kustomization.yaml; do
  ns="$(basename "$(dirname "$k")")"
  # a namespace with no child Kustomizations has no substituteFrom to satisfy
  grep -q '/ks.yaml' "$k" 2>/dev/null || continue
  grep -q 'components/sops' "$k" || \
    find_ "$APPS/$ns/kustomization.yaml: no components/sops -> cluster-secrets is never rendered into $ns, so every app there fails at post-build"
done

head_ "4. every manifest in app/ is listed in its kustomization.yaml"
for d in $(app_dirs); do
  k="$d/app/kustomization.yaml"; [ -f "$k" ] || continue
  for f in "$d"/app/*.yaml; do
    b="$(basename "$f")"
    [ "$b" = "kustomization.yaml" ] && continue
    grep -q "\./$b" "$k" || find_ "$(rel "$d")/app/$b not listed in app/kustomization.yaml"
  done
done

head_ "5. every OCIRepository/HelmRepository is referenced"
for src in $(grep -rl 'kind: OCIRepository\|kind: HelmRepository' "$APPS" 2>/dev/null); do
  name="$(grep -m1 '^  name:' "$src" | awk '{print $2}')"
  ns="$(printf '%s' "$src" | sed -E "s|$APPS/([^/]+)/.*|\1|")"
  grep -rq "name: $name" --include=helmrelease.yaml "$APPS/$ns" 2>/dev/null || \
    find_ "$(rel "$src"): source '$name' referenced by no HelmRelease"
done

head_ "6. Authelia coverage (forward-auth binds only envoy-internal routes)"
if [ ! -f "$AUTHELIA" ]; then
  find_ "cannot find $AUTHELIA"
else
  # hostname -> gateway, per manifest. Each app has one route in practice.
  gw_map=""
  for f in $(grep -rl 'hostnames:' "$APPS" --include=helmrelease.yaml --include='*httproute*.yaml' 2>/dev/null); do
    gw="external"; grep -q 'name: envoy-internal' "$f" && gw="internal"
    for h in $(grep -oE '"[a-z0-9-]+\.\$\{SECRET_DOMAIN\}"' "$f" | tr -d '"' | sed 's/\.\${SECRET_DOMAIN}//'); do
      gw_map="$gw_map$h $gw"$'\n'
    done
  done
  gw_map="$(printf '%s' "$gw_map" | sort -u)"
  for h in $(lines "$gw_map" | awk '$2=="internal"{print $1}'); do
    grep -qE "domain: $h\.\\\$\{SECRET_DOMAIN\}|- $h\.\\\$\{SECRET_DOMAIN\}" "$AUTHELIA" || \
      find_ "internal route '$h' has no access_control rule (default deny -> 403)"
  done
  note_ "$(lines "$gw_map" | wc -l | tr -d ' ') hostnames, $(lines "$gw_map" | awk '$2=="internal"' | wc -l | tr -d ' ') internal (forward-auth enforced)"
  # reverse: rules for hostnames that no longer exist
  for h in $(grep -oE '[a-z0-9-]+\.\$\{SECRET_DOMAIN\}' "$AUTHELIA" | sed 's/\.\${SECRET_DOMAIN}//' | sort -u); do
    printf '%s\n' "$gw_map" | awk '{print $1}' | grep -qx "$h" || \
      note_ "access_control lists '$h' but no route declares it (stale rule?)"
  done
fi

head_ "7. stateful apps are backed up (volsync component)"
for d in $(app_dirs); do
  n="$(app_name "$d")"
  is_exempt "$n" "$VOLSYNC_EXEMPT" && continue
  is_exempt "$n" "$BACKUP_NOT_NEEDED" && continue
  hr="$d/app/helmrelease.yaml"
  stateful=0
  [ -f "$hr" ] && grep -qE 'existingClaim: ' "$hr" && stateful=1
  [ -f "$d/app/pvc.yaml" ] && stateful=1
  # A DataVolume creates its own PVC, so it is invisible to the two checks above.
  # No early `continue` for a missing helmrelease either: chart-less app dirs like
  # virtualization/vm are exactly where a DataVolume lives.
  [ -f "$d/app/datavolume.yaml" ] && stateful=1
  [ "$stateful" = 0 ] && continue
  # Two legitimate shapes: the shared component, or a bespoke ReplicationSource
  # where the component's hourly cadence does not suit the volume (a VM disk).
  if ! grep -q 'components/volsync' "$d/ks.yaml" 2>/dev/null \
     && [ ! -f "$d/app/replicationsource.yaml" ]; then
    find_ "$(rel "$d"): has a PVC but no backup (no components/volsync, no app/replicationsource.yaml)"
  fi
done

head_ "8. every CNPG Cluster has a backup configured"
for c in $(grep -rl '^kind: Cluster$' "$APPS" --include='*.yaml' 2>/dev/null); do
  ns="$(printf '%s' "$c" | sed -E "s|$APPS/([^/]+)/.*|\1|")"
  # three legitimate shapes: the deprecated in-tree barmanObjectStore, a
  # volumeSnapshot backup, or a CNPG-I plugin (spec.plugins) -- the last of which
  # puts the real config in an ObjectStore + ScheduledBackup in the same namespace
  if grep -qE 'barmanObjectStore|ObjectStore|^\s+backup:|^\s+plugins:' "$c" \
     || [ -n "$(find "$APPS/$ns" -name 'scheduledbackup*.yaml' 2>/dev/null)" ]; then
    ok_ "$(rel "$c"): backup configured"
  else
    find_ "$(rel "$c"): CNPG Cluster has NO backup -- data that git cannot rebuild"
  fi
done

head_ "9. mail senders follow no-reply@<subdomain>.<domain>"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  f="${line%%:*}"; s="${line#*sender:}"
  case "$s" in
    *'no-reply@'*'${SECRET_DOMAIN}'*) : ;;
    *) find_ "$(rel "$f"): sender '$s' does not follow no-reply@<subdomain>.<domain>" ;;
  esac
done < <(grep -rn 'sender:' "$APPS" --include='*.yaml' 2>/dev/null)

head_ "10. Homepage coverage (dashboard is hand-maintained, so it drifts)"
HP="$APPS/default/homepage/app/helmrelease.yaml"
if [ -f "$HP" ] && [ -n "${gw_map:-}" ]; then
  hp_hosts="$(grep -oE 'href: https://[a-z0-9-]+\.\$\{SECRET_DOMAIN\}' "$HP" \
              | sed -E 's|.*https://||;s|\.\$\{SECRET_DOMAIN\}||' | sort -u)"
  for h in $(lines "$gw_map" | awk '{print $1}'); do
    printf '%s\n' "$hp_hosts" | grep -qx "$h" || note_ "route '$h' has no Homepage card"
  done
  for h in $(lines "$hp_hosts"); do
    printf '%s\n' "$gw_map" | awk '{print $1}' | grep -qx "$h" || \
      note_ "Homepage lists '$h' but no route declares it (stale card?)"
  done
  # widgets: a card without one is often just a missing API key
  cards=$(grep -cE '^            - [A-Za-z].*:$' "$HP" 2>/dev/null || echo 0)
  widgets=$(grep -cE '^                  type: ' "$HP" 2>/dev/null || echo 0)
  note_ "$cards cards, $widgets widgets -- check for cards whose app supports a widget but has none"
else
  note_ "could not read $HP"
fi

head_ "11. cleanup sweep"
for f in $(grep -rl '^\s*#\s*- \./.*ks.yaml' "$APPS" --include=kustomization.yaml 2>/dev/null); do
  note_ "$(rel "$f") has commented-out ks entries:"
  grep -E '^\s*#\s*- \./' "$f" | sed 's/^/             /'
done
for d in $(app_dirs); do
  n="$(app_name "$d")"; ns="$(ns_of "$d")"
  is_exempt "$n" "$DISABLED_APPS" && continue
  grep -q "\./$n/ks.yaml" "$APPS/$ns/kustomization.yaml" 2>/dev/null || continue
  [ -d "$d/app" ] || find_ "$ns/$n: ks.yaml points at app/ which does not exist"
done
for d in "$APPS"/*/*/; do
  [ -d "$d" ] || continue
  case "$d" in */components/*|*/namespace*) continue;; esac
  [ -f "$d/ks.yaml" ] || { [ -d "$d/app" ] && note_ "$(rel "$d"): app/ but no ks.yaml (never deployed?)"; }
done

head_ "summary"
printf '  %s finding(s). Report-only -- propose fixes, do not apply them.\n' "$findings"
exit 0
