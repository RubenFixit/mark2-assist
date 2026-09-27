#!/bin/bash
# Helpers for the hardware test; sourcing this file does not change the system.

HW_ACTIVE_UNITS=()
HW_INACTIVE_UNITS=()
HW_RESTORE_PENDING=false

# Explicit compatibility candidates, not a substring match against all modules.
# The installer builds vocalfusion-soundcard; accept alternate VocalFusion
# names too so the diagnostic is not tied to that one driver build.
HW_VOCALFUSION_MODULES=(
    vocalfusion_soundcard
    vocalfusion
    snd_soc_vocalfusion
    snd_soc_vocalfusion_soundcard
)

hw_install_cleanup() {
    trap 'hw_cleanup "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
}

hw_cleanup() {
    local status="$1" unit i
    local -a activated=()
    set +e
    trap - EXIT
    # A second Ctrl-C must not interrupt restoration halfway through.
    trap '' INT TERM HUP PIPE
    if [ "$HW_RESTORE_PENDING" = true ]; then
        echo "  Restoring previously active user services and sockets..."
        # Reverse stop order: audio sockets/servers before their consumers.
        for ((i=${#HW_ACTIVE_UNITS[@]}-1; i>=0; i--)); do
            unit="${HW_ACTIVE_UNITS[i]}"
            if ! systemctl --user start "$unit"; then
                echo "  ERROR: Could not restore $unit. Retry: systemctl --user start $unit" >&2
                [ "$status" -ne 0 ] || status=1
            fi
        done
        # Starting PipeWire can pull in an enabled but previously stopped
        # WirePlumber (or socket). Restore that stopped state as well.
        for unit in "${HW_INACTIVE_UNITS[@]}"; do
            if systemctl --user is-active --quiet "$unit"; then
                activated+=("$unit")
            fi
        done
        if [ "${#activated[@]}" -gt 0 ]; then
            if ! systemctl --user stop "${activated[@]}"; then
                echo "  ERROR: Could not restore stopped state: ${activated[*]}" >&2
                [ "$status" -ne 0 ] || status=1
            fi
        fi
        for unit in "${HW_ACTIVE_UNITS[@]}"; do
            if ! systemctl --user is-active --quiet "$unit"; then
                echo "  ERROR: $unit is not active after restoration; check systemctl --user status $unit" >&2
                [ "$status" -ne 0 ] || status=1
            fi
        done
    fi
    exit "$status"
}

hw_stop_conflicts() {
    local unit state
    local -a candidates=(
        mark2-volume-buttons.service lva.service
        wireplumber.service pipewire-pulse.service pipewire.service
        pipewire-pulse.socket pipewire.socket
    )
    # Fail before changing anything if the user's service manager is unavailable.
    if ! systemctl --user show-environment >/dev/null; then
        echo "  ERROR: Cannot contact your user service manager. Run as the logged-in Mark II user, without sudo." >&2
        return 1
    fi
    # Snapshot every unit BEFORE stopping any: dependencies can stop other units.
    for unit in "${candidates[@]}"; do
        state=$(systemctl --user is-active "$unit" 2>/dev/null) || :
        case "$state" in
            active) HW_ACTIVE_UNITS+=("$unit") ;;
            inactive|failed) HW_INACTIVE_UNITS+=("$unit") ;;
            unknown) ;;
            *)
                echo "  ERROR: $unit has state '${state:-unavailable}'; wait for services to settle and retry." >&2
                return 1 ;;
        esac
    done
    [ "${#HW_ACTIVE_UNITS[@]}" -gt 0 ] || return 0
    echo "  Temporarily stopping: ${HW_ACTIVE_UNITS[*]}"
    # Arm restoration before stop, including partial failure or interruption.
    HW_RESTORE_PENDING=true
    # One transaction includes sockets so clients cannot socket-activate servers.
    # No enable/disable/mask operations: persistent settings remain untouched.
    if ! systemctl --user stop "${HW_ACTIVE_UNITS[@]}"; then
        echo "  ERROR: Could not stop all conflicting units; aborting the test." >&2
        return 1
    fi
    for unit in "${HW_ACTIVE_UNITS[@]}"; do
        state=$(systemctl --user is-active "$unit" 2>/dev/null) || :
        case "$state" in
            inactive|failed) ;;
            *) echo "  ERROR: $unit did not stay stopped ($state)." >&2; return 1 ;;
        esac
    done
}

hw_loaded_vocalfusion_module() {
    local module normalized module_root="${1:-/sys/module}"
    # Linux normalizes the module filename's hyphen to an underscore.
    # Read sysfs directly: lsmod | grep -q can fail with SIGPIPE under pipefail.
    for module in "${HW_VOCALFUSION_MODULES[@]}"; do
        normalized="${module//-/_}"
        if [ -d "$module_root/$normalized" ]; then
            printf '%s\n' "$normalized"
            return 0
        fi
    done
    return 1
}

hw_button_device() {
    local entry name found=""
    local input_class="${1:-/sys/class/input}" input_dir="${2:-/dev/input}"
    for entry in "$input_class"/event*; do
        [ -r "$entry/device/name" ] || continue
        IFS= read -r name < "$entry/device/name" || continue
        case "$name" in
            soc:sj201_buttons|sj201_buttons)
                if [ -n "$found" ]; then
                    echo "  Multiple SJ201 button devices found; cannot choose safely." >&2
                    return 1
                fi
                found="$input_dir/${entry##*/}" ;;
        esac
    done
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

hw_button_pressed() {
    local output status=0
    # Keep reading to EOF so timeout/SIGPIPE cannot turn a real press into failure.
    output=$(timeout 8 stdbuf -oL evtest "$1" 2>&1) || status=$?
    if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
        printf '%s\n' "$output" >&2
        return 1
    fi
    grep -Eq '^Event: .*type 1 \(EV_KEY\), code (114|115|248|582) .*value 1$' <<< "$output"
}
