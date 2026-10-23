import { currentLogin } from '../domain/issues.mts';
import { AuthenticationError, CredentialsError, ForgejoError, PermissionError, TransportError } from '../domain/refusals.mts';
import { lines } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

export const help = `usage: doctor

Prints the Forgejo lines of the doctor, each "ok: ..." or "problem: ...", and exits 1 when there is a problem.
It tells three things apart: not configured (FORGEJO_URL or FORGEJO_TOKEN_COMMAND is missing), not authorized
(the token command fails, Forgejo refuses the token, or the token lacks the read:user scope) and healthy.`;

export async function run(_args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const { forgejoUrl, tokenCommand } = context.settings;
  const missing = [forgejoUrl === undefined ? 'FORGEJO_URL' : '', tokenCommand === undefined ? 'FORGEJO_TOKEN_COMMAND' : ''].filter((name) => name !== '');
  if (missing.length > 0) return { stdout: lines(`problem: the Forgejo tracker is not configured: ${missing.join(' and ')} ${missing.length === 1 ? 'is' : 'are'} not set`), stderr: '', exitCode: 1 };
  try {
    const login = await currentLogin(context.api());
    return { stdout: lines(`ok: Forgejo at ${forgejoUrl ?? ''} knows the token as ${login}`), stderr: '', exitCode: 0 };
  } catch (error) {
    let line: string;
    if (error instanceof CredentialsError) line = `problem: not authorized: ${error.message}`;
    else if (error instanceof AuthenticationError) line = 'problem: not authorized: Forgejo does not accept the token';
    else if (error instanceof PermissionError) line = 'problem: not authorized: the token cannot read its own user; it needs the scope read:user';
    else if (error instanceof TransportError) line = `problem: Forgejo cannot be reached: ${error.message}`;
    else if (error instanceof ForgejoError) line = `problem: ${error.message}`;
    else throw error;
    return { stdout: lines(line), stderr: '', exitCode: 1 };
  }
}
