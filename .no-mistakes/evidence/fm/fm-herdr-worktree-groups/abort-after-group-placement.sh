#!/usr/bin/env bash
set -u
ROOT=/home/lee/.no-mistakes/worktrees/78e11e7c1ced/01M4BXYVWA7XE9EXEJVSYMJFV2
H="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"; herdr_forget_inherited_pane
T=$(mktemp -d /tmp/fm-manual-wtg/abort.XXXXXX)
S=$("$H" name wtg-abort); export HERDR_SESSION=$S
echo "session=$S"
WTS=""
cleanup() {
  [ -d "$T/webapp.origin.git.gone" ] && mv "$T/webapp.origin.git.gone" "$T/webapp.origin.git"
  while IFS=$'\t' read -r wt p; do [ -n "$wt" ] && [ -d "$wt" ] && (cd "$p" && treehouse return --force "$wt") >/dev/null 2>&1; done <<<"$WTS"
  (cd "$T/webapp" 2>/dev/null && treehouse destroy --help >/dev/null 2>&1)
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
wsl() { lab workspace list | jq -c '[.result.workspaces[] | {workspace_id,label,tab_count,linked:.worktree.is_linked_worktree}]'; }
HOME_DIR="$T/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"; touch "$HOME_DIR/state/.last-watcher-beat"
mkproj "$T/webapp"; brief ok1; brief broken
spawn ok1 "$T/webapp" >"$T/ok1.out" 2>"$T/ok1.err" || { cat "$T/ok1.err"; exit 1; }
WTS+="$(mf "$HOME_DIR/state/ok1.meta" worktree)"$'\t'"$T/webapp"$'\n'
echo "after ok1:"; wsl
echo "treehouse status before:"; (cd "$T/webapp" && treehouse status 2>&1)
git -C "$T/webapp.origin.git" symbolic-ref HEAD refs/heads/ghost
spawn broken "$T/webapp" >"$T/b.out" 2>"$T/b.err"; echo "broken spawn exit=$?"
sed 's/^/  stderr: /' "$T/b.err"
echo "after aborted spawn:"; wsl
[ -e "$HOME_DIR/state/broken.meta" ] && echo "RESULT: broken.meta left" || echo "RESULT: no broken.meta"
echo "treehouse status after:"; (cd "$T/webapp" && treehouse status 2>&1)
lab worktree list --cwd "$T/webapp" | jq -c '[.result.worktrees[] | {path,open_workspace_id}]'
:
