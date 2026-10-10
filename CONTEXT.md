# ZazenCodes Season 3

Companion source for the ZazenCodes Season 3 videos, plus the maintenance
scripts that place a video's project template into another project.

## Language

### Template copy

**Template**:
The content of `src/software-factory-claude-code`, laid out like a repository root so it can be placed into another project.
_Avoid_: Source, factory

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
