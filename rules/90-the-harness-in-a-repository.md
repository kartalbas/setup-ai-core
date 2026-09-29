## The harness in a repository

- **Every automation script exists in two spellings**, `.sh` for Bash 3.2+ and `.ps1` for PowerShell
  7+, with the same options, the same output and the same exit codes. [review]
- **Nothing the harness deploys is tracked by the repository.** It lives in the working tree,
  registered in the clone's own exclude file, and is assembled by the harness from its layers.
  [tool]
- **Managed files are never edited in a checkout, and a fault of the harness is reported, not fixed
  or worked around there.** A rule, a skill or a script changes in the layer it came from, and the
  change reaches every checkout through the harness. When a hook, a command or a managed file of the
  harness gets in the way, the agent neither edits it nor bypasses it (no `--no-verify`, no changed
  shim or `.ai-core/` file): it opens an issue in the repository of that layer (`ai-core --help`
  names the clone ai-core runs from; its origin is that repository), or tells the session that works
  on the harness where one runs on the same machine, and goes on with its own work. [discipline]
