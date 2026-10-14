# warden

Claude Code plugin that connects your agent to a **Vaultwarden** or **Bitwarden** vault, using
your own account, with guardrails that keep secrets out of transcripts and logs.

- **Reads** via [rbw](https://github.com/doy/rbw): search, read one exact entry, TOTP, add, generate.
- **Attachments** via the official `bw` CLI.
- **Org admin** (optional): invite, change access and remove members with the bundled
  `vw-members.sh` (the part `bw` cannot do), plus `bw confirm`.

Guardrails: never dump the vault, resolve the exact entry before reading it, show passwords
only when asked, keep secrets off argv, never handle the master password, one attempt per
operation. Every read lands in the server event log under your identity.

## Install

```bash
claude plugin marketplace add rodrigopg/warden-plugin
claude plugin install warden@warden-plugin
```

Then, once per machine, in your own terminal:

```bash
rbw config set base_url https://<your-vault-server>   # omit for bitwarden.com
rbw config set email <your-email>
rbw login
```

Ask Claude something like *"what is the login for the staging database?"*.

## License

MIT
