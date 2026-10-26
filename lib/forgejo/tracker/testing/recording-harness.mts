import type { HarnessSteps, StepOutcome } from '../commands/command.mts';

// The harness steps of a command under test: each call is recorded, and a step named in `failing` fails.
export interface RecordingHarness extends HarnessSteps {
  readonly calls: string[];
  readonly failing: Set<keyof HarnessSteps>;
}

export function createRecordingHarness(): RecordingHarness {
  const calls: string[] = [];
  const failing = new Set<keyof HarnessSteps>();
  const step = (name: keyof HarnessSteps, said: string) => (path: string): Promise<StepOutcome> => {
    calls.push(`${name} ${path}`);
    return Promise.resolve(failing.has(name) ? { succeeded: false, output: `planted: ${name} failed` } : { succeeded: true, output: said });
  };
  return {
    calls,
    failing,
    checkTeamModes: step('checkTeamModes', ''),
    assembleWorktree: step('assembleWorktree', 'init: assembled'),
    refreshCheckout: step('refreshCheckout', 'refreshed: the checkout'),
    readLiveTags: step('readLiveTags', ''),
    readLiveRelease: (checkout, repository, environment) => step('readLiveRelease', '{"delivered":null}')(`${checkout} ${repository} ${environment}`),
    openLandingCheck: (cwd) => step('openLandingCheck', '/planted/receipt')(cwd),
    completeLandingCheck: (receipt, commit, ciRef) => step('completeLandingCheck', '')(`${receipt} ${commit} ${ciRef}`),
    closeLandingCheck: (receipt) => step('closeLandingCheck', '')(receipt),
    installTools: (path) => step('installTools', 'installed')(path),
    readTokensPage: (cwd, itemsFile, columnsFile, board) => step('readTokensPage', 'the page')(`${cwd} ${itemsFile} ${columnsFile} ${board}`),
  };
}
