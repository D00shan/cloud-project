# Destruction guide

Destruction requires the original `.env`, valid
`infrastructure/state/deployment.json`, matching authenticated account/region,
matching deterministic names, and ownership tags. Interactive use requires
typing `<PROJECT_NAME>/<ENVIRONMENT>` exactly:

```bash
./infrastructure/destroy.sh
./infrastructure/destroy.sh --yes '<PROJECT_NAME>/<ENVIRONMENT>'
```

`--yes` is noninteractive confirmation, not a way to supply resource names.
The script cannot target arbitrary names.

Reverse order is: disable/delete event-source mapping; remove notification;
delete function; detach managed and delete inline policies; delete role; delete
queue; abort multipart uploads; empty bucket; delete bucket; remove state.
Versioned objects and delete markers are removed if versioning is enabled;
otherwise normal objects are recursively emptied.

Before each target, absence is distinguished from ambiguous AWS failure.
Confirmed absence is checkpointed atomically. Present resources must still be
owned. `AccessDenied`, expired credentials, network errors, or foreign tags
stop cleanup. After a partial failure, keep state, correct the reported issue,
and rerun; completed steps are safely skipped. State is removed only when all
cleanup succeeds.

Confirm removal using read-only `get-*`, `head-bucket`, and `get-queue-url`
commands with the recorded profile/region. Exact not-found responses are
expected. Never use Console deletion as a shortcut, and verify the original
stack remains unchanged.
