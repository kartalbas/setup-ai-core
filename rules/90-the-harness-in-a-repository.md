## The harness in a repository

- **Every automation script exists in two spellings**, `.sh` for Bash 3.2+ and `.ps1` for PowerShell
  7+, with the same options, the same output and the same exit codes, because Windows runs the
  `.ps1` and Linux the `.sh`, and a change in one spelling alone makes them two programs.
  [machine · review]
- **Nothing the harness deploys is tracked by the repository.** It lives in the working tree,
  registered in the clone's own exclude file, and is assembled by the harness from its layers.
  [tool]
- **Managed files are never edited in a checkout, and a fault of the harness is reported, not fixed
  or worked around there.** A rule, a skill or a script changes in the layer it came from, and the
  change reaches every checkout through the harness. A fault is a hook, a command or a managed file
  that is wrong, not one that refuses a change for a defect the change has; the second is fixed in
  the change. On a fault the agent neither edits the harness nor bypasses it (no changed shim or
  `.ai-core/` file): it opens an issue in the repository of that layer (`ai-core --help` names the
  clone ai-core runs from; its origin is that repository), naming no private project, organisation
  or machine where that repository is public, or, where it can message the session that works on
  the harness, tells it; it names the fault in its report, goes on with what the fault does not
  block, and reports the rest as blocked. [discipline]
