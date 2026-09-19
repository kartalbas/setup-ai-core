## The harness in a repository

- **Every automation script exists in two spellings**, `.sh` for Bash 3.2+ and `.ps1` for PowerShell
  7+, with the same options, the same output and the same exit codes. [review]
- **Nothing the harness deploys is tracked by the repository.** It lives in the working tree,
  registered in the clone's own exclude file, and is assembled by the harness from its layers.
  [tool]
- **Managed files are never edited in a checkout.** A rule, a skill or a script changes in the layer
  it came from, and the change reaches every checkout through the harness. [discipline]
