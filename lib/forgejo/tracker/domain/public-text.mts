import { ForgejoError } from '../api/client.mts';
import type { ForgejoClient } from '../api/client.mts';
import { repositoryShape } from '../api/shapes.mts';
import { formatRepository, repositoryPath } from './issues.mts';
import type { RepositoryRef } from './issues.mts';
import { PreconditionError } from './refusals.mts';

// The public-text protection: text written to a public or unknown destination holds no literal
// email address. Reserved example domains, noreply addresses and a domain without a dot are allowed.
// The scan reads the raw text; an address dressed by Markdown, HTML, invisible or lookalike
// characters may pass.

const BACKTICK = '\\u0060';
const LOCAL_CHARACTER = String.raw`(?:[A-Za-z0-9.!#$%&'*+/=?^_${BACKTICK}{|}~\[\]-]|[^\x00-\x7f])`;
// Beside letters, marks and numbers, a domain takes the ten code points IDNA2008 allows inside a label,
// or the dot of a domain that holds one would go unseen.
const DOMAIN = String.raw`[\p{L}\p{N}][\p{L}\p{N}\p{M}\u00b7\u0375\u05f3\u05f4\u06fd\u06fe\u0f0b\u200c\u200d\u30fb._。．｡-]*`;
const SCHEME_USER = /(?<scheme>[A-Za-z][A-Za-z0-9+.-]*:\/\/)(?:\{\{[^}@\r\n]*\}\}|[^/?#\s@{<>()[\]"'`,;])*@/gu;
const SCP_USER = /(?<![^\s`(\[<"'])[A-Za-z0-9._-]+@(?=[A-Za-z0-9<][A-Za-z0-9.<>_-]*:[^\s:]*(?:\/|\.git\b))/gu;
const RESERVED_DOMAIN = /(^|\.)(invalid|example|test|localhost|example\.(com|net|org))$/;

function addressPattern(quoted: string, bracketed: string): RegExp {
  return new RegExp(`(?:${quoted}|${LOCAL_CHARACTER}+)@(?:${bracketed}|${DOMAIN})`, 'gu');
}

// The first literal email address in the text that the protection refuses, if any.
export function findEmailAddress(text: string): string | undefined {
  const cleaned = text.replace(SCHEME_USER, '$<scheme>').replace(SCP_USER, '');
  const patterns = [addressPattern(String.raw`"[^"\r\n]+"`, String.raw`\[[^\]\r\n]+\]`), addressPattern(String.raw`"[^"@\r\n]+"`, String.raw`\[[^\]@\r\n]+\]`)];
  for (const pattern of patterns) {
    for (const match of cleaned.matchAll(pattern)) {
      const address = match[0];
      const domain = (address.split('@').pop() ?? '')
        .replace(/[。．｡]/g, '.')
        .toLowerCase()
        .replace(/\.+$/, '');
      if (!/[\p{L}]|^\[/u.test(domain)) continue;
      if (!/\.|^\[/.test(domain)) continue;
      if (RESERVED_DOMAIN.test(domain) || domain === 'users.noreply.github.com') continue;
      return address;
    }
  }
  return undefined;
}

// A destination is private only when Forgejo says so. A repository whose visibility cannot be read
// is treated as public, so the scan runs.
async function isPrivateRepository(api: ForgejoClient, repository: RepositoryRef): Promise<boolean> {
  try {
    const found = await api.call({ name: `read the visibility of ${formatRepository(repository)}`, method: 'GET', path: repositoryPath(repository), success: 200, read: repositoryShape.type.read });
    return found.private;
  } catch (error) {
    if (error instanceof ForgejoError) return false;
    throw error;
  }
}

export function refuseEmailAddress(command: string, destination: string, text: string): void {
  const address = findEmailAddress(text);
  if (address !== undefined) throw new PreconditionError(`${command}: refused email address ${address} in a public or unknown tracker destination (${destination})`);
}

export async function checkPublicText(api: ForgejoClient, command: string, repository: RepositoryRef, text: string): Promise<void> {
  if (await isPrivateRepository(api, repository)) return;
  refuseEmailAddress(command, formatRepository(repository), text);
}
