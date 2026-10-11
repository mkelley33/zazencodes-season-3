# ZazenCodes Season 3

Companion source for the ZazenCodes Season 3 videos, plus the maintenance
scripts that place a video's project template into another project.

## Language

### Template install

**Template**:
The content of `src/software-factory-claude-code`, laid out like a repository root so it can be placed into another project.
_Avoid_: Source, factory

**Install**:
An Additive copy of the Template into a Target, followed by the setup the Target needs before its first factory run: a Hook merge into the Target's existing settings, and protection of the Target's `main` branch on GitHub unless told not to. With `--force`, the Install also makes an Overwrite of every different Skip that is a regular file, apart from the Target's settings.
_Avoid_: Copy, deploy

**Target**:
An existing directory that receives the Template.
_Avoid_: Destination, repo

**Additive copy**:
A copy that only adds entries to the Target and never changes or removes an entry that is already there.
_Avoid_: Merge, sync

**Skip**:
A Template file left uncopied because the Target already has an entry at that path. An identical Skip has the same content as the Template file; a different Skip does not.
_Avoid_: Clobber

**Overwrite**:
A different Skip that is a regular file, not a symlink, replaced with the Template file because the Install ran with `--force`. A directory or a symlink at a Template file's path is never overwritten.
_Avoid_: Clobber, force copy

**Conflict**:
A Target entry that cannot act as a directory where the Template has one: a symlink or a file. A Conflict blocks the whole Additive copy.
_Avoid_: Collision, clobber

### Factory

**Job**:
One feature run through the factory loop, from spec to an open pull request or to a human. A Job is recorded as one Issue. The factory never merges a Job; a human merges its pull request on GitHub.
_Avoid_: Task, run

**Issue**:
The GitHub issue that is a Job's record: its Queue entry, its state and its Artifacts.
_Avoid_: Ticket, job folder

**Queue**:
The open Issues labeled `factory` that no session has started.
_Avoid_: Backlog

**Claim**:
A session's comment that takes an Issue from the Queue. The Claim with the lowest comment id wins.
_Avoid_: Lock, assignment

**Stage label**:
The single `factory:*` label that says where a Job is in the loop.
_Avoid_: Status

**State comment**:
The orchestrator's one comment on an Issue, holding the Job's round, verdicts, branch and worktree.
_Avoid_: job.json

**Artifact**:
A comment one agent posts once per step: the spec, a build, a review, a decision or a rework note.
_Avoid_: File

**Follow-up**:
An Issue opened for a review finding left unresolved when a Job escalates. A Follow-up enters the Queue.
_Avoid_: Child issue

**Surface**:
Whether a Job's change shows on a page someone can open: `page` or `none`. The spec states it.
_Avoid_: UI flag

**Skipped review**:
A review the Surface makes unnecessary: the UX and UI reviews of a Job whose Surface is `none`. A round counts only the reviews that are not skipped.
_Avoid_: N/A

**Guard**:
The rule that blocks merges, pushes to `main` and commits on `main`, so a Job reaches `main` only through a pull request a human merges.
_Avoid_: Hook, protection

**Hook merge**:
The Install adding the Guard to a Target's existing settings, leaving everything else in them as it was.
_Avoid_: Patch

**Clean**:
Removing the worktree and branch of a Job whose pull request was merged.
_Avoid_: Cleanup, gc
