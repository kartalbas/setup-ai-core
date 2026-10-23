import type { ForgejoClient } from '../api/client.mts';
import type { GitClient } from '../git/git.mts';

// What cli.mts hands to a command. The Forgejo client is built on first use, so a command that
// needs no server (help, a refused argument) needs no settings and no token.
export interface CommandContext {
  readonly cwd: string;
  readonly api: () => ForgejoClient;
  readonly git: GitClient;
  readonly settings: {
    readonly forgejoUrl: string | undefined;
    readonly tokenCommand: string | undefined;
    readonly labelsFile: string | undefined;
  };
  readonly now: () => Date;
}

// A command returns its result; only cli.mts prints and exits.
export interface CommandResult {
  readonly stdout: string;
  readonly stderr: string;
  readonly exitCode: number;
}

export interface Command {
  readonly name: string;
  readonly help: string;
  readonly run: (args: readonly string[], context: CommandContext) => Promise<CommandResult>;
}

export function lines(...text: readonly string[]): string {
  return text.length === 0 ? '' : `${text.join('\n')}\n`;
}

export function succeeded(stdout: readonly string[] = [], stderr: readonly string[] = []): CommandResult {
  return { stdout: lines(...stdout), stderr: lines(...stderr), exitCode: 0 };
}

// YYYY-MM-DD in the time zone of the process, as `date +%Y-%m-%d` writes it.
export function isoDate(moment: Date): string {
  const two = (value: number): string => String(value).padStart(2, '0');
  return `${moment.getFullYear()}-${two(moment.getMonth() + 1)}-${two(moment.getDate())}`;
}
