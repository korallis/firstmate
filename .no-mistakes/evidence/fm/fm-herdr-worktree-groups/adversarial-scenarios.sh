#!/usr/bin/env bash
# Adversarial live scenarios for native Herdr worktree groups (test-phase scratch).
set -u
ROOT=$1
H=$ROOT/bin/fm-herdr-lab.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
unset FM_TEST_HERDR_WORKTREE_GROUPS FM_TEST_SEAM FM_BACKEND_HERDR_WORKTREE_GROUPS
TMP=$(mktemp -d "$(cd /tmp && pwd -P)/fm-nm-wtg.XXXXXX")
export TREEHOUSE_ROOT=$TMP/th
mkdir -p "$TREEHOUSE_ROOT"
SES=$("$H" name nm-wtg-adv); export HERDR_SESSION=$SES
RC=0
ok(){ echo "PASS - $1"; }
bad(){ echo "FAIL - $1"; RC=1; }
ev(){ echo "# evidence: $1"; }
cleanup(){
  for m in "$TMP"/home*/state/*.meta; do [ -f "$m" ] || continue; local h; h=$(dirname "$(dirname "$m")")
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/fm-teardown.sh" "$(basename "$m" .meta)" --force >/dev/null 2>&1 || true
  done
  "$H" teardown "$SES" >/dev/null 2>&1 || true
  find "$TMP" -type d -exec chmod u+rwx {} + 2>/dev/null; rm -rf "$TMP"
}
trap cleanup EXIT
"$H" provision "$SES" || { echo "provision failed"; exit 1; }
lab(){ "$H" run "$SES" "$@"; }
wss(){ lab workspace list | jq -c '.result.workspaces'; }
went(){ wss | jq -c --arg ws "$1" '.[]|select(.workspace_id==$ws)'; }
real(){ (cd "$1" && pwd -P); }
parent_ids(){ wss | jq -r --arg r "$(real "$1")" '[.[]|select((.worktree|type)=="object" and .worktree.is_linked_worktree==false and .worktree.checkout_path==$r)|.workspace_id]|join(",")'; }
mf(){ sed -n "s/^$2=//p" "$1" | tail -1; }
is_child(){ # ws parent
  local e p; e=$(went "$1"); p=$(went "$2")
  [ -n "$e" ] && [ -n "$p" ] && printf '%s' "$e" | jq -e --argjson p "$p" '.worktree.is_linked_worktree==true and .worktree.repo_key==$p.worktree.repo_key' >/dev/null
}
mkproj(){ mkdir -p "$1"; git -C "$1" init -q; echo x > "$1/README.md"; git -C "$1" add README.md; git -C "$1" -c user.name=t -c user.email=t@e.invalid commit -qm i; git clone -q --bare "$1" "$1.origin.git"; git -C "$1" remote add origin "file://$1.origin.git"; }
brief(){ mkdir -p "$TMP/home/data/$1"; printf '# Task\n## Captain'"'"'s intent\nfixture %s\n\n## Firstmate spec\nfixture.\n' "$1" > "$TMP/home/data/$1/brief.md"; }
spawn(){ local id=$1 p=$2; shift 2; local hm=${HM:-$TMP/home}; mkdir -p "$hm/state" "$hm/config" "$hm/data/$id"; touch "$hm/state/.last-watcher-beat"; cp "$TMP/home/data/$id/brief.md" "$hm/data/$id/brief.md" 2>/dev/null; env ${EV:-} FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$hm" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" "$id" "$p" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr "$@" > "$TMP/$id.out" 2> "$TMP/$id.err"; }
mkdir -p "$TMP/home/state" "$TMP/home/config"; touch "$TMP/home/state/.last-watcher-beat"
for id in o1 o2 c1 c2 d1 e1 f1 g3; do brief $id; done
for p in omega gamma delta eps phi; do mkproj "$TMP/$p"; done
echo "# herdr: $(lab status --json | jq -c '{server:.server.version}')"

# S1 removed user-facing env override
if EV=FM_BACKEND_HERDR_WORKTREE_GROUPS=off spawn o1 "$TMP/omega"; then
  W=$(mf "$TMP/home/state/o1.meta" herdr_workspace_id); P=$(parent_ids "$TMP/omega")
  if is_child "$W" "$P"; then ok "FM_BACKEND_HERDR_WORKTREE_GROUPS=off no longer opts out: o1=$W grouped under omega parent $P"; ev "$(went "$W" | jq -c '{workspace_id,label,linked:.worktree.is_linked_worktree}')"; else bad "o1 not grouped with removed override: $(wss)"; fi
else bad "o1 spawn failed: $(cat "$TMP/o1.err")"; fi

# S2 test seam variable without FM_TEST_SEAM is inert
if EV=FM_TEST_HERDR_WORKTREE_GROUPS=off spawn o2 "$TMP/omega"; then
  W=$(mf "$TMP/home/state/o2.meta" herdr_workspace_id); P=$(parent_ids "$TMP/omega")
  if is_child "$W" "$P"; then ok "FM_TEST_HERDR_WORKTREE_GROUPS=off without FM_TEST_SEAM=1 is ignored: o2=$W grouped under $P"; else bad "o2 not grouped: $(wss)"; fi
else bad "o2 spawn failed: $(cat "$TMP/o2.err")"; fi

# S3 concurrent fresh spawns from two homes into one Herdr session
HM=$TMP/home1 spawn c1 "$TMP/gamma" & p1=$!; HM=$TMP/home2 spawn d1 "$TMP/delta" & p3=$!
s1=0; s3=0; wait $p1 || s1=$?; wait $p3 || s3=$?
HM=$TMP/home1 spawn c2 "$TMP/gamma" || s2=$?; s2=${s2:-0}
PG=$(parent_ids "$TMP/gamma"); PD=$(parent_ids "$TMP/delta")
C1W=$(mf "$TMP/home1/state/c1.meta" herdr_workspace_id); C2W=$(mf "$TMP/home1/state/c2.meta" herdr_workspace_id)
if [ "$s1$s2$s3" = 000 ] && [ -n "$PG" ] && [ "${PG#*,}" = "$PG" ] && [ -n "$PD" ] && [ "${PD#*,}" = "$PD" ] \
  && is_child "$C1W" "$PG" && is_child "$C2W" "$PG" && is_child "$(mf "$TMP/home2/state/d1.meta" herdr_workspace_id)" "$PD"; then
  ok "concurrent spawns from two homes (gamma, delta) in one session both grouped under one parent per project (gamma=$PG delta=$PD); c2 joined gamma's group"
  ev "$(wss | jq -c '[.[]|{workspace_id,label,linked:.worktree.is_linked_worktree}]')"
else bad "concurrent spawns: status $s1$s2$s3 gamma=[$PG] delta=[$PD] errs: $(cat "$TMP/c1.err" "$TMP/c2.err" "$TMP/d1.err" | grep -i error | head -5)"; fi

# S4 abort after placement in a fresh project, concurrent with good spawns from other homes (x3 rounds)
bbrief(){ brief $1; printf '\nYou are in a disposable git worktree of fixture, at a detached HEAD on a clean copy of its base branch.\nBase branch: no-such-base\n' >> "$TMP/home/data/$1/brief.md"; }
for r in 1 2 3; do
  bbrief e$r; brief f$r
  HM=$TMP/home4 spawn e$r "$TMP/eps" --base-branch no-such-base & pe=$!; HM=$TMP/home5 spawn f$r "$TMP/phi" & pf=$!
  se=0; sf=0; wait $pe || se=$?; wait $pf || sf=$?
  PE=$(parent_ids "$TMP/eps"); PF=$(parent_ids "$TMP/phi")
  ELAB=$(wss | jq -r --arg l "e$r" '[.[]|select(.label==$l)]|length')
  if [ "$se" != 0 ] && [ ! -e "$TMP/home4/state/e$r.meta" ] && [ -z "$PE" ] && [ "$ELAB" = 0 ] && grep -q "could not fetch 'origin/no-such-base'" "$TMP/e$r.err"; then
    ok "round $r: e$r failed after group placement (origin fetch) - no meta, no e$r child, and the empty eps parent it created was closed"
  else bad "round $r e$r abort: status=$se epsParent=[$PE] ews=$ELAB err=$(grep -i error "$TMP/e$r.err" | head -3)"; fi
  if [ "$sf" = 0 ] && [ -n "$PF" ] && [ "${PF#*,}" = "$PF" ] && is_child "$(mf "$TMP/home5/state/f$r.meta" herdr_workspace_id)" "$PF"; then
    ok "round $r: f$r spawned concurrently with e$r's abort cleanup and was grouped under phi parent $PF"
  else bad "round $r f$r concurrent with abort: status=$sf err=$(grep -i error "$TMP/f$r.err" | head -3)"; fi
done
ev "e1 stderr: $(grep -v '^warning: .*launch-brief' "$TMP/e1.err" | tr '\n' ' ' | cut -c1-500)"
ev "treehouse status for eps after aborts (lease returned): $(cd "$TMP/eps" && treehouse status 2>&1 | tr '\n' ' ')"

# S5 abort into a project whose parent already exists with children: parent and siblings survive
bbrief g3; sg=0; HM=$TMP/home1 spawn g3 "$TMP/gamma" --base-branch no-such-base || sg=$?
ev "g3 stderr: $(grep -v 'launch-brief' "$TMP/g3.err" | tr '\n' ' ' | cut -c1-500)"
if [ "$sg" != 0 ] && [ "$(parent_ids "$TMP/gamma")" = "$PG" ] && is_child "$C1W" "$PG" && is_child "$C2W" "$PG" \
   && [ "$(wss | jq -r '[.[]|select(.label=="g3")]|length')" = 0 ] && [ ! -e "$TMP/home1/state/g3.meta" ]; then
  ok "g3 aborted after placement under the existing gamma parent: its child closed, parent $PG and siblings $C1W,$C2W kept"
else bad "g3 abort: status=$sg gamma=[$(parent_ids "$TMP/gamma")] $(wss)"; fi
ev "treehouse status for gamma after g3 abort: $(cd "$TMP/gamma" && treehouse status 2>&1 | tr '\n' ' ')"
ev "final workspace list: $(wss | jq -c '[.[]|{workspace_id,label,tab_count,linked:.worktree.is_linked_worktree}]')"
ev "gamma worktree list: $(lab worktree list --workspace "$PG" | jq -c '[.result.worktrees[]|{path,open_workspace_id}]')"
exit $RC
