<h1 align="center">firstmate</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.png" width="100%" />
</p>

> This is [korallis/firstmate](https://github.com/korallis/firstmate), a maintained fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate) with research-hardened orchestration instructions.
> See [What's different in this fork](#whats-different-in-this-fork); everything else is upstream firstmate, kept current by fast-forward syncs.

## Why this exists

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
For larger fleets, you can opt in to persistent secondmates: domain supervisors that are still ordinary direct reports, but run from their own isolated firstmate homes.
There is no app to install; the orchestrator is `AGENTS.md`, bundled firstmate skills, and helper scripts that any terminal coding agent can follow.

This is not an agent harness.
This is not a single skill.
This is not a CLI.
It is a directory - `AGENTS.md`, bundled skills, and a bash toolbelt - that turns any terminal coding agent into your first mate.
There is no app to install and no daemon to babysit: orchestration state lives on disk and in the session backend, so you can kill everything at any time and the next session reconciles and carries on.

## What's different in this fork

This fork's instructions were hardened by a multi-agent research review of three prompting/planning papers (least-to-most prompting, uncertainty decomposition for clarification seeking, uncertainty of thoughts) and the waves fan-out skill.
The review's headline was negative: none of the papers' actual mechanisms survived adversarial scrutiny on current reasoning models, and upstream firstmate's architecture was already on the right side of the evidence.
What did survive is verification discipline, merged as [PR #1](https://github.com/korallis/firstmate/pull/1):

| Change | Where |
| ------ | ----- |
| Scout reports open with `Status: success\|partial` and a coverage line, tag each finding `high\|med\|low` confidence, and separate verified from inferred | scout brief contract (`bin/fm-brief.sh`) |
| A scout's `done` is a claim, not evidence: relays carry confidence labels, and findings that drive expensive-to-reverse decisions get a second blind-verifier scout (claims + evidence only, no authorship) | `AGENTS.md` section 7 |
| The stuck-crewmate ladder diagnoses the wedge (spec gap vs over-scoped vs execution) before relaunching the same brief | `stuck-crewmate-recovery` skill |
| `needs-decision` escalations carry the concrete options plus a recommended default, and crewmates explore the repo, docs, and experiments before escalating | brief rule 6, both templates |
| Intake resolves scope ambiguity the same way it resolves project ambiguity: proceed on a stated assumption, ask only the one question that discriminates genuinely forked readings | `AGENTS.md` section 7 |
| Multi-task splits state the partition remainder, and a brief for a task unblocked by a predecessor names that predecessor's PR URL or report path | `AGENTS.md` sections 7 and 11 |

Everything below this section is firstmate behavior as it runs in this fork; apart from the verification discipline above, it is shared with upstream.

## Features

- **One liaison** - you talk only to the first mate; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible crew** - every crewmate works in its own tmux window, experimental herdr/zellij tab, cmux workspace, or Orca terminal you can watch or type into; the first mate reconciles.
- **Disposable worktrees** - each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, or an Orca-managed worktree when `backend=orca`, so parallel work on one repo never collides.
- **Two task shapes** - ship tasks deliver a change; scout tasks investigate, plan, reproduce, or audit and leave a report.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` autonomy flag.
- **Optional secondmates** - opt in to persistent domain supervisors that run from isolated firstmate homes with their own `FM_HOME`, state, projects, and session lock, kept on the primary firstmate version by guarded local fast-forwards.
- **Event-driven, zero-token supervision** - a bash watcher sleeps on the fleet and wakes the first mate only when something needs you.
- **Optional X mode** - opt in with one local `.env` token so firstmate can answer your public `@myfirstmate` mentions, act on normal reversible mention requests through the same lifecycle as chat requests, acknowledge spawned work, and post up to three public-safe completion follow-ups within seven days for genuine milestones and the final outcome without changing non-X behavior; dry-run preview records would-be replies and dismissals locally before go-live.
- **Guarded by construction** - the first mate is read-only over your projects outside guarded clone refreshes, safe branch pruning, and approved `local-only` fast-forward merges; crewmates make every project change behind your merge approval.
- **Restart-proof** - all state lives on disk and in the active session backend (tmux by hard default, herdr when selected or auto-detected, zellij/orca/cmux when explicitly selected); kill the session anytime and the next one reconciles and carries on.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

**Requirements:** a verified agent harness (claude, codex, opencode, pi, or grok), git with GitHub auth, and tmux for the reference session backend.
The first mate detects and offers to install everything else.

```sh
gh auth login
git clone https://github.com/kunchenguid/firstmate
cd firstmate && claude   # launch your harness here; AGENTS.md takes over
```

Then just talk:

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/, and spawns two crewmates in the active backend
# fm-fix-login-k3 and fm-dark-mode-p7.
# Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

Setup guides for tmux (the default) and every other supported backend (herdr, zellij, Orca, cmux) are linked in [Documentation](#documentation) below.

## How It Works

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/ (read-only)+routes  │
 │ writes backlog/briefs/state freely  │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   tmux windows, herdr/zellij tabs, cmux workspaces, or Orca terminals
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree, Orca worktree, or isolated secondmate home
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► verify ► relay ► teardown
```

You chat with the first mate.
It routes each request to a crewmate in its own session endpoint and git worktree, supervises the fleet with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or investigation reports.
Optional secondmates extend this to persistent domain supervisors, dispatch profiles let you steer which harness handles which task, and an opt-in X mode lets the same fleet answer public mentions.

Full architecture - the supervision engine, worktree isolation, secondmates, dispatch profiles, project modes, optional X mode, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

### Ship vs scout

A **ship** task changes a project and ends in a merge.
A **scout** task answers a question - "what's wrong", "how would we", "find out why" - and ends in a report at `data/<id>/report.md` that opens with status and coverage, tags each finding with confidence, and separates what was verified from what was inferred.
A scout whose findings reveal shippable work can be promoted in place, keeping its worktree and loaded context.

### Delivery modes

| Mode | Path to main | Who approves |
| ---- | ------------ | ------------ |
| `no-mistakes` (default, highest assurance) | full validation pipeline (review, test, docs, lint) → PR → CI | you merge the PR |
| `direct-PR` | crewmate pushes and opens the PR itself, no pipeline | you merge the PR |
| `local-only` | local branch, no remote, no PR; the first mate reviews the diff | you approve, it fast-forwards local `main` |

Orthogonal to mode, `+yolo` (off by default, not recommended) lets the first mate make routine approval calls itself; anything destructive, irreversible, or security-sensitive still escalates to you.

### Scaling up: secondmates

For larger fleets, a **secondmate** is a persistent domain supervisor - itself a full firstmate running from an isolated home with its own state, backlog, and project clones.
The first mate routes work to it by matching your request against each secondmate's natural-language scope; the secondmate runs the same lifecycle inside its own home and reports back through status files.
Secondmates are idle by default: they never invent their own work, and an empty queue is a healthy resting state.
Secondmate homes inherit the primary's crew harness, dispatch profiles, and backlog backend, so their own crews follow your settings.

### Harnesses and backends

Verified harnesses: **claude, codex, opencode, pi, and grok** - the first mate, crewmates, and secondmates can each run on a different one (`config/crew-harness`, `config/secondmate-harness`).
An optional `config/crew-dispatch.json` holds natural-language dispatch rules ("use grok for news-dependent work", "use haiku for trivial edits") that the first mate weighs per task; copy [docs/examples/crew-dispatch.json](docs/examples/crew-dispatch.json) to start.
The session backend is **tmux** (the verified reference); **herdr** is an experimental alternative, auto-detected when firstmate runs natively inside it - see [docs/herdr-backend.md](docs/herdr-backend.md).

## Install

**Requirements:** a verified agent harness (claude, codex, opencode, pi, or grok), git with GitHub auth, and tmux for the reference session backend.
Experimental herdr spawns additionally require `herdr` and `jq`, checked at spawn time.
The first mate detects and offers to install everything else it needs - node, gh, treehouse (with durable-lease support), no-mistakes (v1.31.2+), the AXI CLIs, and optionally tasks-axi (v0.1.1+) for backlog management.
Nothing is ever installed without your consent.

```sh
gh auth login
git clone https://github.com/korallis/firstmate   # this fork; upstream is kunchenguid/firstmate
cd firstmate && claude   # launch your harness here; AGENTS.md takes over
```

Run it inside tmux for the best experience: every crewmate window lands in your own session, where you can watch the crew work in real time or type into any window to intervene.
Outside tmux, default-backend crewmates land in a detached `firstmate` session you can attach to; on the experimental herdr backend, attach to the selected `HERDR_SESSION` and switch between per-home workspaces - the primary uses `firstmate`, each secondmate uses `2ndmate-<secondmate-id>`, with that home's task tabs inside its own space ([docs/herdr-backend.md](docs/herdr-backend.md)).

### Keeping this fork current

The fork does not auto-sync with upstream.
Pull Kun Chen's latest into the fork, then update your running instance:

```sh
gh repo sync korallis/firstmate    # fork ← upstream, on GitHub
/updatefirstmate                   # in the running first mate: fast-forward pull + re-read instructions
```

## Using it

Just talk.
Some real shapes of conversation:

**Parallel ship tasks:**

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/, and spawns two crewmates in windows
# fm-fix-login-k3 and fm-dark-mode-p7. Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

**A scout investigation:**

```sh
> find out why the export job in dataproc got 10x slower last week

# firstmate dispatches an investigator; you get verified findings, not a PR.
# The report lands at data/<id>/report.md with coverage, per-finding
# confidence, and verified-vs-inferred separation; the first mate relays
# the findings and can promote the task in place if you want the fix shipped.
```

**Adding a project with an explicit mode:**

```sh
> add my repo github.com/you/scratchpad as local-only

# firstmate clones it and records the mode; future changes stop at a local
# branch - it reviews the diff, you approve, it fast-forwards local main.
```

**Stepping away:**

```sh
> /afk back in an hour

# a sub-supervisor daemon self-handles routine wakes and batches only
# captain-relevant events into one digest; any normal message brings you back.
```

**Steering the fleet's harnesses:**

```sh
> use codex for crewmates from now on          # recorded in config/crew-harness
> run this one on grok                          # per-task override
> use haiku on low effort for trivial edits     # becomes a crew-dispatch.json rule
```

You can also watch or type into any `fm-<id>` window directly - the first mate treats your intervention as authoritative and reconciles.

### Built-in skills

Firstmate ships these user-invocable built-in skills.
Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the sub-supervisor self-handles routine wakes in bash and escalates only captain-relevant events as one batched digest, cutting supervision cost while you step away |
| `/updatefirstmate` | Self-update the running firstmate and its secondmates to the latest from origin with fast-forward-only pulls, then re-read instructions and nudge secondmates |
| `/stow`            | Sweep the session for uncaptured durable knowledge, route each finding to its disk home per AGENTS.md, file undone next steps to the backlog, and report what is now safe to reset |

Agent-only reference skills (harness adapters, stuck-crewmate recovery, secondmate provisioning, X-mention handling) live under `.agents/skills/` and are loaded by firstmate at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Optional X mode

Put one `FMX_PAIRING_TOKEN` into a gitignored `.env` at the firstmate home's root (the repo root by default) and firstmate answers your public `@myfirstmate` mentions from its live fleet state, running actionable mentions through the normal lifecycle with one public-safe completion follow-up.
Anything destructive, irreversible, or security-sensitive is never executed from a public mention; it is flagged to you through the trusted channel first.
Set `FMX_DRY_RUN=1` to preview every would-be reply in `state/x-outbox/` without posting.
Remove the token and the next session reverts to normal.

## Guardrails

- The first mate is read-only over your projects outside a handful of guarded operations (clone refreshes, safe branch pruning, project-gate initialization, approved `local-only` fast-forward merges); crewmates make every change, in isolated worktrees, behind your merge approval.
- PRs are never merged without your explicit word (or a per-project `+yolo` you opted into, which still escalates anything destructive, irreversible, or security-sensitive).
- Teardown refuses worktrees holding uncommitted or unlanded work; `--force` exists only for an explicit captain-ordered discard.
- Everything personal to your fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored and never leaves your machine.

### Two-tier skill layout

Firstmate's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus firstmate's agent-only reference skills). Every one of these assumes a live firstmate home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how firstmate itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of firstmate.
  Each one is a self-contained skill with no dependency on firstmate's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback in the current directory, and closes with a resume pointer for the next session.
  It intentionally shares no code with the firstmate-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

- [docs/architecture.md](docs/architecture.md) - how the crew, supervision, worktrees, secondmates, and project modes work.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional X mode, the files you set, and harness support.
- [docs/tmux-backend.md](docs/tmux-backend.md) - setup guide for the tmux reference backend: prerequisites, attaching, and watching crew windows.
- [docs/herdr-backend.md](docs/herdr-backend.md) - setup guide for the experimental herdr backend, plus its verification notes and known gaps.
- [docs/zellij-backend.md](docs/zellij-backend.md) - setup guide for the experimental zellij backend, plus its verification notes and known gaps.
- [docs/orca-backend.md](docs/orca-backend.md) - setup guide for the experimental Orca backend, plus its lifecycle notes and known gaps.
- [docs/cmux-backend.md](docs/cmux-backend.md) - setup guide for the experimental cmux backend, plus its verification notes and known gaps.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/herdr-backend.md](docs/herdr-backend.md) - the experimental herdr session backend.
- [`AGENTS.md`](AGENTS.md) - firstmate's full operating manual for the orchestrator agent.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.
Changes that belong to firstmate generally (rather than this fork's instruction hardening) are best offered upstream to [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate).

## License

MIT - see [LICENSE](LICENSE).
firstmate is created by [Kun Chen (@kunchenguid)](https://github.com/kunchenguid); this fork tracks upstream and adds research-derived instruction hardening.
