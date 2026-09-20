One file per section, named `NN-slug.md`: two digits order the sections and leave room between
the generic ones (`00`, `10`, ... `90` in setup-ai-core). A file with the same name as a generic
section replaces that section; a new name adds one, at the place its number says. Every rule ends
with its enforcement tag, `[machine]`, `[tool]`, `[review]` or `[discipline]`, or a combination such
as `[machine · review]`; `ai-core rules-check rules` refuses one without.
