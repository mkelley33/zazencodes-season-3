# Software Factory for Claude Code

A small, visual software factory built from one skill, seven subagents and
GitHub issues. You type `/factory <feature>` and agents write a spec, build it
on its own branch, review it from four angles, and either merge it to `main` or
hand it to you.

```
feature → spec-writer → builder → [security, ux, ui, code] → WAIT FOR ALL
                           ▲                                      │
                           └──── any CHANGES: resume builder ◄────┤
                                                                  ▼ all PASS
                                     merge to main ◄─ APPROVE ─ approver ─ ESCALATE → needs-human
```

This folder is laid out like a repo root, so you can copy it straight into
yours.

```
.claude/
  skills/factory/SKILL.md        the orchestrator: runs the loop, keeps the issue current
  agents/                        one file per agent in the loop
    spec-writer.md               opus    posts the spec comment
    builder.md                   opus    commits on factory/<job-id>, posts the build comment
    reviewer-security.md         opus    posts the round-N security review
    reviewer-ux.md               sonnet  posts the round-N UX review
    reviewer-ui.md               sonnet  posts the round-N UI review
    reviewer-code.md             sonnet  posts the round-N code review
    approver.md                  opus    posts the decision comment
factory/
  dashboard.html                 the visual board
  serve.py                       serves the board and reads GitHub through gh
BUILD_PROMPT.md                  the prompt that built the original factory
```

## How it works

- Every job is one GitHub issue in your repo, labeled `factory`. The issue is
  the queue entry, the state and the record: a `factory:<stage>` label says
  where the job is, a state comment holds the round and verdicts, and every
  agent posts its artifact as a comment. A closed issue is a merged job.
- The session that runs `/factory` becomes the orchestrator. It spawns every
  agent and is the only writer of the job's label and state comment.
- Agents get their context from the issue and the repo, not the conversation,
  and each posts only its own comment. Every comment starts with a heading,
  such as `## spec`, `## round-1 review-ux` or `## decision round-1`. Every review's second line is
  `VERDICT: PASS` or `VERDICT: CHANGES`; the decision's is `APPROVE` or
  `ESCALATE`.
- The four reviewers run in parallel. A round is done only when all four
  comments exist. If any says CHANGES, the same builder is resumed (at most
  twice). When the rounds run out, each outstanding review becomes a new
  `factory` issue, queued for `/factory next`.
- Each job gets its own git worktree under `.claude/worktrees/` on a
  `factory/<job-id>` branch, where the job id is the issue number plus a slug.
  Open several sessions and run `/factory` in each to build features in
  parallel.

## Commands

```
/factory <feature>               open an issue for the feature and run it through the loop
/factory next                    claim the oldest open `factory` issue nobody has started
/factory approve <job-id>        merge a needs-human job into main
/factory rework <job-id> <note>  send a needs-human job back to the builder with feedback
```

`/factory next` is how you queue work: open an issue, add the `factory` label,
and a session will pick it up.

## Use it in your repo

1. Copy `.claude/` and `factory/` into your repo root.
2. Install the [`gh`](https://cli.github.com) CLI and run `gh auth login` with
   access to the repo. The factory creates its labels on the first run.
3. Make sure your `AGENTS.md` (or `CLAUDE.md`) says how to set up a fresh
   checkout, start the dev server on a given port, and run your tests, build
   and lint. The agents carry nothing repo-specific; they read all of it from
   there.
4. Install the [`agent-browser`](https://github.com/vercel-labs/agent-browser)
   CLI if your project has pages to look at. The builder and the UX and UI
   reviewers use it to check the running app.
5. Commit everything on `main`, then run `/factory <feature>`.

The review checklists are deliberately general. Ask Claude to tailor them to
your stack: your framework, your security hot spots, and what the approver
should always escalate.

## Dashboard

```bash
python3 factory/serve.py
```

Open <http://127.0.0.1:8765/>. The server reads your repo's `factory` issues
through `gh`, so it needs the same login as the factory. Jobs move across the
stages as cards, review chips fill in as verdicts land, and jobs that need you
stand out. Click a card to read its comments. It polls every ten seconds and
backs off when GitHub's rate limit runs low, so leave it open while jobs run.
Pass `--repo owner/name` to watch a repo other than the current directory's.

## BUILD_PROMPT.md

The prompt used to build the original factory, kept verbatim for reference.
If you are copying this folder as a template, ignore it.

The factory has grown since then: it now runs each job in its own git worktree
and records every job on its own GitHub issue, instead of the single
`board.json` the prompt describes, so several jobs can run at once.
