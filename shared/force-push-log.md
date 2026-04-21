# Force-Push Log (FW-007)

Every legitimate `--force` / `--force-with-lease` push or ref-deletion
against `master` must be announced here BEFORE the push. The pre-push
hook at `cabinet/scripts/git-hooks/pre-push` refuses the push without
a matching entry.

## Why

`master` in this repo is shared across all officers. A force-push or
reset that rewrites history destroys other officers' unpushed work.
On 2026-04-17, a `git reset --hard origin/master` wiped 4 commits
from another officer in the shared tree. This log + hook combo is
the gate; see `feedback_git_staging_shared_tree.md` for the
narrow-staging vigilance half.

## Protocol

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$TS  <your-role>  <why the rewrite is necessary>" >> shared/force-push-log.md
FORCE_PUSH_ANNOUNCED=$TS git push --force-with-lease origin master
```

Requirements enforced by the hook:
- `FORCE_PUSH_ANNOUNCED` env var set to a well-formed ISO UTC timestamp.
- Timestamp within 5 minutes of the push.
- Exact timestamp string present in this file.
- Prefer `--force-with-lease` over `--force` to catch concurrent pushes.

Coordination note: before pushing, `git fetch && git log origin/master..HEAD`
on every active officer's tree to confirm no unpushed work exists.

---

## Entries

<!-- Append entries below. Format: TIMESTAMP  ROLE  REASON -->
