#!/usr/bin/env bash
set -u
ROOT=/home/lee/.no-mistakes/worktrees/78e11e7c1ced/01M4BXYVWA7XE9EXEJVSYMJFV2
EV=/home/lee/.no-mistakes/evidence/01M4BXYVWA7XE9EXEJVSYMJFV2
H="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"; herdr_forget_inherited_pane
T=$(mktemp -d /tmp/fm-manual-wtg/run.XXXXXX)
S=$("$H" name wtg-manual); export HERDR_SESSION=$S
echo "session=$S tmp=$T"
WTS=""
cleanup() {
  TMUX_TMPDIR="$T/tmux" tmux -L fm-lab-tui kill-server 2>/dev/null
  while IFS=$'\t' read -r wt p; do [ -n "$wt" ] && [ -d "$wt" ] && (cd "$p" && treehouse return --force "$wt") >/dev/null 2>&1; done <<<"$WTS"
  "$H" teardown "$S" >/dev/null 2>&1 && echo "lab torn down"
  find "$T" -type d -exec chmod u+rwx {} + 2>/dev/null; rm -rf "$T"
}
trap cleanup EXIT
"$H" provision "$S" || exit 1
lab() { "$H" run "$S" "$@"; }
mkproj() { mkdir -p "$1"; git -C "$1" init -q -b main; echo x >"$1/README.md"; git -C "$1" add .; git -C "$1" -c user.name=t -c user.email=t@e.invalid commit -qm init; git clone -q --bare "$1" "$1.origin.git"; git -C "$1" remote add origin "file://$1.origin.git"; }
brief() { mkdir -p "$HOME_DIR/data/$1"; printf '# Task\n## Captain'"'"'s intent\nfixture %s\n\n## Firstmate spec\nfixture\n' "$1" >"$HOME_DIR/data/$1/brief.md"; }
spawn() { local id=$1 p=$2; shift 2; FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" "$id" "$p" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr "$@"; }
mf() { sed -n "s/^$2=//p" "$1" | tail -1; }
wsl() { lab workspace list | jq -c '[.result.workspaces[] | {workspace_id,label,tab_count,checkout:.worktree.checkout_path,linked:.worktree.is_linked_worktree}]'; }
HOME_DIR="$T/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"; touch "$HOME_DIR/state/.last-watcher-beat"
mkproj "$T/webapp"; mkproj "$T/api"
for id in fix-login add-cache bump-deps bad-base; do brief $id; done

echo "== scenario: three spawns across two projects"
for x in "fix-login webapp" "add-cache webapp" "bump-deps api"; do set -- $x
  spawn "$1" "$T/$2" >"$T/$1.out" 2>"$T/$1.err" || { echo "SPAWN $1 FAILED"; cat "$T/$1.err"; exit 1; }
  WTS+="$(mf "$HOME_DIR/state/$1.meta" worktree)"$'\t'"$T/$2"$'\n'
  echo "$1 -> workspace $(mf "$HOME_DIR/state/$1.meta" herdr_workspace_id) worktree $(mf "$HOME_DIR/state/$1.meta" worktree)"
done
echo "workspace list:"; wsl | jq .
echo "herdr worktree list --cwd webapp:"; lab worktree list --cwd "$T/webapp" | jq -c '[.result.worktrees[] | {path,is_linked_worktree,open_workspace_id}]'

echo "== TUI sidebar capture (real herdr client, 120x40, private tmux socket)"
mkdir -p "$T/tmux"
TMUX_TMPDIR="$T/tmux" tmux -L fm-lab-tui new-session -d -x 120 -y 40 -s v \
  "env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_BIN_PATH -u HERDR_SESSION herdr --session $S"
sleep 4
TMUX_TMPDIR="$T/tmux" tmux -L fm-lab-tui capture-pane -p -t v > "$EV/herdr-tui-sidebar-grouped.txt"
TMUX_TMPDIR="$T/tmux" tmux -L fm-lab-tui capture-pane -p -e -t v > "$EV/herdr-tui-sidebar-grouped.ansi"
cat "$EV/herdr-tui-sidebar-grouped.txt"
TMUX_TMPDIR="$T/tmux" tmux -L fm-lab-tui kill-server

echo "== adversarial: spawn whose base branch does not exist aborts after group placement"
BEFORE=$(wsl)
spawn bad-base "$T/webapp" --base-branch no-such-branch >"$T/bad.out" 2>"$T/bad.err"; echo "bad-base spawn exit=$?"
sed 's/^/  stderr: /' "$T/bad.err" | tail -8
AFTER=$(wsl)
echo "workspace list after abort:"; echo "$AFTER" | jq -c '.[]'
[ "$BEFORE" = "$AFTER" ] && echo "RESULT: workspace list unchanged by aborted spawn" || echo "RESULT: workspace list CHANGED by aborted spawn"
[ -e "$HOME_DIR/state/bad-base.meta" ] && echo "RESULT: bad-base meta left behind" || echo "RESULT: no bad-base meta"
echo "treehouse leases on webapp:"; (cd "$T/webapp" && treehouse list 2>&1 | head -20)

echo "== teardown one child; parent & siblings stay"
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-teardown.sh" fix-login --force >"$T/td.out" 2>&1; echo "teardown exit=$?"
wsl | jq -c '.[]'
