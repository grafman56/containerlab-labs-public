# Break Tests

This directory contains fault-injection material for disposable learning exercises.
It is separate from each lab's normal topology, configuration, validation, and
verification paths.

## Rules

- Keep normal lab sources in a known-good state.
- Put each exercise under `break-tests/<lab>/<scenario-id>/`.
- Give the learner a symptom-based ticket only after a scoped deployment proves
  the intended fault is live.
- Do not place fault configuration in a lab's `configs/` directory or normal
  `verify.sh` script.
- Keep the cause, affected node, and restoration method out of the learner
  ticket.
- Record the baseline revision, deployed scenario revision, live verification,
  and restoration verification in the scenario runbook.

## Deployment model

A future fixed Semaphore break-test template must stage the selected scenario
in an isolated worktree, deploy only its named topology, and run the scenario's
live checks. It must then restore the normal lab source and redeploy it after
the exercise. The normal lab Deploy templates must always use the known-good
source.

Do not run break-test files through an ordinary lab verification command. A
scenario needs its own launch, live verification, and restoration procedure.
