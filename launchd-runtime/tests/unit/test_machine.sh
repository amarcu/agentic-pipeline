#!/bin/bash
# Tests for launchd-runtime/bin/machine — wake, boot, run and release the
# machines in machines.conf. What these pin is the rules a job must never break:
# nothing but the desktop is powered, nothing reboots under a logged-in person,
# and Windows is reached only through a one-time BootNext. No real packet, ssh
# or tailnet call is made: all three are mocks driven by files in $MC_TMP.

_mc_setup() {
    MC_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-machine.XXXXXX)
    /bin/mkdir -p "$MC_TMP/up"
    : > "$MC_TMP/ssh.log"
    : > "$MC_TMP/wol.log"

    # A host answers SSH while $MC_TMP/up/<host> exists; `who` prints
    # $MC_TMP/who-<host>. BootNext + reboot drops the host, as a reboot would.
    /bin/cat > "$MC_TMP/ssh" <<'SH'
#!/bin/bash
while [[ "$1" == "-o" ]]; do shift 2; done
target="$1"; shift; host="${target#*@}"; cmd="$*"
echo "$host $cmd" >> "$MC_TMP/ssh.log"
[[ -e "$MC_TMP/up/$host" ]] || exit 255
case "$cmd" in
    "exit 0") exit 0 ;;
    "query user") [[ -e "$MC_TMP/who-fails" ]] && exit 1
                  [[ -e "$MC_TMP/who-$host" ]] || { echo "No User exists for *" >&2; exit 1; }
                  /bin/cat "$MC_TMP/who-$host"; exit 0 ;;
    who) [[ -e "$MC_TMP/who-fails" ]] && exit 1
                      /bin/cat "$MC_TMP/who-$host" 2>/dev/null; exit 0 ;;
    *efibootmgr*) /bin/rm -f "$MC_TMP/up/$host"; : > "$MC_TMP/up/desktop-win"; exit 255 ;;
    *"shutdown /r"*) /bin/rm -f "$MC_TMP/up/$host"; : > "$MC_TMP/up/gpu-box"; exit 255 ;;
    *poweroff*|*"shutdown /s"*) [[ -e "$MC_TMP/poweroff-refused" ]] && exit 1
                                /bin/rm -f "$MC_TMP/up/$host"; exit 255 ;;
    *) echo "ran: $cmd"; exit 0 ;;
esac
SH
    # Wake brings Ubuntu up only when $MC_TMP/wakes exists — the NIC answering.
    /bin/cat > "$MC_TMP/wol" <<'SH'
#!/bin/bash
echo "$*" >> "$MC_TMP/wol.log"
[[ -e "$MC_TMP/wakes" ]] && : > "$MC_TMP/up/gpu-box"
exit 0
SH
    # The tailnet: HostName is a display name and DNSName is what matches.
    /bin/cat > "$MC_TMP/tailscale" <<'SH'
#!/bin/bash
/bin/cat "$MC_TMP/status.json"
SH
    /bin/cat > "$MC_TMP/status.json" <<'JSON'
{"Self": {"DNSName": "pipeline-mac.tail.ts.net.", "HostName": "Pipeline Mac", "Online": true},
 "Peer": {
   "a": {"DNSName": "gpu-box.tail.ts.net.", "HostName": "ubuntu", "Online": false},
   "b": {"DNSName": "relay-pi.tail.ts.net.", "HostName": "relay-pi", "Online": true}}}
JSON
    /bin/chmod +x "$MC_TMP/ssh" "$MC_TMP/wol" "$MC_TMP/tailscale"

    /usr/bin/sed 's/^DESKTOP_WINDOWS_BOOT_ENTRY=.*/DESKTOP_WINDOWS_BOOT_ENTRY="0003"/' \
        "$RUNTIME_DIR/machines.conf.example" > "$MC_TMP/machines.conf"
    # The fixture's own roster, so the tests do not move when the real one does.
    # The Windows side starts with no host; a test that needs one sets it.
    /bin/cat >> "$MC_TMP/machines.conf" <<'CONF'
get_machine_host() {
    case "$1" in
        m2)              echo "pipeline-mac" ;;
        m4)              echo "work-mac" ;;
        desktop-ubuntu)  echo "gpu-box" ;;
        desktop-windows) echo "" ;;
        laptop)          echo "win-laptop" ;;
        pi)              echo "relay-pi" ;;
        *)               echo "" ;;
    esac
}
get_machine_user() {
    case "$1" in
        desktop-ubuntu)  echo "dev" ;;
        desktop-windows) echo "" ;;
        *)               echo "" ;;
    esac
}
CONF

    export MC_TMP
    export MACHINES_CONF="$MC_TMP/machines.conf"
    export MACHINE_SSH="$MC_TMP/ssh"
    export MACHINE_WOL_SEND="$MC_TMP/wol"
    export TAILSCALE="$MC_TMP/tailscale"
    export MACHINE_WAIT_SECONDS=2
    export MACHINE_POLL_SECONDS=0
}

_mc_teardown() {
    /bin/rm -rf "$MC_TMP"
    unset MC_TMP MACHINES_CONF MACHINE_SSH MACHINE_WOL_SEND TAILSCALE MACHINE_WAIT_SECONDS MACHINE_POLL_SECONDS
}

_mc() { "$RUNTIME_DIR/bin/machine" "$@"; }

test_machine_never_powers_anything_but_the_desktop() {
    _mc_setup
    local rc=0 out status
    for name in m2 m4 laptop pi; do
        out=$(_mc release "$name"); status=$?
        assert_equal 3 "$status" "release $name is refused" || rc=1
        assert_contains "$out" "result=refused" || rc=1
    done
    out=$(_mc wake laptop); status=$?
    assert_equal 3 "$status" "only the desktop is woken" || rc=1
    assert_equal "" "$(/bin/cat "$MC_TMP/ssh.log")" "no refusal touches a machine" || rc=1
    _mc_teardown
    return $rc
}

test_machine_boot_windows_needs_the_boot_entry() {
    _mc_setup
    local rc=0 out status
    /usr/bin/sed -i '' 's/^DESKTOP_WINDOWS_BOOT_ENTRY=.*/DESKTOP_WINDOWS_BOOT_ENTRY=""/' "$MACHINES_CONF"
    : > "$MC_TMP/up/gpu-box"
    out=$(_mc boot desktop windows); status=$?
    assert_equal 3 "$status" "an unset entry is refused, not guessed" || rc=1
    assert_contains "$out" "DESKTOP_WINDOWS_BOOT_ENTRY is not set" || rc=1
    assert_not_contains "$(/bin/cat "$MC_TMP/ssh.log")" "efibootmgr" "nothing is written to the firmware" || rc=1
    _mc_teardown
    return $rc
}

test_machine_never_reboots_under_a_logged_in_person() {
    _mc_setup
    local rc=0 out status
    /usr/bin/sed -i '' 's/desktop-windows) echo ""/desktop-windows) echo "desktop-win"/' "$MACHINES_CONF"
    : > "$MC_TMP/up/gpu-box"
    echo "dev      seat0        2026-09-27 09:12" > "$MC_TMP/who-gpu-box"
    out=$(_mc boot desktop windows); status=$?
    assert_equal 3 "$status" "someone at the desk refuses the reboot" || rc=1
    assert_contains "$out" "someone is using ubuntu" || rc=1
    out=$(_mc release desktop-ubuntu); status=$?
    assert_equal 3 "$status" "and refuses the power-off" || rc=1
    assert_not_contains "$(/bin/cat "$MC_TMP/ssh.log")" "efibootmgr" || rc=1
    assert_not_contains "$(/bin/cat "$MC_TMP/ssh.log")" "poweroff" || rc=1
    _mc_teardown
    return $rc
}

test_machine_boots_windows_once_through_bootnext() {
    _mc_setup
    local rc=0 out status log
    /usr/bin/sed -i '' 's/desktop-windows) echo ""/desktop-windows) echo "desktop-win"/' "$MACHINES_CONF"
    : > "$MC_TMP/up/gpu-box"
    out=$(_mc boot desktop windows); status=$?
    assert_equal 0 "$status" "the reboot is issued and Windows answers" || rc=1
    assert_contains "$out" "windows up" || rc=1
    log=$(/bin/cat "$MC_TMP/ssh.log")
    assert_contains "$log" "sudo -n /usr/bin/efibootmgr --bootnext 0003" "one-time BootNext, never the default order" || rc=1
    assert_not_contains "$log" "grub" "GRUB is never used" || rc=1
    _mc_teardown
    return $rc
}

test_machine_boot_windows_needs_a_login_there() {
    # Rebooting into a Windows the pipeline cannot reach strands the desktop:
    # the job cannot run and nothing can boot it back.
    _mc_setup
    local rc=0 out status
    : > "$MC_TMP/up/gpu-box"
    out=$(_mc boot desktop windows); status=$?
    assert_equal 3 "$status" "refused before any reboot" || rc=1
    assert_contains "$out" "no host or pipeline login" || rc=1
    assert_not_contains "$(/bin/cat "$MC_TMP/ssh.log")" "efibootmgr" || rc=1
    _mc_teardown
    return $rc
}

test_machine_wakes_the_desktop_and_waits_for_ubuntu() {
    _mc_setup
    local rc=0 out status
    : > "$MC_TMP/wakes"
    out=$(_mc wake desktop); status=$?
    assert_equal 0 "$status" || rc=1
    assert_contains "$out" "ubuntu up" || rc=1
    assert_equal "02:00:00:AA:BB:CC 192.168.1.255" "$(/bin/cat "$MC_TMP/wol.log")" \
        "the packet goes to the desktop's MAC on the LAN broadcast" || rc=1
    _mc_teardown
    return $rc
}

test_machine_wake_times_out_and_dry_run_sends_nothing() {
    _mc_setup
    local rc=0 out status
    out=$(_mc --dry-run wake desktop); status=$?
    assert_equal 0 "$status" || rc=1
    assert_contains "$out" "dry-run" || rc=1
    assert_equal "" "$(/bin/cat "$MC_TMP/wol.log")" "a dry run sends no packet" || rc=1
    out=$(_mc wake desktop); status=$?
    assert_equal 4 "$status" "a desktop that never answers times out" || rc=1
    assert_contains "$out" "result=timeout" || rc=1
    _mc_teardown
    return $rc
}

test_machine_releases_an_idle_desktop() {
    _mc_setup
    local rc=0 out status
    : > "$MC_TMP/up/gpu-box"
    out=$(_mc release desktop-ubuntu); status=$?
    assert_equal 0 "$status" || rc=1
    assert_contains "$(/bin/cat "$MC_TMP/ssh.log")" "sudo -n /usr/bin/systemctl poweroff" || rc=1
    _mc_teardown
    return $rc
}

test_machine_list_matches_peers_by_dns_name() {
    _mc_setup
    local rc=0 out
    out=$(_mc list)
    assert_contains "$out" "down (gpu-box)" "HostName 'ubuntu' does not hide the peer" || rc=1
    assert_contains "$out" "up (relay-pi)" || rc=1
    assert_contains "$out" "up (pipeline-mac)" "this host is Self, not a peer" || rc=1
    assert_contains "$out" "not on the tailnet" "desktop-windows has no host yet" || rc=1
    _mc_teardown
    return $rc
}

test_machine_run_needs_a_pipeline_login() {
    _mc_setup
    local rc=0 out status
    out=$(_mc run laptop -- hostname); status=$?
    assert_equal 3 "$status" "the laptop is the human's; no login is configured" || rc=1
    : > "$MC_TMP/up/gpu-box"
    out=$(_mc run desktop-ubuntu -- nvidia-smi); status=$?
    assert_equal 0 "$status" || rc=1
    assert_contains "$out" "ran: nvidia-smi" || rc=1
    _mc_teardown
    return $rc
}

test_machine_a_failed_presence_check_counts_as_someone_there() {
    _mc_setup
    local rc=0 out status
    /usr/bin/sed -i '' 's/desktop-windows) echo ""/desktop-windows) echo "desktop-win"/' "$MACHINES_CONF"
    : > "$MC_TMP/up/gpu-box"
    : > "$MC_TMP/who-fails"
    out=$(_mc boot desktop windows); status=$?
    assert_equal 3 "$status" "not knowing who is there refuses the reboot" || rc=1
    out=$(_mc release desktop-ubuntu); status=$?
    assert_equal 3 "$status" "and the power-off" || rc=1
    assert_not_contains "$(/bin/cat "$MC_TMP/ssh.log")" "efibootmgr" || rc=1
    assert_not_contains "$(/bin/cat "$MC_TMP/ssh.log")" "poweroff" || rc=1
    _mc_teardown
    return $rc
}

test_machine_release_fails_when_the_desktop_stays_up() {
    _mc_setup
    local rc=0 out status
    : > "$MC_TMP/up/gpu-box"
    : > "$MC_TMP/poweroff-refused"
    out=$(_mc release desktop-ubuntu); status=$?
    assert_equal 1 "$status" "a refused power-off is a failure" || rc=1
    assert_contains "$out" "result=failed" || rc=1
    _mc_teardown
    return $rc
}

test_machine_boots_ubuntu_back_from_windows() {
    _mc_setup
    local rc=0 out status
    /usr/bin/sed -i '' 's/desktop-windows) echo ""/desktop-windows) echo "desktop-win"/' "$MACHINES_CONF"
    : > "$MC_TMP/up/desktop-win"
    out=$(_mc boot desktop ubuntu); status=$?
    assert_equal 0 "$status" || rc=1
    assert_contains "$(/bin/cat "$MC_TMP/ssh.log")" "desktop-win shutdown /r /t 0" "Windows restarts; Ubuntu is the default boot" || rc=1
    assert_contains "$out" "ubuntu up" || rc=1
    _mc_teardown
    return $rc
}

test_machine_runs_default_jobs_here() {
    _mc_setup
    local rc=0 out status
    out=$(_mc run local -- echo on-the-pipeline-host); status=$?
    assert_equal 0 "$status" || rc=1
    assert_equal "on-the-pipeline-host" "$out" || rc=1
    assert_equal "" "$(/bin/cat "$MC_TMP/ssh.log")" "no ssh for a local job" || rc=1
    _mc_teardown
    return $rc
}

test_machine_releases_an_idle_windows_desktop() {
    # With nobody signed in, `query user` says "No User exists" and exits 1.
    # That is the idle answer, and it must not read as someone being there.
    _mc_setup
    local rc=0 out status
    /usr/bin/sed -i '' 's/desktop-windows) echo ""/desktop-windows) echo "desktop-win"/' "$MACHINES_CONF"
    : > "$MC_TMP/up/desktop-win"
    out=$(_mc release desktop-windows); status=$?
    assert_equal 0 "$status" "an idle Windows desktop is powered off" || rc=1
    assert_contains "$(/bin/cat "$MC_TMP/ssh.log")" "desktop-win shutdown /s /t 0" || rc=1
    _mc_teardown
    return $rc
}

test_machine_keeps_a_signed_in_windows_desktop_on() {
    _mc_setup
    local rc=0 out status
    /usr/bin/sed -i '' 's/desktop-windows) echo ""/desktop-windows) echo "desktop-win"/' "$MACHINES_CONF"
    : > "$MC_TMP/up/desktop-win"
    printf ' USERNAME  SESSIONNAME  ID  STATE\n devwin     console       1  Active\n' > "$MC_TMP/who-desktop-win"
    out=$(_mc release desktop-windows); status=$?
    assert_equal 3 "$status" "a console session refuses the power-off" || rc=1
    assert_not_contains "$(/bin/cat "$MC_TMP/ssh.log")" "shutdown /s" || rc=1
    _mc_teardown
    return $rc
}
