// The settings bin/ai-core hands over in the environment. The token is not among them: it is read
// by running FORGEJO_TOKEN_COMMAND when the first request needs it.

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

export interface Settings {
  readonly tracker: string | undefined;
  readonly forgejoUrl: string | undefined;
  readonly tokenCommand: string | undefined;
  readonly labelsFile: string | undefined;
  readonly ciGate: string | undefined;
  readonly liveTags: string | undefined;
  readonly integratePollSeconds: string | undefined;
  readonly integrateWaitSeconds: string | undefined;
}

export interface Config {
  readonly forgejoUrl: string;
  readonly tokenCommand: string;
}

export function readSettings(env: Readonly<Record<string, string | undefined>>): Settings {
  const value = (name: string): string | undefined => {
    const found = env[name];
    return found === undefined || found.trim() === '' ? undefined : found;
  };
  return {
    tracker: value('TRACKER'),
    forgejoUrl: value('FORGEJO_URL'),
    tokenCommand: value('FORGEJO_TOKEN_COMMAND'),
    labelsFile: value('AI_CORE_LABELS_FILE'),
    ciGate: value('CI_GATE'),
    liveTags: value('LIVE_TAGS'),
    integratePollSeconds: value('AI_CORE_INTEGRATE_POLL'),
    integrateWaitSeconds: value('AI_CORE_INTEGRATE_WAIT'),
  };
}

// Scheme and host, no credentials, no path: the API path is the client's.
export function parseForgejoUrl(text: string): string {
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    throw new ConfigError(`FORGEJO_URL is not an address: it must be a scheme and a host, such as https://forge.example.test`);
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new ConfigError('FORGEJO_URL must start with https:// or http://');
  if (url.username !== '' || url.password !== '') throw new ConfigError('FORGEJO_URL must not carry credentials');
  if ((url.pathname !== '/' && url.pathname !== '') || url.search !== '' || url.hash !== '') throw new ConfigError('FORGEJO_URL must be a scheme and a host and nothing after it');
  return url.origin;
}

export function requireConfig(settings: Settings): Config {
  if (settings.tracker?.toLowerCase() !== 'forgejo') {
    throw new ConfigError(`TRACKER is '${settings.tracker ?? 'not set'}': the Forgejo tracker runs only with TRACKER=forgejo`);
  }
  if (settings.forgejoUrl === undefined) throw new ConfigError('FORGEJO_URL is not set');
  if (settings.tokenCommand === undefined) throw new ConfigError('FORGEJO_TOKEN_COMMAND is not set');
  return { forgejoUrl: parseForgejoUrl(settings.forgejoUrl), tokenCommand: settings.tokenCommand };
}
