#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#=== CONFIG ===#
DEFAULT_SSH_CONFIG="$HOME/.ssh/config"
SSH_CONFIG="${SAM_CONFIG:-$DEFAULT_SSH_CONFIG}"
DEFAULT_USER="root"
# shellcheck disable=SC2088  # literal ~ on purpose: written to ssh_config, ssh expands it
DEFAULT_KEY="~/.ssh/id_rsa"
MAX_BACKUPS=10

# Only pass -F for a non-default config: -F makes ssh skip /etc/ssh/ssh_config
SSH_F=()
if [[ "$SSH_CONFIG" != "$DEFAULT_SSH_CONFIG" ]]; then SSH_F=(-F "$SSH_CONFIG"); fi

#=== COLORS ===#
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

#=== HELP ===#
print_help() {
  cat <<EOF
SSH Alias Manager (sam)
Usage:
  sam help
  sam ls                                 List all SSH aliases (with index)
  sam add [options]                      Add SSH alias (prompts for anything missing)
     [ -h HOST/IP ] [ -u USER ] [ -i KEY ] [ -p PORT ] [ -a ALIAS ]
  sam remove <index|alias> | -a ALIAS    Remove SSH alias
  sam edit   <index|alias> | -a ALIAS    Edit SSH alias (interactive)
  sam ssh <index>                        SSH into server by its index in the list

Options also available as: --add, --remove, --edit, --ls, --list, --help
Environment:
  SAM_CONFIG   Path to primary SSH config (default: ~/.ssh/config)
EOF
}

#=== UTIL ===#
die()  { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}$*${NC}" >&2; }

# Temp files are tracked in the parent shell and removed on exit
TMPFILES=()
cleanup() { if (( ${#TMPFILES[@]} )); then rm -f "${TMPFILES[@]}"; fi; }
trap cleanup EXIT
mktmp() { local __f; __f="$(mktemp)"; TMPFILES+=("$__f"); printf -v "$1" '%s' "$__f"; }

expand_tilde() {
  local p="$1"
  if [[ "$p" == "~" ]]; then p="$HOME"; fi
  printf '%s' "${p/#\~\//$HOME/}"
}

# Quote ssh_config values that contain whitespace
cfg_val() {
  if [[ "$1" =~ [[:space:]] ]]; then printf '"%s"' "$1"; else printf '%s' "$1"; fi
}

ensure_config() {
  local dir; dir="$(dirname "$SSH_CONFIG")"
  if [[ ! -d "$dir" ]]; then mkdir -p "$dir"; chmod 700 "$dir"; fi
  if [[ ! -f "$SSH_CONFIG" ]]; then ( umask 077; : > "$SSH_CONFIG" ); fi
}

backup_config() {
  [[ -f "$SSH_CONFIG" ]] || return 0
  cp -p "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%s)"
  # Keep only the newest MAX_BACKUPS (names sort by timestamp)
  local -a baks
  mapfile -t baks < <(compgen -G "${SSH_CONFIG}.bak.*" | sort -r || true)
  if (( ${#baks[@]} > MAX_BACKUPS )); then rm -f -- "${baks[@]:MAX_BACKUPS}"; fi
}

# Overwrite the config IN PLACE (keeps symlinks, owner and permissions intact)
write_config() { cat "$1" > "$SSH_CONFIG"; }

# Shared awk helpers. Handles "Key value", "Key=value", indentation, trailing comments.
AWK_LIB='
function kw(   k){ k=tolower($1); sub(/=.*/,"",k); return k }
function val(   v){
  v=$0; sub(/^[ \t]*[^ \t=]+[ \t]*(=[ \t]*)?/,"",v); sub(/[ \t\r]+$/,"",v)
  if (v ~ /^".*"$/) v=substr(v,2,length(v)-2)
  return v
}
function has_alias(T,   i){
  if (kw()!="host") return 0
  for(i=2;i<=NF;i++){ if ($i ~ /^#/) return 0; if ($i==T) return 1 }
  return 0
}
function is_block_start(   k){ k=kw(); return (k=="host" || k=="match") }
function is_note(){ return ($0 ~ /^[ \t]*(#.*)?[\r]?$/) }
function load(file, arr,   l,n){ n=0; while ((getline l < file) > 0) arr[++n]=l; close(file); return n }
'

# Expand Include directives (recursive, multiple patterns) into a temp file.
# Usage: expand_config <src> <outvar>
expand_config() {
  local __out; mktmp __out
  if [[ -f "$1" ]]; then _expand_into "$1" "$__out" 0; fi
  printf -v "$2" '%s' "$__out"
}

_expand_into() {
  local src="$1" out="$2" depth="$3" line rest pat inc
  local -a pats
  (( depth > 16 )) && return 0   # same nesting limit as ssh
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee]([[:space:]]+|[[:space:]]*=[[:space:]]*)(.+)$ ]]; then
      rest="${BASH_REMATCH[2]}"
      IFS=$' \t' read -ra pats <<< "$rest"
      for pat in "${pats[@]}"; do
        pat="${pat%\"}"; pat="${pat#\"}"
        pat="$(expand_tilde "$pat")"
        # ssh resolves relative Include paths against ~/.ssh for user configs
        if [[ "$pat" != /* ]]; then pat="$HOME/.ssh/$pat"; fi
        while IFS= read -r inc; do
          if [[ -f "$inc" ]]; then _expand_into "$inc" "$out" $(( depth + 1 )); fi
        done < <(compgen -G "$pat" | sort || true)
      done
    else
      printf '%s\n' "$line" >> "$out"
    fi
  done < "$src"
}

# Unique, ordered list of concrete aliases (skips globs, negations, comments)
collect_aliases() {
  awk "$AWK_LIB"'
    kw()=="host" {
      for (i=2;i<=NF;i++) {
        t=$i
        if (t ~ /^#/) break
        if (t ~ /[*?!]/) continue
        if (!seen[t]++) print t
      }
    }
  ' "$1"
}

all_aliases() {
  # Often runs in a subshell (where the EXIT trap doesn't fire), so clean up here
  local exp; expand_config "$SSH_CONFIG" exp
  collect_aliases "$exp"
  rm -f "$exp"
}

alias_exists() { all_aliases | grep -Fxq -- "$1"; }

alias_in_main_config() {
  [[ -f "$SSH_CONFIG" ]] || return 1
  T="$1" awk "$AWK_LIB"'
    BEGIN { T=ENVIRON["T"] }
    has_alias(T) { f=1; exit }
    END { exit !f }
  ' "$SSH_CONFIG"
}

# What ssh will ACTUALLY use (first-match-wins, Match, Include, /etc/ssh, defaults)
# Prints: hostname= user= port= identityfile= keycount=
resolve_effective() {
  ssh ${SSH_F[@]+"${SSH_F[@]}"} -G "$1" </dev/null 2>/dev/null | awk '
    { k=$1; v=$0; sub(/^[^ ]+ /,"",v) }
    k=="hostname" && h=="" { h=v }
    k=="user"     && u=="" { u=v }
    k=="port"     && p=="" { p=v }
    k=="identityfile" { n++; if (n==1) key=v }
    END {
      print "hostname=" h; print "user=" u; print "port=" p
      print "identityfile=" key; print "keycount=" n+0
    }
  ' || true
}

# Literal values written in the first block that lists the alias
block_get() {
  T="$2" awk "$AWK_LIB"'
    BEGIN { T=ENVIRON["T"] }
    inb && is_block_start() { exit }
    inb {
      k=kw()
      if ((k=="hostname" || k=="user" || k=="identityfile" || k=="port") && !(k in v)) v[k]=val()
      next
    }
    has_alias(T) { inb=1 }
    END {
      print "hostname=" v["hostname"]; print "user=" v["user"]
      print "identityfile=" v["identityfile"]; print "port=" v["port"]
    }
  ' "$1"
}

# Every other option in that block (ProxyJump, ForwardAgent, comments...), so edits keep them
block_body() {
  T="$2" awk "$AWK_LIB"'
    BEGIN { T=ENVIRON["T"] }
    inb && is_block_start() { exit }
    inb {
      if (is_note()) { buf[++nb]=$0; next }   # trailing notes belong to the next block
      for (j=1;j<=nb;j++) print buf[j]; nb=0
      k=kw()
      if (k!="hostname" && k!="user" && k!="identityfile" && k!="port") print
      next
    }
    has_alias(T) { inb=1 }
  ' "$1"
}

validate_alias() {
  local a="$1"
  [[ -n "$a" ]] || die "Alias is required."
  [[ "$a" =~ ^[A-Za-z0-9._@][A-Za-z0-9._@-]*$ ]] || die "Invalid alias '$a' (letters, digits, . _ - @ only)"
  [[ ! "$a" =~ ^[0-9]+$ ]] || die "Alias can't be purely numeric (clashes with index lookup): $a"
}

validate_host() {
  local h="$1" o
  local -a octs
  [[ -n "$h" ]] || die "Host is required."
  if [[ "$h" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    IFS='.' read -ra octs <<< "$h"
    for o in "${octs[@]}"; do (( 10#$o <= 255 )) || die "Invalid IPv4: $h"; done
  elif [[ "$h" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:.]+(%[A-Za-z0-9]+)?$ ]]; then
    :   # IPv6
  elif [[ ! "$h" =~ ^[A-Za-z0-9_]([A-Za-z0-9._-]*[A-Za-z0-9_])?$ ]]; then
    die "Invalid host/IP: $h"
  fi
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || die "Invalid port: $1"
}

validate_key() {
  local key; key="$(expand_tilde "$1")"
  [[ -f "$key" ]] || die "SSH key not found at $1"
  local perms
  perms=$(stat -c "%a" "$key" 2>/dev/null || stat -f "%Lp" "$key" 2>/dev/null || echo "")
  if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
    warn "Warning: SSH key should be 600 (or 400). Current: $perms"
    local fix
    read -rp "$(echo -e "${YELLOW}Fix permissions? [y/N]:${NC} ")" fix
    if [[ "$fix" =~ ^[Yy]$ ]]; then chmod 600 "$key"; fi
  fi
}

# Turn "<index>" or "<alias>" into an existing alias name, or die
resolve_alias_arg() {
  local arg="$1" a
  [[ -n "$arg" ]] || die "No alias given."
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    a="$(get_alias_by_index "$arg")"
    [[ -n "$a" ]] || die "No alias at index $arg"
    printf '%s' "$a"
  else
    alias_exists "$arg" || die "Alias '$arg' not found."
    printf '%s' "$arg"
  fi
}

# Parse "<index|alias>" or "-a ALIAS" into the named variable
parse_target() {
  local __var="$1"; shift
  local __t="" opt
  if [[ $# -gt 0 && "$1" != -* ]]; then
    __t="$1"
  else
    OPTIND=1
    while getopts ":a:" opt; do
      case "$opt" in
        a) __t="$OPTARG" ;;
        :) die "Option -$OPTARG needs a value" ;;
        *) die "Invalid option -$OPTARG" ;;
      esac
    done
  fi
  printf -v "$__var" '%s' "$__t"
}

#=== TABLE HELPERS ===#
pad_right() {
  local s="$1" w="$2" n
  n=$(( w - ${#s} ))
  printf '%s' "$s"
  if (( n > 0 )); then printf '%*s' "$n" ''; fi
}

hline() {
  local line
  printf -v line '%*s' "$1" ''
  printf '%s' "${line// /─}"
}

border_row() {
  local l="$1" m="$2" r="$3"; shift 3
  local out="$l" first=1 w
  for w in "$@"; do
    if (( first )); then first=0; else out+="$m"; fi
    out+="$(hline $(( w + 2 )))"
  done
  printf '%b%s%s%b\n' "$BOLD" "$out" "$r" "$NC"
}

#=== COMMANDS ===#
list_aliases() {
  [[ -f "$SSH_CONFIG" ]] || die "No SSH config found at $SSH_CONFIG"

  local -a ALIASES
  mapfile -t ALIASES < <(all_aliases)
  if (( ${#ALIASES[@]} == 0 )); then
    warn "No non-glob aliases found (only wildcard patterns?)."
    return 0
  fi

  local -a C_ID=() C_AL=() C_HO=() C_US=() C_KE=() C_PO=()
  local idx=1 a k v H U K P N
  for a in "${ALIASES[@]}"; do
    H=""; U=""; K=""; P=""; N=0
    while IFS='=' read -r k v; do
      case "$k" in
        hostname)     H="$v" ;;
        user)         U="$v" ;;
        identityfile) K="$v" ;;
        port)         P="$v" ;;
        keycount)     N="$v" ;;
      esac
    done < <(resolve_effective "$a")
    if (( N > 1 )); then K="$K (+$(( N - 1 )))"; fi

    C_ID+=("$idx"); C_AL+=("$a"); C_HO+=("${H:-?}")
    C_US+=("${U:-?}"); C_KE+=("${K:--}"); C_PO+=("${P:-22}")
    idx=$(( idx + 1 ))
  done

  local -a HDR=("ID" "ALIAS" "HOST" "USER" "KEY_PATH" "PORT") W=()
  local i r
  for i in "${!HDR[@]}"; do W[i]=${#HDR[i]}; done
  for r in "${!C_ID[@]}"; do
    if (( ${#C_ID[r]} > W[0] )); then W[0]=${#C_ID[r]}; fi
    if (( ${#C_AL[r]} > W[1] )); then W[1]=${#C_AL[r]}; fi
    if (( ${#C_HO[r]} > W[2] )); then W[2]=${#C_HO[r]}; fi
    if (( ${#C_US[r]} > W[3] )); then W[3]=${#C_US[r]}; fi
    if (( ${#C_KE[r]} > W[4] )); then W[4]=${#C_KE[r]}; fi
    if (( ${#C_PO[r]} > W[5] )); then W[5]=${#C_PO[r]}; fi
  done

  border_row "┌" "┬" "┐" "${W[@]}"
  local line="│"
  for i in "${!HDR[@]}"; do line+=" $(pad_right "${HDR[i]}" "${W[i]}") │"; done
  printf '%b%s%b\n' "$BOLD" "$line" "$NC"
  border_row "├" "┼" "┤" "${W[@]}"
  for r in "${!C_ID[@]}"; do
    printf '│ %b%s%b │ %s │ %s │ %s │ %s │ %s │\n' \
      "$GREEN" "$(pad_right "${C_ID[r]}" "${W[0]}")" "$NC" \
      "$(pad_right "${C_AL[r]}" "${W[1]}")" \
      "$(pad_right "${C_HO[r]}" "${W[2]}")" \
      "$(pad_right "${C_US[r]}" "${W[3]}")" \
      "$(pad_right "${C_KE[r]}" "${W[4]}")" \
      "$(pad_right "${C_PO[r]}" "${W[5]}")"
  done
  border_row "└" "┴" "┘" "${W[@]}"
}

get_alias_by_index() {
  local idx="${1:-0}"
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  local -a ALIASES
  mapfile -t ALIASES < <(all_aliases)
  if (( idx >= 1 && idx <= ${#ALIASES[@]} )); then echo "${ALIASES[$((idx-1))]}"; else echo ""; fi
}

ssh_by_index() {
  [[ $# -eq 1 ]] || die "Usage: sam ssh <index>"
  local idx="$1"
  [[ "$idx" =~ ^[0-9]+$ ]] && (( 10#$idx > 0 )) || die "Index must be a positive integer"
  local alias
  alias="$(get_alias_by_index "$idx")"
  [[ -n "$alias" ]] || die "No alias at index $idx"
  echo -e "${GREEN}Connecting to $alias ...${NC}"
  cleanup   # exec skips the EXIT trap
  exec ssh ${SSH_F[@]+"${SSH_F[@]}"} "$alias"
}

add_alias() {
  local HOST="" ALIAS="" S_USER="" KEY_PATH="" PORT="" opt
  local set_user=0 set_key=0 set_port=0
  OPTIND=1
  while getopts ":h:u:i:a:p:" opt; do
    case "$opt" in
      h) HOST="$OPTARG" ;;
      u) S_USER="$OPTARG"; set_user=1 ;;
      i) KEY_PATH="$OPTARG"; set_key=1 ;;
      a) ALIAS="$OPTARG" ;;
      p) PORT="$OPTARG"; set_port=1 ;;
      :) die "Option -$OPTARG needs a value" ;;
      *) die "Invalid option -$OPTARG" ;;
    esac
  done
  shift $((OPTIND-1))

  # Only prompt for what wasn't passed as a flag
  local interactive=0
  if [[ -z "$HOST" || -z "$ALIAS" ]]; then interactive=1; fi
  if [[ -z "$HOST" ]]; then read -rp "Enter Host/IP (required): " HOST; fi
  if (( interactive && !set_user )); then read -rp "Enter username [${DEFAULT_USER}]: " S_USER; fi
  if (( interactive && !set_key )); then read -rp "Enter SSH key path [${DEFAULT_KEY}]: " KEY_PATH; fi
  if (( interactive && !set_port )); then read -rp "Enter port [22]: " PORT; fi
  if [[ -z "$ALIAS" ]]; then read -rp "Enter alias (required): " ALIAS; fi
  S_USER="${S_USER:-$DEFAULT_USER}"
  KEY_PATH="${KEY_PATH:-$DEFAULT_KEY}"
  PORT="${PORT:-22}"

  validate_alias "$ALIAS"
  validate_host "$HOST"
  validate_port "$PORT"
  validate_key "$KEY_PATH"
  if alias_exists "$ALIAS"; then die "Alias '$ALIAS' already exists."; fi

  local NB tmp
  mktmp NB; mktmp tmp
  {
    printf 'Host %s\n' "$ALIAS"
    printf '  HostName %s\n' "$HOST"
    printf '  User %s\n' "$(cfg_val "$S_USER")"
    printf '  IdentityFile %s\n' "$(cfg_val "$KEY_PATH")"
    if [[ "$PORT" != "22" ]]; then printf '  Port %s\n' "$PORT"; fi
  } > "$NB"

  ensure_config
  backup_config
  # ssh uses the FIRST value it finds, so the new block goes above the first
  # wildcard Host / Match block (e.g. "Host *") instead of after it.
  NBF="$NB" awk "$AWK_LIB"'
    BEGIN { nn=load(ENVIRON["NBF"], nbl) }
    done { print; next }
    is_note() { buf[++nb]=$0; next }
    {
      k=kw(); g=0
      if (k=="host") for (i=2;i<=NF;i++) { if ($i ~ /^#/) break; if ($i ~ /[*?]/) { g=1; break } }
      if (g || k=="match") {
        j=1; while (j<=nb && buf[j] ~ /^[ \t\r]*$/) { print buf[j]; j++ }
        for (x=1;x<=nn;x++) print nbl[x]
        print ""
        for (; j<=nb; j++) print buf[j]
        nb=0; done=1; print; next
      }
      for (j=1;j<=nb;j++) print buf[j]; nb=0
      print
    }
    END {
      if (!done) {
        for (j=1;j<=nb;j++) print buf[j]
        if (NR>0 && !(nb>0 && buf[nb] ~ /^[ \t\r]*$/)) print ""
        for (x=1;x<=nn;x++) print nbl[x]
      }
    }
  ' "$SSH_CONFIG" > "$tmp"
  write_config "$tmp"

  echo -e "${GREEN}Added alias '$ALIAS' for $S_USER@$HOST${NC}"
}

remove_alias() {
  local ALIAS
  parse_target ALIAS "$@"
  if [[ -z "$ALIAS" ]]; then read -rp "Enter alias to remove (index or name): " ALIAS; fi
  ALIAS="$(resolve_alias_arg "$ALIAS")"

  if ! alias_in_main_config "$ALIAS"; then
    warn "Refusing to modify alias '$ALIAS' because it is defined in an Included file."
    warn "Edit/remove it in its original file."
    exit 1
  fi

  backup_config
  local tmp; mktmp tmp
  T="$ALIAS" awk "$AWK_LIB"'
    BEGIN { T=ENVIRON["T"] }
    function out(l){ if (l ~ /^[ \t\r]*$/) { if (lb) return; lb=1 } else lb=0; print l }  # no double blanks
    function flush(   j){ for (j=1;j<=nb;j++) out(buf[j]); nb=0 }
    skip {
      if (is_block_start()) { skip=0 }
      else if (is_note()) { buf[++nb]=$0; next }
      else { nb=0; next }
    }
    is_note() { buf[++nb]=$0; next }
    has_alias(T) {
      rest=""; c=""
      for (i=2;i<=NF;i++) {
        if ($i ~ /^#/) { for (; i<=NF; i++) c=c " " $i; break }
        if ($i!=T) rest=rest " " $i
      }
      if (rest=="") {                             # sole alias: drop whole block
        while (nb>0 && buf[nb] ~ /^[ \t]*#/) nb-- # ...and the comment sitting on it
        flush(); skip=1; next
      }
      flush()
      match($0, /^[ \t]*/)
      out(substr($0,1,RLENGTH) $1 rest c); next  # shared line: drop just this name
    }
    { flush(); out($0) }
    END { if (!skip) flush() }
  ' "$SSH_CONFIG" > "$tmp"
  write_config "$tmp"
  echo -e "${GREEN}Removed alias '$ALIAS'${NC}"
}

edit_alias() {
  local OLD_ALIAS
  parse_target OLD_ALIAS "$@"
  if [[ -z "$OLD_ALIAS" ]]; then read -rp "Enter alias to edit (index or name): " OLD_ALIAS; fi
  OLD_ALIAS="$(resolve_alias_arg "$OLD_ALIAS")"

  local EXPANDED src in_main=0
  expand_config "$SSH_CONFIG" EXPANDED
  if alias_in_main_config "$OLD_ALIAS"; then in_main=1; src="$SSH_CONFIG"; else src="$EXPANDED"; fi

  local k v l_host="" l_user="" l_key="" l_port=""
  while IFS='=' read -r k v; do
    case "$k" in
      hostname) l_host="$v" ;; user) l_user="$v" ;;
      identityfile) l_key="$v" ;; port) l_port="$v" ;;
    esac
  done < <(block_get "$src" "$OLD_ALIAS")

  local e_host="" e_user="" e_key="" e_port="" e_n=0
  while IFS='=' read -r k v; do
    case "$k" in
      hostname) e_host="$v" ;; user) e_user="$v" ;;
      identityfile) e_key="$v" ;; port) e_port="$v" ;; keycount) e_n="$v" ;;
    esac
  done < <(resolve_effective "$OLD_ALIAS")

  echo -e "${YELLOW}Current effective config for '${OLD_ALIAS}' (what ssh will use):${NC}"
  echo "  HostName: ${e_host:-unknown}"
  echo "  User    : ${e_user:-unknown}"
  echo "  Key     : ${e_key:--}$( (( e_n > 1 )) && echo " (+$(( e_n - 1 )) more)" || true)"
  echo "  Port    : ${e_port:-22}"

  local ALIAS HOST S_USER KEY_PATH PORT
  local d_host="${l_host:-$e_host}" d_user="${l_user:-$e_user}" d_port="${l_port:-${e_port:-22}}"
  read -rp "New alias name [${OLD_ALIAS}]: " ALIAS;          ALIAS="${ALIAS:-$OLD_ALIAS}"
  read -rp "New Host (IP or DNS) [${d_host}]: " HOST;        HOST="${HOST:-$d_host}"
  read -rp "Username [${d_user}]: " S_USER;                  S_USER="${S_USER:-$d_user}"
  read -rp "Key Path [${l_key:-none: ssh defaults}] ('-' = none): " KEY_PATH
  if [[ "$KEY_PATH" == "-" ]]; then KEY_PATH=""; else KEY_PATH="${KEY_PATH:-$l_key}"; fi
  read -rp "Port [${d_port}]: " PORT;                        PORT="${PORT:-$d_port}"

  validate_alias "$ALIAS"
  validate_host "$HOST"
  validate_port "$PORT"
  if [[ -n "$KEY_PATH" ]]; then validate_key "$KEY_PATH"; fi
  if [[ "$ALIAS" != "$OLD_ALIAS" ]] && alias_exists "$ALIAS"; then
    die "Alias '$ALIAS' already exists."
  fi

  # New block = edited core fields + every other option the old block had
  local NB tmp
  mktmp NB; mktmp tmp
  {
    printf 'Host %s\n' "$ALIAS"
    printf '  HostName %s\n' "$HOST"
    printf '  User %s\n' "$(cfg_val "$S_USER")"
    if [[ -n "$KEY_PATH" ]]; then printf '  IdentityFile %s\n' "$(cfg_val "$KEY_PATH")"; fi
    if [[ "$PORT" != "22" || -n "$l_port" ]]; then printf '  Port %s\n' "$PORT"; fi
    block_body "$src" "$OLD_ALIAS"
  } > "$NB"

  backup_config
  if (( in_main )); then
    # Replace the block where it sits (keeps its precedence position)
    T="$OLD_ALIAS" NBF="$NB" awk "$AWK_LIB"'
      BEGIN { T=ENVIRON["T"]; nn=load(ENVIRON["NBF"], nbl) }
      skip {
        if (is_block_start()) { skip=0; for (j=1;j<=nb;j++) print buf[j]; nb=0 }
        else if (is_note()) { buf[++nb]=$0; next }
        else { nb=0; next }
      }
      !done && has_alias(T) {
        done=1; rest=""; c=""
        for (i=2;i<=NF;i++) {
          if ($i ~ /^#/) { for (; i<=NF; i++) c=c " " $i; break }
          if ($i!=T) rest=rest " " $i
        }
        for (x=1;x<=nn;x++) print nbl[x]
        if (rest=="") { skip=1; nb=0; next }
        print ""
        match($0, /^[ \t]*/)
        print substr($0,1,RLENGTH) $1 rest c; next
      }
      { print }
    ' "$SSH_CONFIG" > "$tmp"
  else
    warn "Alias '$OLD_ALIAS' is defined in an Included file; that file will NOT be modified."
    warn "Adding an override block at the TOP of $SSH_CONFIG (ssh uses the first value it finds)."
    { cat "$NB"; echo "Match all"; echo; cat "$SSH_CONFIG"; } > "$tmp"
  fi
  write_config "$tmp"

  echo -e "${GREEN}Updated alias '$OLD_ALIAS' -> '$ALIAS'${NC}"
}

#=== MAIN ===#
[[ $# -eq 0 ]] && { print_help; exit 0; }

case "${1:-}" in
  -h|--help|help)          print_help ;;
  -ls|--ls|--list|ls|list) list_aliases ;;
  --add|add)       shift; add_alias "$@" ;;
  --remove|remove) shift; remove_alias "$@" ;;
  --edit|edit)     shift; edit_alias "$@" ;;
  ssh)             shift; ssh_by_index "$@" ;;
  *)
    echo -e "${RED}Unknown command: $1${NC}" >&2
    print_help
    exit 1
    ;;
esac
