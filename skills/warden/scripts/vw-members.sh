#!/usr/bin/env bash
# Org member management against a Vaultwarden/Bitwarden API — the part `bw` cannot do (it
# has no invite/remove/update for members). Auth reuses the refresh token `bw login` already
# stored, so no master password is needed here; the access token only ever lives in a
# 600 temp file passed to curl as `-H @file`, never on argv (readable by other users).
#
# Usage:
#   vw-members.sh list   <org-id>
#   vw-members.sh invite <org-id> <email> [user|manager|admin] [<collection-id>[:ro] ...]
#   vw-members.sh access <org-id> <member-id> [user|manager|admin] [<collection-id>[:ro] ...]
#   vw-members.sh remove <org-id> <member-id>
#
# Collection ids: `bw list collections --organizationid <org-id>` (needs `bw unlock`).
# After invite + the user's own signup, finish with: bw confirm org-member <member-id> --organizationid <org-id>
# Invites are emailed only if the server has SMTP configured; the user accepts and signs up
# (status 0 -> 1), then you confirm (status 2). Server URL: $VW_URL, else `bw config server`.
set -euo pipefail

BASE="${VW_URL:-$(bw config server)}"
BASE="${BASE%/}"
DATA="${BITWARDENCLI_APPDATA_DIR:-$HOME/.config/Bitwarden CLI}/data.json"
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
[ -f "$DATA" ] || { echo "no bw state at $DATA — run 'bw login' first" >&2; exit 1; }

uid=$(jq -r '.global_account_activeAccountId // empty' "$DATA")
[ -n "$uid" ] || { echo "no active bw account — run 'bw login'" >&2; exit 1; }
rt=$(jq -r --arg k "user_${uid}_token_refreshToken" '.[$k] // empty' "$DATA")
[ -n "$rt" ] || { echo "no refresh token in bw state — run 'bw login'" >&2; exit 1; }

HDR=$(mktemp); chmod 600 "$HDR"; trap 'rm -f "$HDR"' EXIT
at=$(printf 'grant_type=refresh_token&client_id=cli&refresh_token=%s' "$rt" \
    | curl -fsS --data-binary @- "$BASE/identity/connect/token" | jq -r '.access_token // empty') \
    || { echo "token refresh failed — run 'bw logout' + 'bw login'" >&2; exit 1; }
[ -n "$at" ] || { echo "token refresh returned no access token" >&2; exit 1; }
printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$at" > "$HDR"
unset at rt

api() { curl -fsS -H @"$HDR" "$@"; }

role() {
    case "${1:-user}" in
        admin) echo 1 ;; user) echo 2 ;; manager) echo 3 ;;
        *) echo "role must be user|manager|admin" >&2; exit 1 ;;
    esac
}

colls() {  # args: <id>[:ro] ... -> JSON array
    local out='[]' id ro
    for c in "$@"; do
        id="${c%%:*}"; ro=false; [ "$c" != "$id" ] && ro=true
        out=$(jq -c --arg id "$id" --argjson ro "$ro" '. + [{id:$id,readOnly:$ro,hidePasswords:false,manage:false}]' <<<"$out")
    done
    echo "$out"
}

cmd="${1:-}"; org="${2:-}"
[ -n "$cmd" ] && [ -n "$org" ] || { sed -n '7,11p' "$0" >&2; exit 1; }

case "$cmd" in
    list)
        # status: 0 invited, 1 accepted (needs `bw confirm`), 2 confirmed; -1 revoked
        api "$BASE/api/organizations/$org/users?includeCollections=true" \
            | jq -r '.data[] | [.id, .email, (.status|tostring), (.type|tostring), ((.collections // [])|length|tostring)] | @tsv' \
            | { echo -e "member-id\temail\tstatus\ttype\tcollections"; cat; }
        ;;
    invite)
        email="${3:?email required}"; t=$(role "${4:-user}"); shift $(( $# >= 4 ? 4 : 3 ))
        jq -n --arg e "$email" --argjson t "$t" --argjson c "$(colls "$@")" \
            '{emails:[$e],type:$t,accessAll:false,collections:$c,groups:[],permissions:{}}' \
            | api -o /dev/null -d @- "$BASE/api/organizations/$org/users/invite"
        echo "invited $email — next: user signs up, then 'bw confirm org-member <id> --organizationid $org'"
        ;;
    access)
        mid="${3:?member-id required}"; t=$(role "${4:-user}"); shift $(( $# >= 4 ? 4 : 3 ))
        jq -n --argjson t "$t" --argjson c "$(colls "$@")" \
            '{type:$t,accessAll:false,collections:$c,groups:[],permissions:{}}' \
            | api -o /dev/null -X PUT -d @- "$BASE/api/organizations/$org/users/$mid"
        echo "access updated for $mid (collections replaced, not merged)"
        ;;
    remove)
        mid="${3:?member-id required}"
        api -o /dev/null -X DELETE "$BASE/api/organizations/$org/users/$mid"
        echo "removed $mid from $org — rotate any secrets they could read"
        ;;
    *) echo "unknown command: $cmd" >&2; exit 1 ;;
esac
