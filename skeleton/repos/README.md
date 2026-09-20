One folder per repository of the project, named like the repository, in the layout of its
checkout. `repos/<repo>/AGENTS.md` is that repository's map; any other file here, such as
`.claude/settings.json` or `.ai-core/config.env`, is copied over the checkout the same way and
wins over everything the generic templates and this harness's own files put there.
