One folder per repository of the project, named like the repository, in the layout of its
checkout. `repos/<repo>/AGENTS.md` is that repository's map; any other file here, such as
`.claude/settings.json`, is copied over the checkout the same way, whole, and wins over everything
the generic templates and this harness's own files put there. `.ai-core/config.env` is the one file
laid over key by key: list only the keys that repository changes, and every other key of this
harness's `config.env` stays.
