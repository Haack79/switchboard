#136843 is already retargeted and rebased; I didn't have to push anything.

- **Rebase:** at 02:57 UTC another process rebased the branch onto the #136842 merge commit (`8357acc`), probably the stack tooling. Its single commit (`9c461d3`) has the same patch as my local rebase, so I reset my local branch to match it instead of force-pushing over it.
- **PR status:** #136843 now targets `master` and is still approved. CI is running on the new head: 77 checks passed, 12 pending and 0 failed so far.

It isn't queued to merge. Do you want me to watch CI and queue it with `/trunk merge` once it's green?
