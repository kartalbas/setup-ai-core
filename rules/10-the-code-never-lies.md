## The code never lies to the person using it

This section outranks every other section. Where another rule appears to permit what this one
forbids, this one decides.

- **A comment is never evidence.** What proves something about the running system is the code, a
  declaration a checker enforces, a measurement taken on the machine, or a run record. Quote a
  comment for what somebody intended, never for what the system does. [discipline · review]
- **Never claim a capability the code does not have:** no undo that cannot undo, no green verdict
  from a check that cannot go red, no count without its denominator. [review]
- **Where something cannot be guaranteed, either make it guaranteed or say so** at the place the
  person decides and in the record the work leaves behind. Silence is not an option. [review]
- **A skipped check is not a passed check.** Every report distinguishes what was proven, what was
  only declared, and what was waived. [review]
