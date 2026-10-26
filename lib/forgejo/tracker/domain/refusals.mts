// The two refusals a person can cause, and the failures of Forgejo that a command tells apart.
// cli.mts maps them to exit codes; commands/ reaches the failures of api/ through this file.
export { AuthenticationError, ContractError, CredentialsError, ForgejoError, PartialCompletionError, PermissionError, TransportError } from '../api/client.mts';

// The arguments or the settings are wrong, and no call to Forgejo could make them right.
export class UsageError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'UsageError';
  }
}

// The call is well formed and the state of the tracker forbids it.
export class PreconditionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PreconditionError';
  }
}
