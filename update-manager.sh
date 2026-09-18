#!/usr/bin/env bash
#
# update-manager.sh
# ----------------------
# Updates the Proxmox host and/or its Debian/Ubuntu LXC containers.
#
# Interactive usage:
#   sudo ./update-manager.sh
#
# Non-interactive usage (bypasses the menu):
#   sudo ./update-manager.sh --all                  # everything
#   sudo ./update-manager.sh --host-only            # host only
#   sudo ./update-manager.sh --cts-only             # all containers
#   sudo ./update-manager.sh --only host,101,105    # precise selection (host + CTID)
#
# Must be run as root (or via sudo) on the Proxmox node itself.

set -uo pipefail

LOG_FILE="/var/log/update-manager-$(date +%Y%m%d-%H%M%S).log"

C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_BLUE='\033[0;34m'

log()  { echo -e "${C_BLUE}[$(date '+%H:%M:%S')]${C_RESET} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"    | tee -a "$LOG_FILE"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${C_RED}[ERROR]${C_RESET} $*"  | tee -a "$LOG_FILE"; }

if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run as root (sudo)."
    exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
    err "'pct' not found — this script must run on a Proxmox node."
    exit 1
fi

APT_CMD='export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1; \
apt-get update && \
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade -y && \
apt list --upgradable ; \
apt-get autoremove -y && apt-get autoclean'

CT_IDS=()
CT_LABELS=()
CT_SKIPPED_INFO=()

discover_containers() {
    CT_IDS=()
    CT_LABELS=()
    CT_SKIPPED_INFO=()

    mapfile -t CT_LINES < <(pct list | tail -n +2)

    for line in "${CT_LINES[@]}"; do
        [[ -z "$line" ]] && continue
        local vmid status name
        vmid=$(awk '{print $1}' <<< "$line")
        status=$(awk '{print $2}' <<< "$line")
        name=$(awk '{print $NF}' <<< "$line")

        if [[ "$status" != "running" ]]; then
            CT_SKIPPED_INFO+=("CT $vmid ($name): stopped, skipped.")
            continue
        fi

        local os_id
        os_id=$(pct exec "$vmid" -- sh -c '. /etc/os-release 2>/dev/null && echo "$ID"' 2>/dev/null || echo "unknown")

        if [[ "$os_id" != "debian" && "$os_id" != "ubuntu" ]]; then
            CT_SKIPPED_INFO+=("CT $vmid ($name): distro '$os_id' not supported, skipped.")
            continue
        fi

        CT_IDS+=("$vmid")
        CT_LABELS+=("CT $vmid ($name) — $os_id")
    done
}

UPDATED=()
FAILED=()

show_failure_tail() {
    local tmp_output="$1"
    echo -e "${C_RED}--- Last lines of output (diagnostics) ---${C_RESET}"
    tail -n 20 "$tmp_output"
    echo -e "${C_RED}------------------------------------------------${C_RESET}"
}

update_host() {
    log "=== Updating Proxmox host ($(hostname)) ==="
    local tmp_output
    tmp_output=$(mktemp)
    if bash -c "$APT_CMD" > "$tmp_output" 2>&1; then
        ok "Proxmox host updated successfully."
        UPDATED+=("Host ($(hostname))")
    else
        err "Failed to update Proxmox host (see $LOG_FILE)."
        FAILED+=("Host ($(hostname))")
        show_failure_tail "$tmp_output"
    fi
    cat "$tmp_output" >> "$LOG_FILE"
    rm -f "$tmp_output"
    echo
}

update_container() {
    local vmid="$1"
    local label="$2"
    log "=== Updating $label ==="
    local tmp_output
    tmp_output=$(mktemp)
    if pct exec "$vmid" -- bash -c "$APT_CMD" > "$tmp_output" 2>&1; then
        ok "$label updated successfully."
        UPDATED+=("$label")
    else
        err "Failed to update $label (see $LOG_FILE)."
        FAILED+=("$label")
        show_failure_tail "$tmp_output"
    fi
    cat "$tmp_output" >> "$LOG_FILE"
    rm -f "$tmp_output"
    echo
}

print_summary() {
    log "=== Summary ==="
    echo "  Updated : ${#UPDATED[@]}"
    for u in "${UPDATED[@]:-}"; do [[ -n "$u" ]] && echo "    - $u"; done
    echo "  Failed  : ${#FAILED[@]}"
    for f in "${FAILED[@]:-}"; do [[ -n "$f" ]] && echo "    - $f"; done
    if [[ "${#CT_SKIPPED_INFO[@]}" -gt 0 ]]; then
        echo "  Skipped : ${#CT_SKIPPED_INFO[@]}"
        for s in "${CT_SKIPPED_INFO[@]}"; do echo "    - $s"; done
    fi
    log "Full log: $LOG_FILE"
}

SELECTED_TARGETS=()

select_targets_interactive() {
    discover_containers

    local CHECKLIST_BIN=""
    if command -v whiptail >/dev/null 2>&1; then
        CHECKLIST_BIN="whiptail"
    elif command -v dialog >/dev/null 2>&1; then
        CHECKLIST_BIN="dialog"
    fi

    if [[ -n "$CHECKLIST_BIN" ]]; then
        local items=()
        items+=("host" "Proxmox host ($(hostname))" "OFF")
        for i in "${!CT_IDS[@]}"; do
            items+=("${CT_IDS[$i]}" "${CT_LABELS[$i]}" "OFF")
        done

        local result
        result=$("$CHECKLIST_BIN" --separate-output --checklist \
            "Select the targets to update (SPACE to check, ENTER to confirm)" \
            22 78 12 "${items[@]}" 3>&1 1>&2 2>&3)

        if [[ -z "$result" ]]; then
            SELECTED_TARGETS=()
            return
        fi
        while IFS= read -r line; do
            [[ -n "$line" ]] && SELECTED_TARGETS+=("$line")
        done <<< "$result"
        return
    fi

    echo
    echo "whiptail/dialog not installed — select via numbers separated by spaces."
    echo "  0) Proxmox host ($(hostname))"
    for i in "${!CT_IDS[@]}"; do
        echo "  $((i + 1))) ${CT_LABELS[$i]}"
    done
    echo
    read -r -p "Enter the desired numbers separated by a space (e.g.: 0 1 3): " -a choices

    for choice in "${choices[@]:-}"; do
        [[ -z "$choice" ]] && continue
        if [[ "$choice" == "0" ]]; then
            SELECTED_TARGETS+=("host")
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#CT_IDS[@]} )); then
            SELECTED_TARGETS+=("${CT_IDS[$((choice - 1))]}")
        else
            warn "Choice ignored (invalid): $choice"
        fi
    done
}

run_selected_targets() {
    if [[ "${#SELECTED_TARGETS[@]}" -eq 0 ]]; then
        warn "No target selected, nothing to do."
        return
    fi
    for target in "${SELECTED_TARGETS[@]}"; do
        if [[ "$target" == "host" ]]; then
            update_host
        else
            local label="CT $target"
            for i in "${!CT_IDS[@]}"; do
                [[ "${CT_IDS[$i]}" == "$target" ]] && label="${CT_LABELS[$i]}"
            done
            update_container "$target" "$label"
        fi
    done
}

run_all() {
    update_host
    discover_containers
    for i in "${!CT_IDS[@]}"; do
        update_container "${CT_IDS[$i]}" "${CT_LABELS[$i]}"
    done
}

run_cts_only() {
    discover_containers
    if [[ "${#CT_IDS[@]}" -eq 0 ]]; then
        warn "No running Debian/Ubuntu containers found."
        return
    fi
    for i in "${!CT_IDS[@]}"; do
        update_container "${CT_IDS[$i]}" "${CT_LABELS[$i]}"
    done
}

show_menu() {
    echo
    echo "=========================================="
    echo "   Proxmox update — $(hostname)"
    echo "=========================================="
    echo "  1) Update everything (host + all containers)"
    echo "  2) Proxmox host only"
    echo "  3) Containers only (all)"
    echo "  4) Manual selection (host and/or containers of choice)"
    echo "  0) Cancel"
    echo "=========================================="
    read -r -p "Your choice [1-4, 0 to cancel]: " MENU_CHOICE
}

case "${1:-}" in
    --all)
        run_all
        print_summary
        exit 0
        ;;
    --host-only)
        update_host
        print_summary
        exit 0
        ;;
    --cts-only)
        run_cts_only
        print_summary
        exit 0
        ;;
    --only)
        shift
        IFS=',' read -r -a wanted <<< "${1:-}"
        discover_containers
        for w in "${wanted[@]}"; do
            [[ "$w" == "host" ]] && SELECTED_TARGETS+=("host") || SELECTED_TARGETS+=("$w")
        done
        run_selected_targets
        print_summary
        exit 0
        ;;
esac

show_menu
case "$MENU_CHOICE" in
    1)
        run_all
        ;;
    2)
        update_host
        ;;
    3)
        run_cts_only
        ;;
    4)
        select_targets_interactive
        run_selected_targets
        ;;
    0)
        echo "Cancelled."
        exit 0
        ;;
    *)
        err "Invalid choice."
        exit 1
        ;;
esac

print_summary
