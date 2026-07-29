# Portability rehearsal record

**Status: Not yet executed**

Do not commit credentials, tokens, full sensitive CLI output, or unnecessary
account identifiers. Prefer a partially redacted account ID.

## Environment

- Date:
- Tester:
- AWS account ID (partially redacted):
- Region:
- Project/environment:
- Bucket:
- Queue:
- Lambda:
- IAM role:
- Event-source mapping UUID (redact if evidence is committed):
- Confirmation original stack uses different names:

## Cycle one

- [ ] `./test.sh` passed
- [ ] Preflight passed
- [ ] First deployment passed
- [ ] First `validate.sh` passed all three cases/security/health checks
- [ ] First destruction passed
- [ ] State file absent
- [ ] Bucket, queue, Lambda, role, and mapping confirmed absent

Evidence/notes:

## Cycle two from empty state

- [ ] Preflight passed
- [ ] Second deployment passed
- [ ] Second validation passed
- [ ] Final destruction passed
- [ ] State file absent
- [ ] All temporary resources confirmed absent

Evidence/notes:

## Final safeguards

- [ ] Original stack confirmed unchanged
- [ ] Portable static/account-specific identifier audit passed
- [ ] No `.env`, state, generated JSON, ZIP, dependencies, or credentials committed

Final result: Not yet proven.
