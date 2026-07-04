---
name: stuck-crewmate-recovery
description: Agent-only playbook for stuck firstmate direct reports. Use after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer. Escalates from peek, to one-line steer, to harness-specific interrupt, to wedge diagnosis, to relaunch with progress, to failed status.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `bin/fm-send.sh`.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `bin/fm-send.sh <window> --key Escape`.
4. Before any relaunch, diagnose the wedge from the pane and the brief.
   If the crewmate is circling a question the brief cannot answer (a spec gap), do not relaunch the same brief: resolve it yourself when it is technical, or escalate exactly one option-listing question to the captain, then exit the agent with the adapter's exit command and relaunch with the answer appended to the progress note.
   If the brief is over-scoped (real progress landed, wedged only on the remainder), record what landed and file the remainder as a new smaller task instead of a second relaunch.
   Relaunch the same brief as-is only for execution wedges.
5. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
6. If a second relaunch fails too, write `failed` to the backlog and tell the captain with evidence.
