import { readFile } from 'node:fs/promises';
import { applySync, builtInLabels, listOrganizationLabels, parseCatalog, planSync } from '../domain/labels.mts';
import { refuseEmailAddress } from '../domain/public-text.mts';
import { UsageError } from '../domain/refusals.mts';
import { parseArguments, refuseExtra, requireValue } from './arguments.mts';
import { lines } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: labels-sync --org ORG [--check]';
export const help = `${USAGE}

Creates and updates the labels of an organization from labels.tsv and from the status/ and priority/ constants of
the tracker, and deletes none. A label of a family is written group/name where labels.tsv has group:name; the
families status/, priority/, type/, goal/ and test/ are exclusive, area/ is not. The whole file is read before
anything is written, so a bad row writes nothing, and a catalog that already matches writes nothing. --check
writes nothing and exits 1 when the organization differs.`;

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--org': 'value', '--check': 'switch' });
  refuseExtra(parsed.positionals, USAGE);
  const organization = requireValue(parsed, '--org');
  const file = context.settings.labelsFile;
  if (file === undefined) throw new UsageError('labels-sync needs the labels file: run it through ai-core');
  let text: string;
  try {
    text = await readFile(file, 'utf8');
  } catch {
    throw new UsageError(`cannot read the label catalog ${file}`);
  }
  const desired = [...parseCatalog(text, file), ...builtInLabels()];
  refuseEmailAddress('labels-sync', organization, desired.map((label) => `${label.name}\n${label.description}`).join('\n'));

  const api = context.api();
  const plan = planSync(desired, await listOrganizationLabels(api, organization));
  const report = [
    ...plan.create.map((label) => `create ${label.name}`),
    ...plan.update.map((label) => `update ${label.name} (${Object.keys(label.changes).join(', ')})`),
    ...plan.leftAlone.map((name) => `not in the catalog, left alone: ${name}`),
  ];
  const differs = plan.create.length + plan.update.length > 0;
  const summary = `${organization}: ${plan.create.length} to create, ${plan.update.length} to update, ${plan.unchanged} unchanged`;
  if (parsed.switches.has('--check')) return { stdout: lines(...report, summary), stderr: '', exitCode: differs ? 1 : 0 };
  await applySync(api, organization, plan);
  return { stdout: lines(...report, summary), stderr: '', exitCode: 0 };
}
