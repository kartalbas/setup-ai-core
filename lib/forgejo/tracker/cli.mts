import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { ForgejoClient, ForgejoError, PartialCompletionError } from './api/client.mts';
import type { TokenSource } from './api/client.mts';
import { createTokenSource } from './api/credentials.mts';
import type { Command, CommandContext, CommandResult } from './commands/command.mts';
import { ConfigError, readSettings, requireConfig } from './config.mts';
import { PreconditionError, UsageError } from './domain/refusals.mts';
import { GitClient, GitError } from './git/git.mts';

const EXIT_PRECONDITION = 1;
const EXIT_INVALID = 2;
const EXIT_EXTERNAL = 3;
const EXIT_PARTIAL = 4;

const COMMANDS: readonly Command[] = [];

const NO_BOARD = 'Forgejo has no board and no epics';
export const REFUSED_ON_FORGEJO: Readonly<Record<string, string>> = {
  'board-list': NO_BOARD,
  'board-order': NO_BOARD,
  'board-sync': NO_BOARD,
  'board-unarchive': NO_BOARD,
  'field-option-add': NO_BOARD,
  'item-move': NO_BOARD,
  'item-top': NO_BOARD,
  'project-new': NO_BOARD,
  'repo-boards': NO_BOARD,
  'repo-link': NO_BOARD,
  'view-filter': NO_BOARD,
  'epics-top': NO_BOARD,
  'subissue-add': NO_BOARD,
  'subissue-remove': NO_BOARD,
  'status-sync': 'a card is moved when the work happens, and issue-proof closes the issue; nothing is reconstructed afterwards',
  'issue-transfer': 'an issue stays in its repository on Forgejo',
  'issue-duplicate': 'close the duplicate with issue-close --reason not-planned and say in a comment which issue it repeats',
  'issue-map': 'it reads boards, which Forgejo does not have',
  'incident-count': 'it finds repositories through boards, which Forgejo does not have',
};

export interface Io {
  readonly argv: readonly string[];
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly cwd: string;
  readonly stdout: (text: string) => void;
  readonly stderr: (text: string) => void;
}

function version(): string {
  return readFileSync(new URL('../../../VERSION', import.meta.url), 'utf8').trim();
}

function topLevelHelp(): string {
  return ['usage: cli.mts COMMAND [ARGUMENTS]', '', 'Every command takes --help. The commands of the Forgejo tracker:', ...COMMANDS.map((command) => `  ${command.name}`), ''].join('\n');
}

function exitCodeOf(error: unknown): number {
  if (error instanceof PartialCompletionError) return EXIT_PARTIAL;
  if (error instanceof ForgejoError) return error.kind === 'configuration' ? EXIT_INVALID : EXIT_EXTERNAL;
  if (error instanceof UsageError || error instanceof ConfigError) return EXIT_INVALID;
  if (error instanceof PreconditionError) return EXIT_PRECONDITION;
  return EXIT_EXTERNAL;
}

function isKnownFailure(error: unknown): boolean {
  return (
    error instanceof ForgejoError ||
    error instanceof UsageError ||
    error instanceof PreconditionError ||
    error instanceof ConfigError ||
    error instanceof GitError
  );
}

export async function main(io: Io): Promise<number> {
  const [name, ...args] = io.argv;
  if (name === '--version') {
    io.stdout(`ai-core forgejo tracker ${version()}\n`);
    return 0;
  }
  if (name === undefined || name === 'help' || name === '--help' || name === '-h') {
    io.stdout(topLevelHelp());
    return 0;
  }
  const refusal = REFUSED_ON_FORGEJO[name];
  if (refusal !== undefined) {
    io.stderr(`error: ${name} is not available with TRACKER=forgejo: ${refusal}\n`);
    return EXIT_INVALID;
  }
  const command = COMMANDS.find((candidate) => candidate.name === name);
  if (command === undefined) {
    io.stderr(`error: unknown command '${name}'\n`);
    return EXIT_INVALID;
  }
  if (args[0] === '--help' || args[0] === '-h') {
    io.stdout(`${command.help}\n`);
    return 0;
  }

  const settings = readSettings(io.env);
  let tokens: TokenSource | undefined;
  let client: ForgejoClient | undefined;
  const context: CommandContext = {
    cwd: io.cwd,
    git: new GitClient(),
    settings,
    now: () => new Date(),
    api: () => {
      if (client === undefined) {
        const config = requireConfig(settings);
        tokens = createTokenSource(config.tokenCommand);
        client = new ForgejoClient({ baseUrl: config.forgejoUrl, token: tokens });
      }
      return client;
    },
  };

  let result: CommandResult;
  try {
    result = await command.run(args, context);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const shown = tokens === undefined ? message : tokens.redact(message);
    io.stderr(isKnownFailure(error) ? `error: ${shown}\n` : `error: unexpected failure: ${shown}\n`);
    return exitCodeOf(error);
  }
  io.stdout(result.stdout);
  io.stderr(result.stderr);
  return result.exitCode;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exitCode = await main({
    argv: process.argv.slice(2),
    env: process.env,
    cwd: process.cwd(),
    stdout: (text) => {
      process.stdout.write(text);
    },
    stderr: (text) => {
      process.stderr.write(text);
    },
  });
}
