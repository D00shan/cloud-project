# Portable infrastructure guides

Read these guides in order:

1. [Deployment guide](deployment-guide.md) — prerequisites and the complete
   parallel-stack workflow.
2. [Configuration reference](configuration-reference.md) — every `.env` value
   and the deterministic naming contract.
3. [Architecture](architecture.md) — resources, policies, dependencies, event
   flow, and teardown order.
4. [Validation guide](validation-guide.md) — security checks and end-to-end
   compression proof.
5. [Troubleshooting](troubleshooting.md) — safe diagnostics and recovery.
6. [Destruction guide](destruction-guide.md) — guarded reverse-order cleanup.
7. [Portability rehearsal](portability-rehearsal.md) — evidence checklist for
   two complete disposable deployment cycles.

`./test.sh` is local validation: it uses mocks, never credentials, and proves
script logic. A real AWS rehearsal creates a separate disposable stack and is
the only way to prove account portability. Passing local tests alone must not
be recorded as a successful AWS rehearsal.
