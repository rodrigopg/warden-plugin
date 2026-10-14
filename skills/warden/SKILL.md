---
name: warden
description: "Use this skill when the user asks for a password, login, credential, secret, token or API key stored in their Vaultwarden/Bitwarden vault, or wants to add/update one, or (as an org admin) to invite/remove members or change collection access. Reads via rbw; admin via bw + the bundled vw-members.sh."
tags:
  - credentials
  - security
  - vaultwarden
  - bitwarden
  - rbw
---

# Warden: Vaultwarden/Bitwarden in the agent harness

Gives the agent audited, least-privilege access to a Vaultwarden (or Bitwarden) vault through
the user's own account. Works with any server: self-hosted Vaultwarden, bitwarden.com or
bitwarden.eu.

Every read appears in the server's event log under the user's identity, exactly like a manual
read. There is no separate agent identity; that is by design.

---

## Guardrails (never violate)

- **Never dump the vault.** `rbw list` (names only) is fine. Never loop `rbw get` over every
  entry: it defeats the audit trail and floods the event log.
- **Resolve first, then read ONE entry.** Find the exact name or UUID with `rbw search` /
  `rbw list`, then `rbw get` that exact entry. Never guess names.
- **Show passwords only when the user asks for the value.** Otherwise answer with name,
  username and URL. Prefer `--field <field>` over `--full` (which prints the password).
- **Secrets never go on argv, in `echo`, or in logs.** Pipe with `printf '%s\n'` when needed.
  Command lines are readable by other users on shared machines.
- **Never ask for the master password and never pipe it.** Unlocking is the user's job in
  their own terminal.
- **One attempt per operation.** On failure, report the exact error and stop: no retries with
  guessed flags. Unsure of syntax: `rbw help <subcommand>` first.
- **Ambiguous match = stop.** If rbw reports `multiple entries found`, resolve the UUID
  (below); never pick the first match.
- **Suggest `rbw lock`** at the end of a session that unlocked the vault.

---

## Setup (once per machine)

Install [rbw](https://github.com/doy/rbw) (Debian/Ubuntu: `apt install rbw`; macOS:
`brew install rbw`; otherwise `cargo install rbw`), then **the user** runs, in a real
terminal:

```bash
rbw config set base_url https://<your-vault-server>   # omit for bitwarden.com
rbw config set email <your-email>
rbw register   # only if the server requires device registration (bitwarden.com)
rbw login
```

Headless machines: pick a pinentry that exists (`command -v pinentry-curses pinentry-tty`)
and set it with `rbw config set pinentry <binary>`. Without a TTY, `rbw login`/`unlock`
fails with `failed to parse pinentry output`; that is expected, not a misconfiguration.

The rbw agent keeps the vault unlocked in the background (like `ssh-agent`), so the agent
can read without prompting until it locks. If it is locked and there is no TTY, tell the user
to run `rbw unlock` and stop.

## Reading

```bash
rbw unlocked && rbw sync                    # is it unlocked? refresh the local copy
rbw search "<term>"                         # matching entry names
rbw list --fields name,user,folder          # overview, no secrets
rbw get --field username "<exact-name>"
rbw get --field uris "<exact-name>"
rbw get "<exact-name>"                      # the password: only when asked
rbw get --full "<exact-name>"               # password + notes: only when asked
rbw code "<exact-name>"                     # current TOTP code
```

Duplicate names are common (browser imports, KeePass migrations):

```bash
rbw list --fields id,name,user,folder | grep -i "<term>"
rbw get <uuid> --field username
```

## Writing

```bash
rbw generate 24 "<name>" <username> --uri https://<site>   # new entry; prints the password: do not repeat it
rbw add "<name>" <username> --uri https://<site>           # opens $EDITOR for the password
rbw edit "<exact-name>"                                    # opens $EDITOR
```

`add`/`edit` need an interactive editor: from a non-interactive agent prefer `generate`, or
hand the command to the user. Check `rbw help <subcommand>` before relying on any flag.

## Attachments (rbw cannot)

rbw has no attachment support. Use the official CLI (`npm i -g @bitwarden/cli`):

```bash
bw get item <item-id> | jq -r '.attachments[] | "\(.id) \(.fileName)"'
bw get attachment <attachment-id> --itemid <item-id> --output ./<file>
```

Downloaded files are plaintext on disk: delete (`shred -u`) when done.

## Organization admin (optional)

Needs an org owner/admin account and `bw`. `vw-members.sh` is **Vaultwarden / self-hosted
only**: the Bitwarden cloud splits identity and API onto separate hosts (use its Public API).

```bash
bw config server https://<your-vault-server>
bw login                                    # the user, in their terminal
umask 077; bw unlock --raw > ~/.bw-session  # the user; the agent then exports BW_SESSION from it
```

Use `export BW_SESSION=$(cat ~/.bw-session)`, never `--session <key>` (argv). At the end:
`bw lock` and `shred -u ~/.bw-session`.

`bw` cannot invite, update or remove members; the bundled `scripts/vw-members.sh` does,
through the server API using the refresh token `bw login` stored (no master password):

```bash
S=${CLAUDE_PLUGIN_ROOT}/skills/warden/scripts/vw-members.sh
bw list organizations | jq -r '.[] | "\(.id) \(.name)"'
bw list collections --organizationid <org-id> | jq -r '.[] | "\(.id) \(.name)"'
$S list   <org-id>                                         # status 0 invited, 1 accepted, 2 confirmed
$S invite <org-id> <email> user <collection-id>[:ro] ...
bw confirm org-member <member-id> --organizationid <org-id>   # after the person signed up
$S access <org-id> <member-id> user <collection-id>[:ro] ...  # replaces the whole list
$S remove <org-id> <member-id>
```

Onboarding: invite, the person signs up with **that exact email** (emailed link if the server
has SMTP), then confirm (confirming before signup fails: no public key yet). Offboarding:
remove, then rotate every secret in the collections they could read. Granting access to
sensitive collections or changing roles needs the user's explicit OK each time.

## Errors

| Situation | Action |
|-----------|--------|
| `rbw: command not found` | Install (see Setup) and tell the user which method you used |
| Locked, no TTY | Ask the user to run `rbw unlock`; stop |
| Entry not found | Check `rbw config show` (`base_url`, `email`) and `rbw sync`; never switch servers yourself |
| `multiple entries found` | Resolve by UUID (Reading) |
| 2FA prompt | Surface it to the user |
| `bw sync` → `invalid_grant` | The login expired: user runs `bw logout` then `bw login` |
| `vw-members.sh` 401/403 | Not an org admin, or the login expired: user runs `bw login` |
| Anything else | Report the exact error and stop |
