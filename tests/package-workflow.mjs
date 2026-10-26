// The coordinator's command that labels a package, as skills/person-in-charge/SKILL.md writes it, with its
// placeholders filled in. The tests of issue-package run what this prints, so a change of the skill's command, or
// of the command it names, turns them red. Usage:
//
//   node tests/package-workflow.mjs SKILL.md OWNER/REPO#NUMBER [--member OWNER/REPO#NUMBER]... [--remove OWNER/REPO#NUMBER]...
import fs from 'node:fs';

const quoted = (text) => `'${text}'`;

export function workflowCommand(skillText, { anchor, members, removals }) {
  const lines = skillText.split('\n');
  const start = lines.findIndex((line) => /^ {4}ai-core issue-package /.test(line));
  if (start < 0) throw new Error('the skill holds no command line that starts with "ai-core issue-package"');
  const parts = [];
  for (let index = start; index < lines.length; index++) {
    const line = lines[index].trim();
    if (!line.endsWith('\\')) {
      parts.push(line);
      break;
    }
    parts.push(line.slice(0, -1).trim());
  }
  const [repository, number] = anchor.split('#');
  const command = parts
    .join(' ')
    .replace('<first issue OWNER/REPO>', quoted(repository))
    .replace('<first issue number>', number)
    .replace(/--member <OWNER\/REPO#NUMBER>( \.\.\.)?/, members.map((member) => `--member ${quoted(member)}`).join(' '))
    .replace(/\[--remove <OWNER\/REPO#NUMBER>( \.\.\.)?\]/, removals.map((removal) => `--remove ${quoted(removal)}`).join(' '));
  if (/[<>[\]]|\.\.\./.test(command)) throw new Error(`a placeholder is left in the skill's command: ${command}`);
  return command.replace(/\s+/g, ' ').trim();
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const [skill, anchor, ...rest] = process.argv.slice(2);
  const members = [];
  const removals = [];
  for (let index = 0; index < rest.length; index += 2) (rest[index] === '--member' ? members : removals).push(rest[index + 1]);
  console.log(workflowCommand(fs.readFileSync(skill, 'utf8'), { anchor, members, removals }));
}
