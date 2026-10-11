# Software Factory for Claude Code

A small, visual software factory built from one skill, seven subagents and
GitHub issues. You type `/factory <feature>` and agents write a spec, build it
on its own branch, review it from four angles, and either open a pull request
to `main` or hand it to you. The factory never merges: you merge the PR on
GitHub.

```
feature → spec-writer → builder → [security, ux, ui, code] → WAIT FOR ALL
                           ▲                                      │
                           └──── any CHANGES: resume builder ◄────┤
                                                                  ▼ all PASS
                                     open PR to main ◄─ APPROVE ─ approver ─ ESCALATE → needs-human
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
  hooks/factory-guard.sh         the Guard: blocks merges and pushes to main
  settings.json                  runs the Guard, allows the factory's gh issue comment and gh issue edit
factory/
  dashboard.html                 the visual board
  serve.py                       serves the board and reads GitHub through gh
  clean.sh                       removes the worktree and branch of merged jobs
BUILD_PROMPT.md                  the factory's shape: loop, files, rules, commands
```

## How it works

- Every job is one GitHub issue in your repo, labeled `factory`. The issue is
  the queue entry, the state and the record: a `factory:<stage>` label says
  where the job is, a state comment holds the round and verdicts, and every
  agent posts its artifact as a comment. `factory:pr` means a pull request is
  open and waits for you. A closed issue is a merged job: the PR says
  `Closes #<n>`, so merging it closes the issue. An issue closed as
  not planned is an abandoned job and is left off the board.
- The session that runs `/factory` becomes the orchestrator. It spawns every
  agent and is the only writer of the job's label and state comment.
- Agents get their context from the issue and the repo, not the conversation,
  and each posts only its own comment. Every comment starts with a heading,
  such as `## spec`, `## round-1 review-ux` or `## decision round-1`. Every review's second line is
  `VERDICT: PASS` or `VERDICT: CHANGES`; the decision's is `APPROVE` or
  `ESCALATE`.
- The spec's second line is its Surface: `Surface: page` when the change
  shows on a page someone can open, `Surface: none` for scripts, backend,
  docs or config. With `none` there is nothing to look at, so the UX and UI
  reviews are skipped and their chips show greyed on the board.
- The reviewers run in parallel. A round is done only when every review that
  is not skipped has its comment, and only those reviews count. If any says
  CHANGES, the same builder is resumed (at most twice). When the rounds run
  out, each outstanding review becomes a new `factory` issue, queued for
  `/factory next`.
- Each job gets its own git worktree under `.claude/worktrees/` on a
  `factory/<job-id>` branch, where the job id is the issue number plus a slug.
  Open several sessions and run `/factory` in each to build features in
  parallel.

## Commands

```
/factory <feature>               open an issue for the feature and run it through the loop
/factory next                    claim the oldest open `factory` issue nobody has started
/factory approve <job-id>        open a pull request for a needs-human job
/factory rework <job-id> <note>  send a needs-human job back to the builder with feedback
/factory clean                   remove the worktree and branch of every merged job
```

`/factory next` is how you queue work: open an issue, add the `factory` label,
and a session will pick it up. `/factory next` and `/factory <feature>` run
`/factory clean` first, so merged jobs don't pile up.

## The Guard

`.claude/hooks/factory-guard.sh` runs before every Bash command an agent or
the orchestrator runs, through the hook in `.claude/settings.json`. It blocks
the common forms of `git merge`, `gh pr merge`, pushes to `main`, force
pushes, `git branch -D` and commits on `main`, and allows any command it
cannot parse. Text inside quotes or a heredoc, such as a review that quotes
`git push --force`, passes. What stops direct pushes to the remote `main` is
GitHub branch protection, which Install sets unless you pass
`--no-protect-main`.

If you copy the folder by hand into a repo that already has its own
`.claude/settings.json`, keep yours and add the `PreToolUse` entry and the
`permissions.allow` entries from the template's `settings.json` to it by hand.

## Permissions

The factory needs two commands to run without asking: every agent posts its
comment with `gh issue comment`, and the orchestrator moves the stage label
with `gh issue edit`. The template's `.claude/settings.json` allows exactly
those two command prefixes, `Bash(gh issue comment *)` and
`Bash(gh issue edit *)`, and the Install adds them to your own settings
through the Hook merge. It names each rule it adds.

Those rules match any arguments. Without a prompt, any agent can post any
text as a comment, or any file it can read (`--body-file <path>`), and edit
any issue's title, body or labels, in any repo your `gh` login can reach.
Deleting a posted comment does not unpublish it, since GitHub has already
notified the issue's watchers, so a leaked secret stays leaked. The
agents read every comment on the issue, and on a public repo anyone can
comment, so treat other users' comments as untrusted input. To opt out,
delete the two entries from `permissions.allow`. You then answer those
prompts again, and a missing decision still ends in `factory:needs-human` as
described below.

Everything else is left to your session's permission mode: the builder's
commits and your repo's test commands, `gh issue create`, `gh label create`,
`gh api`, `git push`, `gh pr create`, and spawning agents. In default mode you
answer those prompts as they come up.

These rules do not guarantee an unattended run. In auto mode the classifier
can still deny an action it reads as an agent approving its own work
(`[Self-Approval]`), including the approver's decision comment or spawning the
approver at all. The job then goes to `factory:needs-human` with no decision
comment. Check the round's reviews on the issue, then run
`/factory approve <job-id>` to open the pull request, or
`/factory rework <job-id> <note>` to send it back to the builder.

## Use it in your repo

1. Copy `.claude/` and `factory/` into your repo root. Or, from the repo this
   template comes from, run `bash scripts/install-software-factory.sh`: it
   asks for the Target path, copies only what your repo is missing, adds the
   Guard and the factory's permission rules to your existing
   `.claude/settings.json` (a Hook merge), and by default (`--protect-main`)
   protects `main` on GitHub: a pull request is required, force pushes and
   deletion are refused. Pass `--no-protect-main` to skip that step. The Hook
   merge needs `jq`; without it the settings file is left as it is and the
   hooks and permission rules are printed for you to add by hand.
   Pass `--force` to overwrite the Template files that differ in your repo
   (each different Skip that is a regular file becomes an Overwrite).
   Directories, symlinks and your `.claude/settings.json` are never
   overwritten, and a Conflict still stops the Install.
2. Install the [`gh`](https://cli.github.com) CLI and run `gh auth login` with
   access to the repo. Install warns when `gh` is missing but does not
   install it or log you in. The factory creates its labels on the first run.
3. Make sure your `AGENTS.md` (or `CLAUDE.md`) says how to set up a fresh
   checkout, start the dev server on a given port, and run your tests, build
   and lint. The agents carry nothing repo-specific; they read all of it from
   there.
4. The builder and the UX and UI reviewers use the
   [`agent-browser`](https://github.com/vercel-labs/agent-browser) CLI to
   check the running app. Install does not install it unless you pass
   `--install-agent-browser`. Without the flag it downloads nothing and
   prints the command to run yourself:
   `brew install agent-browser && agent-browser install`. With the flag it
   installs it with Homebrew when it is missing. If you copied the folder by
   hand or have no Homebrew, install it yourself if your project has pages to
   look at.
5. Commit the Template on a branch, open a pull request, merge it on GitHub
   and pull `main`, so `main`, local and remote, has the factory. Then run
   `/factory <feature>`.

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
Pass `--repo owner/name` to watch a repo other than the current directory's,
and `--port` to listen on a port other than 8765. The server listens on
127.0.0.1 only, refuses requests without a local Host header, and reads
nothing but the repo's issues and their comments.

## BUILD_PROMPT.md

The factory's shape: the loop diagram, the files, the rules and the commands.
It started as the prompt that built the original factory and is now kept up
to date as the design doc. `SKILL.md` holds the procedure, `BUILD_PROMPT.md`
the shape. To change the factory, change the shape there first, then make
`SKILL.md` and the agent files match.
