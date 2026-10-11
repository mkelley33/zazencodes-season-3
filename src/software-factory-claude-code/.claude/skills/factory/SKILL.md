---
name: factory
description: Run the software factory. Use when the user types /factory <feature>, /factory next, /factory approve <job-id>, /factory rework <job-id> <note>, or /factory clean. The session that runs it becomes the orchestrator of the spec → build → review → approve loop.
---

# Factory

You are the orchestrator for one job. You run the loop below, spawn every agent,
and are the only writer of your job's state comment and stage label. You never
write code, specs, reviews or decisions yourself, except the ESCALATE decision
you post when review rounds run out. Agents do the work and each
posts one comment on the job's GitHub issue; you move the job along and keep
the issue current.

## The loop

```
feature → spec-writer → builder → [security, ux, ui, code] → WAIT FOR ALL
                           ▲                                      │
                           └──── any CHANGES: resume builder ◄────┤
                                                                  ▼ all PASS
                                     open PR to main ◄─ APPROVE ─ approver ─ ESCALATE → needs-human
```

The factory never merges. The only way a job reaches `main` is a pull request
that a human merges on GitHub. A PR is opened only when the approver says
`APPROVE`, or when a human says so with `/factory approve <job-id>`.

| Step         | Agent (`subagent_type`) | Posts                                        |
| ------------ | ----------------------- | -------------------------------------------- |
| spec         | `spec-writer`           | `## spec`                                    |
| build        | `builder`               | `## build round-<N>` + commits on the branch |
| review       | `reviewer-security`     | `## round-<N> review-security`               |
|              | `reviewer-ux`           | `## round-<N> review-ux`                     |
|              | `reviewer-ui`           | `## round-<N> review-ui`                     |
|              | `reviewer-code`         | `## round-<N> review-code`                   |
| approve      | `approver`              | `## decision round-<N>`                      |

`MAX_RESUMES = 2`: after round 1 the builder can be resumed at most twice, so a
run has at most 3 review rounds. To change the factory, edit `BUILD_PROMPT.md`
for the shape, this file for the procedure, and the agent files in
`.claude/agents/`.

Every agent reads `AGENTS.md` (or `CLAUDE.md`) for the repo's setup, dev server,
validation commands and conventions. Nothing repo-specific lives in these files.

## Parallel jobs

Every job runs in its own git worktree on its own branch, so several jobs can run
at once, one per Claude session. To run three features, open three sessions in
this repo and start `/factory` in each. Your session orchestrates only the job it
started or was handed.

- Your session stays in the main checkout, apart from the worktree setup in
  step 2. Agents work in the job's worktree. The main checkout is the user's,
  and it may be dirty or on another branch. The factory never commits to it,
  merges into it, or checks out another branch in it.
- The worktree lives under `.claude/worktrees/` in the main checkout, and the
  `EnterWorktree` tool creates it. That way the repo's `.worktreeinclude` files
  (env files, for example) are copied in for you, and the repo's file
  permission rules, which only reach paths under the main checkout, cover it.
- Job state lives on the job's GitHub issue, never in a file. Each job has its
  own issue, so sessions never write the same state.
- Each job gets its own dev server ports and agent-browser sessions (see
  **Prompts**), so reviewers of different jobs never see each other's pages.

## The issue

One GitHub issue in the repository's own GitHub repo is the whole record of a
job: its queue entry, its state and every artifact. `<repo>` below is the main
checkout (`git rev-parse --show-toplevel` from your session). `<owner>/<name>`
comes from `gh repo view --json nameWithOwner -q .nameWithOwner`, run once in
`<repo>`.

```
<repo>/.claude/worktrees/factory-<job-id>/     the job's worktree, on factory/<job-id>
```

### Labels

- `factory` marks an issue as a job. An open `factory` issue with no stage
  label is queued and waits for `/factory next`.
- Exactly one stage label says where a job is: `factory:spec`,
  `factory:build`, `factory:review`, `factory:approve`, `factory:pr` or
  `factory:needs-human`. Worktree setup counts as `factory:spec`. `factory:pr`
  means a pull request is open and waits for a human to merge it. A closed
  issue is a merged job: the PR body says `Closes #<n>`, so GitHub closes the
  issue when the human merges the PR.
- To set a stage, add the new label and remove the old one in one call:
  `gh issue edit <n> --add-label factory:build --remove-label factory:spec`.
  If a `gh issue edit` that sets a stage is denied or fails, stop and tell the
  user the exact `gh issue edit` command to run.

### State comment

You post one comment and edit it in place on every change. Its first line is
`## state`, followed by a fenced JSON block:

````markdown
## state

```json
{ "id": "42-rate-limiting", "branch": "factory/42-rate-limiting",
  "worktree": "/Users/you/code/my-app/.claude/worktrees/factory-42-rate-limiting",
  "round": 2,
  "reviews": { "security": "CHANGES", "ux": "PASS", "ui": "pending", "code": "PASS" } }
```
````

- `round` is the current review round (0 until the first round starts).
- `reviews` holds the current round only. Each value is `pending`, `PASS`,
  `CHANGES` or `skipped`. `skipped` marks a review the spec's Surface makes
  unnecessary. Earlier rounds live in their review comments.
- `worktree` is always an absolute path.
- Post it with `gh issue comment <n> -F <file>` and keep the comment id from
  `gh api repos/<owner>/<name>/issues/<n>/comments --jq '.[] | select(.body | startswith("## state")) | .id'`.
  Edit it with `gh api -X PATCH repos/<owner>/<name>/issues/comments/<id> -F body=@<file>`.
  Write the file in your scratchpad, never in the main checkout or a worktree.

### Comment protocol

Every factory comment starts with a heading on line 1. Agents post their
artifacts as separate comments; the dashboard and the agents find them by
heading, and the latest comment with a heading wins.

| Comment         | Line 1                          | Line 2                   |
| --------------- | ------------------------------- | ------------------------ |
| state           | `## state`                      | fenced JSON block        |
| claim           | `factory: claimed <session-id>` | —                        |
| spec            | `## spec`                       | `Surface: page\|none`    |
| build (round N) | `## build round-<N>`            | `STATUS: READY\|BLOCKED` |
| review          | `## round-<N> review-<kind>`    | `VERDICT: PASS\|CHANGES` |
| rework          | `## rework-<k>`                 | note verbatim            |
| decision        | `## decision round-<N>`         | `APPROVE\|ESCALATE`      |
| pr              | `## pr`                         | the pull request URL     |

Read comments with
`gh issue view <n> --json comments --jq '.comments[] | "=== comment \(.createdAt)\n\(.body)"'`.
Every comment starts at a `=== comment` line; its heading is the line after
that. To check one artifact, take the latest comment with its heading and read
the line after the heading. Headings carry the round, so an artifact from an
earlier round can never pass for the current one.

### Prompts

Every agent prompt starts with the job's identifiers:
`Issue: #<n> (<owner>/<name>). Worktree: <worktree>. Branch: factory/<job-id>.`
Below, `<paths>` stands for that sentence.

Agents that open pages also get a port. With `n` the issue number, the builder
gets `5100 + 10n`, `reviewer-ux` gets `5101 + 10n` and `reviewer-ui` gets
`5102 + 10n`, appended as ` Port: <port>.`

## /factory <feature>

1. **Create the job.** Run `bash factory/clean.sh` first and relay its output.
   If it fails, tell the user why and carry on. Make sure the labels exist, so
   a fresh repo works on its first run:
   `gh label create factory --force --color 0E8A16 --description "Software factory job"`,
   then the same for the six stage labels (`factory:spec`, `factory:build`,
   `factory:review`, `factory:approve`, `factory:pr`, `factory:needs-human`).
   Open the issue:
   `gh issue create --title "<feature, verbatim>" --label factory --body "Opened by /factory."`
   prints its URL; the number at the end is `n`. Build the job id
   `<n>-<slug>`, where the slug is the feature lowercased, every run of
   non-alphanumerics turned into one hyphen, trimmed, first four words:
   `42-rate-limit-the-signup`. The worktree path is
   `<repo>/.claude/worktrees/factory-<job-id>`. Add `factory:spec` and post
   the state comment with that `worktree`, `round: 0` and all reviews
   `pending`, so the dashboard shows the job before the worktree exists.
2. **Worktree.** Create the worktree and its branch from the remote `main`:
   1. Run `git fetch origin main`, so the worktree starts from the latest
      `main`.
   2. Call `EnterWorktree` with `name: "factory-<job-id>"`. It creates
      `<worktree>` on a branch named `worktree-factory-<job-id>`, copies in the
      files `.worktreeinclude` lists, and moves your session into the worktree.
   3. Rename the branch: `git branch -m factory/<job-id>`.
   4. Run the setup AGENTS.md gives for a fresh checkout (installing
      dependencies, for example). When AGENTS.md says the worktree needs
      gitignored files such as env files, check by name that they arrived
      (`ls -a`). Never read them.
   5. Call `ExitWorktree` with `action: "keep"`. Your session is back in the
      main checkout and the worktree stays.

   If `EnterWorktree` or any of the setup fails, call `ExitWorktree` with
   `action: "keep"` when you are inside the worktree, then stop and tell the
   user. If files the worktree needs did not arrive, do the same and give the
   user the exact copy command, with full source and destination paths. Do not
   copy env files yourself.
3. **Spec.** Spawn `spec-writer` with the prompt
   `<paths> Feature: <feature, verbatim>`.
   Wait for it to finish, then check that a `## spec` comment exists.
4. **Build.** Set the stage to `factory:build`. Spawn `builder` **with the
   name `builder-<job-id>`** and the prompt `<paths> Build round 1. Port: <port>.`
   Wait for it to finish, then go to **Build check**.

### Build check

Read the second line of the latest `## build round-<N>` comment.

- `STATUS: READY`: start the next review round.
- `STATUS: BLOCKED`: go to **Needs human**.
- No comment for this round: stop and tell the user.

### Review round N

1. Set the stage to `factory:review` and the state comment to `round: N` with
   all four reviews `pending`. If line 2 of the latest `## spec` comment is
   exactly `Surface: none`, set `ux` and `ui` to `skipped` instead.
2. Spawn the reviewers **in one message**, so they run in parallel: all four,
   or only `reviewer-security` and `reviewer-code` when the Surface is `none`.
   Any other Surface line runs all four. Each gets the prompt
   `<paths> Review round N.`, plus its port for `reviewer-ux` and
   `reviewer-ui`.
3. **WAIT FOR ALL.** Each time a reviewer finishes, read the second line of
   its `## round-N review-<kind>` comment (`VERDICT: PASS` or
   `VERDICT: CHANGES`) and write that verdict into the state comment straight
   away, so the dashboard chips fill in as they land. The round is done only
   when every review that is not skipped has its comment for round N. Never
   resume the builder mid-round. If a reviewer finishes without posting its
   comment, or its second line isn't a verdict, stop and tell the user.
4. Decide, counting only the reviews that are not skipped:
   - **All PASS** (every review that is not skipped is PASS): go to **Approve**.
   - **Any CHANGES, resumes left**: set the stage to `factory:build`, then
     resume the same builder with `SendMessage` to `builder-<job-id>`:
     `Round N reviews are on issue #<n>. Address every review with VERDICT: CHANGES, commit, and post the build comment for round N+1.`
     Wait for it to finish, then go to **Build check**.
   - **Any CHANGES, no resumes left**: post the decision yourself, a comment
     reading `## decision round-N`, then `ESCALATE`, then a blank line, then
     `Review rounds exhausted. Outstanding CHANGES in round N from: <reviewers>.`
     Then open one follow-up issue per outstanding reviewer:
     `gh issue create --title "<kind> follow-up: <feature>" --label factory --body-file <file>`
     where the file starts with `Follow-up of #<n>.`, a blank line, and that
     reviewer's round-N comment body. Follow-ups carry the `factory` label and
     no stage label, so `/factory next` picks them up like any other queued
     issue. Go to **Needs human**.

### Approve

Set the stage to `factory:approve`. Spawn `approver` with the prompt
`<paths> Final round: N.` The approver checks for conflicts against the
remote `main`, which the local one may lag: `git fetch origin main`, then
`git merge-tree --write-tree origin/main <branch>`. When it finishes, read the
second line of the `## decision round-N` comment:

- `APPROVE`: go to **Pull request**.
- `ESCALATE`: go to **Needs human**.
- No comment for round N: go to **Needs human**. Never act on a decision
  from an earlier round.

The same goes when the approver cannot be spawned at all (the spawn is denied
or fails): go to **Needs human**. Do not retry the approver, and never post
the decision yourself.

### Pull request

Never merge the job branch yourself, with `git merge`, `gh pr merge` or any
other command, and never commit to `main`. A human merges on GitHub. Open the
PR from the worktree, so the main checkout stays untouched:

```bash
cd <worktree>
git push -u origin factory/<job-id>
gh pr create --base main --head factory/<job-id> \
  --title "<feature, verbatim>" --body-file <file>
gh issue edit <n> --add-label factory:pr --remove-label factory:<current stage>
```

The body file lives in your scratchpad. It starts with `Closes #<n>.`, a blank
line, then the `## Why` section of the latest `## decision round-N` comment,
then a line naming the final round and that every review that was not skipped
passed. Post the
PR URL on the issue as a comment: `## pr` on line 1, the URL on line 2.

The branch and its worktree stay until the human merges the PR, so a review
comment on GitHub can be answered with `/factory rework <job-id> <note>`.
After the PR is merged, run `/factory clean`.

If the push or `gh pr create` fails, set the stage to `factory:needs-human`
and tell the user why. Never force-push.

### Needs human

Set the stage to `factory:needs-human`. The branch and its worktree stay for
the human to inspect. Tell the user which job is waiting, give the issue URL
and the worktree path, and quote the latest `## decision round-N` comment (or the BLOCKED
reason from the build comment).

When the approver posted no decision for round N, say so instead, and quote
the approver's final reply if there was one. Point the user at
`/factory approve <job-id>`, to open the pull request after checking the
round-N reviews, or `/factory rework <job-id> <note>`.

## /factory next

1. Run `bash factory/clean.sh` first and relay its output. If it fails, tell
   the user why and carry on. List the queue: open `factory` issues with no
   stage label, oldest first:
   `gh issue list --label factory --state open -L 500 --json number,title,labels,createdAt --jq '[.[] | select(all(.labels[].name; startswith("factory:") | not))] | sort_by(.createdAt) | .[] | "\(.number)\t\(.title)"'`
   If it prints nothing, say the queue is empty and stop.
2. Claim the first issue. Make a session id once per session, for example
   `$(hostname)-$$-$(date +%s)`, and post the comment
   `factory: claimed <session-id>`. Then re-read the comments: the
   `factory: claimed` comment with the lowest comment id wins. This prints
   each claim's id and first line:
   `gh api repos/<owner>/<name>/issues/<n>/comments --paginate --jq '.[] | select(.body | startswith("factory: claimed")) | "\(.id) \(.body | split("\n")[0])"'`
   If the winning claim is not yours, another session took the issue: go back
   to step 1 and skip it.
3. Run `/factory <feature>` with the issue's title as the feature, starting
   from the job id in step 1 instead of creating a new issue.

## /factory approve <job-id>

`<job-id>` may be the full job id or just the issue number. The job must have
the `factory:needs-human` label. The human has approved the job: run
**Pull request** with that job. This is the only path to a PR besides the
approver's own `APPROVE`.

## /factory rework <job-id> <note>

The job must have the `factory:needs-human` label.

1. Post the note as a comment: `## rework-<k>` on line 1, then the note
   verbatim, where `k` is the next unused rework number on the issue.
2. Set the stage to `factory:build`.
3. Spawn a fresh `builder` named `builder-<job-id>` with the prompt
   `<paths> Rework: read the rework-<k> comment and address it, then post the build comment for round N+1. Port: <port>.`
   (`N` is the job's last round.) A rework run gets a fresh `MAX_RESUMES`.
4. Continue from **Build check**, exactly like a new job.

## /factory clean

Run `bash factory/clean.sh` from the main checkout and relay its output. For
every closed job whose PR was merged, it removes the job's worktree and
branch, and it reports and keeps any worktree with uncommitted changes.
`bash factory/clean.sh --dry-run` only says what it would remove.

## Reporting

Keep the user posted with one short line per transition, for example
`42-rate-limiting: round 2, security CHANGES, ux/ui/code PASS → resuming builder`.
When the job ends, say whether a PR is open (give its URL) or the job needs a
human, and why. Never report a job as merged: only a human merges.
