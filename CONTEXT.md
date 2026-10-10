# ZazenCodes Season 3

Companion source for the ZazenCodes Season 3 videos, plus the maintenance
scripts that place a video's project template into another project.

## Language

### Template install

**Template**:
The content of `src/software-factory-claude-code`, laid out like a repository root so it can be placed into another project.
_Avoid_: Source, factory

**Install**:
An Additive copy of the Template into a Target, followed by the setup the Target needs before its first factory run.
_Avoid_: Copy, deploy

**Target**:
An existing directory that receives the Template.
_Avoid_: Destination, repo

**Additive copy**:
A copy that only adds entries to the Target and never changes or removes an entry that is already there.
_Avoid_: Merge, sync

**Skip**:
A Template file left uncopied because the Target already has an entry at that path. An identical Skip has the same content as the Template file; a different Skip does not.
_Avoid_: Clobber, overwrite

**Conflict**:
A Target entry that cannot act as a directory where the Template has one: a symlink or a file. A Conflict blocks the whole Additive copy.
_Avoid_: Collision, clobber

### Factory

**Job**:
One feature run through the factory loop, from spec to merge or to a human. A Job is recorded as one Issue.
_Avoid_: Task, run

**Issue**:
The GitHub issue that is a Job's record: its Queue entry, its state and its Artifacts.
_Avoid_: Ticket, job folder

**Queue**:
The open Issues labeled `factory` that no session has started.
_Avoid_: Backlog

**Claim**:
A session's comment that takes an Issue from the Queue. The earliest Claim wins.
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
