#!/usr/bin/env bash
# privilege_escalation_audit.sh
# Quick audit of local privilege escalation exposure on Linux hosts.
# Reads system files only; does not change anything.

set -o errexit
set -o nounset
set -o pipefail

# ---------- helpers ----------
have_cmd() { command -v "$1" >/dev/null 2>&1; }
safe_run() { "$@" 2>/dev/null || true; }  # never crash on read failures
print_hdr() { echo -e "\n=== $* ==="; }
print_sec() { echo -e "\n[$*]"; }
is_root() { [ "$(id -u)" -eq 0 ]; }

start_time=$(date +%s)
host="$(hostname 2>/dev/null || echo unknown)"
run_as="UID=$(id -u) USER=$(id -un 2>/dev/null || echo unknown)"

echo "=== Privilege Escalation Audit ==="
echo "Host: $host | $run_as | $(date -u) UTC"
echo "-------------------------------------------------------------"

# ---------- 0) environment sanity ----------
print_sec "0) Environment"
echo "Using getent: $(have_cmd getent && echo yes || echo no)"
echo "visudo available: $(have_cmd visudo && echo yes || echo no)"
echo "sudo available: $(have_cmd sudo && echo yes || echo no)"
echo "grep version: $(grep --version 2>/dev/null | head -n1 || echo grep)"
echo "Note: Running as root enables full checks (shadow, all sudoers)."

# ---------- 1) UID 0 accounts ----------
print_sec "1) Accounts with UID 0"
uid0_list=$(safe_run getent passwd | awk -F: '$3 == 0 {print $1}')
if [ -z "$uid0_list" ]; then
  # fallback to local files if getent missing
  uid0_list=$(awk -F: '$3 == 0 {print $1}' /etc/passwd 2>/dev/null || true)
fi
uid0_count=$(printf "%s\n" "$uid0_list" | sed '/^$/d' | wc -l | tr -d ' ')
echo "Count: $uid0_count"
if [ -n "$uid0_list" ]; then
  echo "$uid0_list" | sed 's/^/  - /'
fi

# ---------- 2) Admin-capable groups ----------
print_sec "2) Admin-capable groups and members"
# Start with common groups
common_admin_groups="sudo wheel admin"
# Parse sudoers for any %group rules too
sudoers_files=()
if [ -f /etc/sudoers ]; then
  sudoers_files+=("/etc/sudoers")
fi
if [ -d /etc/sudoers.d ]; then
  # include regular files only
  while IFS= read -r f; do sudoers_files+=("$f"); done < <(find /etc/sudoers.d -maxdepth 1 -type f 2>/dev/null | sort)
fi

parsed_groups=""
if [ "${#sudoers_files[@]}" -gt 0 ]; then
  parsed_groups=$(safe_run grep -hE '^[[:space:]]*%[A-Za-z0-9_.-]+' "${sudoers_files[@]}" \
                  | sed -E 's/^[[:space:]]*%([A-Za-z0-9_.-]+).*/\1/' \
                  | sort -u)
fi

all_groups=$(printf "%s\n%s\n" "$common_admin_groups" "$parsed_groups" | tr ' ' '\n' | sed '/^$/d' | sort -u)

if [ -z "$all_groups" ]; then
  echo "No admin groups detected (or unreadable sudoers)."
else
  echo "Groups considered admin-capable:"
  echo "$all_groups" | sed 's/^/  - /'
  echo
  echo "Members:"
  while IFS= read -r g; do
    line=$(safe_run getent group "$g")
    if [ -n "$line" ]; then
      members=$(printf "%s\n" "$line" | awk -F: '{print $4}')
      [ -z "$members" ] && members="(none listed)"
      echo "  - $g: $members"
    else
      echo "  - $g: (group not present)"
    fi
  done <<<"$all_groups"
fi

# ---------- 3) Full-sudo rules ----------
print_sec "3) Users/aliases with full sudo (ALL=(ALL:ALL) ALL)"
if [ "${#sudoers_files[@]}" -gt 0 ]; then
  safe_run grep -HnE '^[[:space:]]*[^#].*ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' "${sudoers_files[@]}" | sed 's/^/  - /' || echo "  - None found"
else
  echo "  - Cannot read sudoers"
fi

# ---------- 4) Passwordless sudo (NOPASSWD) ----------
print_sec "4) Passwordless sudo (NOPASSWD) rules"
if [ "${#sudoers_files[@]}" -gt 0 ]; then
  safe_run grep -HnR --include='*' -E '^[[:space:]]*[^#].*NOPASSWD' "${sudoers_files[@]}" | sed 's/^/  - /' || echo "  - None found"
else
  echo "  - Cannot read sudoers"
fi

# ---------- 5) Validate sudoers syntax ----------
print_sec "5) Sudoers syntax validation"
if have_cmd visudo; then
  status_main="OK"
  if ! safe_run visudo -cf /etc/sudoers >/dev/null; then status_main="ERROR"; fi
  echo "  - /etc/sudoers: $status_main"
  if [ -d /etc/sudoers.d ]; then
    while IFS= read -r f; do
      st="OK"; safe_run visudo -cf "$f" >/dev/null || st="ERROR"
      echo "  - $f: $st"
    done < <(find /etc/sudoers.d -maxdepth 1 -type f 2>/dev/null | sort)
  fi
else
  echo "  - visudo not available; skipping."
fi

# ---------- 6) Empty passwords (shadow) ----------
print_sec "6) Accounts with EMPTY password fields (/etc/shadow)"
if is_root; then
  # Field 2 empty means literally no hash stored (dangerous).
  safe_run awk -F: '($2 == "") {print "  - " $1}' /etc/shadow || echo "  - None found"
else
  echo "  - Need root to read /etc/shadow."
fi

# ---------- 7) Non-root users with UID 0 ----------
print_sec "7) Non-root users with UID 0 (backdoor risk)"
nr_uid0=$(safe_run getent passwd | awk -F: '($3 == 0 && $1 != "root") {print $1}')
if [ -z "$nr_uid0" ]; then
  # fallback
  nr_uid0=$(awk -F: '($3 == 0 && $1 != "root") {print $1}' /etc/passwd 2>/dev/null || true)
fi
if [ -n "$nr_uid0" ]; then
  echo "$nr_uid0" | sed 's/^/  - /'
else
  echo "  - None found"
fi

# ---------- 8) SSH root login exposure ----------
print_sec "8) SSH root access vectors"
# 8a) Root's authorized_keys
if [ -f /root/.ssh/authorized_keys ]; then
  echo "  - /root/.ssh/authorized_keys exists"
else
  echo "  - No /root/.ssh/authorized_keys"
fi
# 8b) System-level authorized_keys
if [ -d /etc/ssh/authorized_keys ]; then
  echo "  - /etc/ssh/authorized_keys present (system-wide keys directory)"
fi
if [ -d /etc/ssh/authorized_keys.d ]; then
  echo "  - /etc/ssh/authorized_keys.d present (drop-in keys for users)"
fi
# 8c) sshd_config effective settings (PermitRootLogin, PasswordAuthentication)
echo "  - sshd configuration:"
sshd_files=()
[ -f /etc/ssh/sshd_config ] && sshd_files+=("/etc/ssh/sshd_config")
if [ -d /etc/ssh/sshd_config.d ]; then
  while IFS= read -r f; do sshd_files+=("$f"); done < <(find /etc/ssh/sshd_config.d -maxdepth 1 -type f 2>/dev/null | sort)
fi
if [ "${#sshd_files[@]}" -eq 0 ]; then
  echo "    * No sshd config files found"
else
  # Parse last effective setting (last one wins)
  for key in PermitRootLogin PasswordAuthentication PubkeyAuthentication; do
    val=$(safe_run awk -v k="$key" '
      BEGIN{IGNORECASE=1}
      /^[[:space:]]*#/ {next}
      $1 ~ ("^" k "$") {v=$2}
      END{if (v!="") print v}
    ' "${sshd_files[@]}")
    [ -n "$val" ] && echo "    * $key: $val" || echo "    * $key: (unset/default)"
  done
fi

# ---------- 9) Per-user sudo entitlements (optional/heavy) ----------
print_sec "9) Per-user sudo summary (sudo -l) [best-effort]"
if have_cmd sudo; then
  # Enumerate local users with shells (likely humans)
  users=$(safe_run getent passwd | awk -F: '$7 ~ /(bash|zsh|sh|fish)$/ {print $1}')
  if [ -z "$users" ]; then
    users=$(awk -F: '$7 ~ /(bash|zsh|sh|fish)$/ {print $1}' /etc/passwd 2>/dev/null || true)
  fi
  count=0
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    count=$((count+1))
    echo "  - $u:"
    # Try without password; if it prompts, we still suppress interactivity
    safe_run sudo -l -U "$u" | sed 's/^/      /' || echo "      (not allowed or needs password)"
    # keep output short-ish
    [ $count -ge 10 ] && { echo "    ...truncated after 10 users"; break; }
  done <<<"$users"
else
  echo "  - sudo not installed."
fi

# ---------- 10) Summary ----------
print_sec "10) Summary"
echo "UID 0 accounts: $uid0_count"
if [ -n "$all_groups" ]; then
  echo "Admin groups detected: $(echo "$all_groups" | tr '\n' ' ' | sed 's/[[:space:]]$//')"
else
  echo "Admin groups detected: (none)"
fi
echo "Full sudo rules present: $( [ "${#sudoers_files[@]}" -gt 0 ] && safe_run grep -hE '^[[:space:]]*[^#].*ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' "${sudoers_files[@]}" | wc -l | tr -d ' ' || echo 0 )"
echo "NOPASSWD rules present: $( [ "${#sudoers_files[@]}" -gt 0 ] && safe_run grep -hE '^[[:space:]]*[^#].*NOPASSWD' "${sudoers_files[@]}" | wc -l | tr -d ' ' || echo 0 )"

end_time=$(date +%s)
elapsed=$((end_time - start_time))
echo "-------------------------------------------------------------"
echo "Completed in ${elapsed}s"
