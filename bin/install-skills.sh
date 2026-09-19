#!/usr/bin/env bash
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: install-skills.sh"
    echo "Links AI agent community skills from the rules/skills.md definition."
    exit 0
  fi
done

echo "==> Community skills (mattpocock, caveman, ponytail) are defined in .ai-core/rules/skills.md."
echo "==> No npm package installation required."
exit 0
