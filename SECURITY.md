# Security notes

zmcp servers are meant to be driven by an AI model, so treat every tool
argument as untrusted input. This file lists what is enforced and what is not.

## Enforced defaults

- **Code execution is opt-in:** `zmcp-tickets` `verify_run`
  (`ZMCP_TICKETS_ALLOW_EXEC=1`), `zmcp-zig-docs` `zig_build` / `zig_test_file`
  (`ZMCP_ZIG_DOCS_ALLOW_RUN=1`), `zmcp-blender` (`ZMCP_BLENDER_ALLOW_EXEC=1`),
  `zmcp-godot` (`ZMCP_GODOT_ALLOW_RUN=1`).
- **Writes are opt-in** for git-hosting, database, cluster and cloud servers via
  `ZMCP_<NAME>_ALLOW_WRITE=1` (see each server's row in the README).
- **Network:** `zmcp-fetch` and `zmcp-rss` block loopback, private and
  link-local hosts and re-check every redirect. API keys are never re-sent on a
  redirect (`web_search`, `context7`).
- **Files:** `zmcp-fs`, `zmcp-markdown-render`, `zmcp-diff-render` and `zmcp-pdf`
  are confined to the working directory or a configured root.
- **Secrets in output:** `zmcp-llm`, `zmcp-aws`, `zmcp-kubernetes` and
  `zmcp-docker` redact secrets they know how to recognise. AWS calls that would
  put a secret in the process argument list are refused.
- **Gateway:** children receive only the environment their server needs, not the
  operator's whole keyring.
- **HTTP hosting:** a set-but-empty `ZMCP_HTTP_TOKEN` or a tokenless remote bind
  refuses to start.
- `ZMCP_NO_DESTRUCTIVE=1` enforces the per-tool `destructive` flag as policy.

## Known gaps

- Not every server has a write gate; the README says which do.
- `destructive` enforcement is opt-in (`ZMCP_NO_DESTRUCTIVE`), not default.
- `zmcp-fetch`, `zmcp-rss` and `zmcp-browser` do not detect DNS rebinding.
- Path confinement is lexical or realpath-based per server; `zmcp-fs` does not
  resolve symlinks. `diff_git_show` does not confine its `repo` argument.
- Redaction is name- and pattern-based. Secrets under innocuous names or in
  free-form text can still get through in kubernetes, docker and aws output.
- Secret-named flags nested inside JSON parameter values are not inspected by
  the AWS argument policy.
- `zmcp-browser` `browser_evaluate` runs page JavaScript and is on by default
  (`ZMCP_BROWSER_NO_EVAL=1` disables it).
- The gateway's per-server environment table is built from what each server
  reads; add anything missing with `ZMCP_GATEWAY_PASS_ENV`.

## Reporting

Please report vulnerabilities privately through the repository's GitHub
security advisories rather than a public issue.
