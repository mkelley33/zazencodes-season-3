# GitHub issues are the factory's job record

The software factory template used to keep each job in a `factory/jobs/<id>/`
folder (a `job.json` plus one markdown file per agent) and queue work in
`factory/backlog.md`, with a dashboard served from that folder. We decided
that a GitHub issue is the job instead: the `factory` label queues it, a
`factory:<stage>` label and one editable state comment hold its state, agents
post their artifacts as comments, and a closed issue is a merged job. The
dashboard reads GitHub through a small local proxy over the `gh` CLI.

We chose this because the job record then lives where the team already looks,
survives a deleted checkout, is shared across machines, and lets anyone queue
work by opening an issue. Two smaller options were rejected: moving only the
backlog to issues, and moving the backlog and `job.json` but keeping the
artifact files. Both would have split a job's record over two places.

## Consequences

- The factory and the dashboard need `gh`, logged in with access to the repo.
- Reads count against GitHub's API rate limit. The dashboard uses ETags and
  backs off when the limit runs low.
- Merging is local: the issue closes when the orchestrator merges into the
  local `main`, which may not have been pushed yet.
- When review rounds run out, each outstanding review opens a new `factory`
  issue that is queued automatically, with no limit on how many generations of
  follow-ups a job can spawn. This was a deliberate choice, not an oversight.
