# Tests for refresh-wake-schedule.sh's derive_wake_times.
#
# The wake queue used to be a hardcoded 03:55/17:55 pair. That was correct
# only while every routine lived on one Mac: when daily-summary moved to the
# M2, the M4 kept waking at 17:55 for nothing and had no wake before its
# 19:00 review nudge. These tests pin the derived behaviour.

_wake_fixture_dir() {
    local dir="$TEST_TMP/agents" ; /bin/mkdir -p "$dir"
    local label
    while [ $# -gt 0 ]; do
        label="r$1$2"
        /bin/cat > "$dir/com.agentic-skills.routines.$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.agentic-skills.routines.$label</string>
  <key>ProgramArguments</key><array><string>/bin/true</string><string>$label</string></array>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>$1</integer><key>Minute</key><integer>$2</integer>
  </dict></dict></plist>
EOF
        shift 2
    done
    echo "$dir"
}

_derive() {
    local fn="$TEST_TMP/derive.sh"
    /usr/bin/sed -n '/^ROUTINE_PLIST_DIR=/,/^}$/p' \
        "$RUNTIME_DIR/system/refresh-wake-schedule.sh" > "$fn"
    echo 'derive_wake_times' >> "$fn"
    ROUTINE_PLIST_DIR="$1" /bin/bash "$fn"
}

test_wake_times_collapse_a_cluster_into_one() {
    setup_run_env
    local rc=0 dir out
    # The real M4 morning batch: four routines inside ten minutes.
    dir=$(_wake_fixture_dir 4 0 4 2 4 5 4 10)
    out=$(_derive "$dir")
    assert_equal "03:50:00" "$out" "four clustered routines yield exactly one wake" || rc=1
    teardown_run_env
    return $rc
}

test_wake_times_cover_a_distant_routine() {
    setup_run_env
    local rc=0 dir out
    # Morning batch plus an evening routine — the gap that went uncovered.
    dir=$(_wake_fixture_dir 4 0 4 10 19 0)
    out=$(_derive "$dir" | /usr/bin/tr '\n' ' ')
    assert_equal "03:50:00 18:50:00 " "$out" "a distant routine gets its own wake" || rc=1
    teardown_run_env
    return $rc
}

test_wake_times_are_empty_without_routines() {
    setup_run_env
    local rc=0 dir out
    dir="$TEST_TMP/empty"; /bin/mkdir -p "$dir"
    out=$(_derive "$dir")
    if [ -n "$out" ]; then
        echo "  FAIL: expected no wake times with no routines installed, got '$out'"
        rc=1
    fi
    teardown_run_env
    return $rc
}

test_wake_times_wrap_before_midnight() {
    setup_run_env
    local rc=0 dir out
    # 00:05 minus a 10-minute lead must wrap to 23:55, not go negative.
    dir=$(_wake_fixture_dir 0 5)
    out=$(_derive "$dir")
    assert_equal "23:55:00" "$out" "a routine just after midnight wraps correctly" || rc=1
    teardown_run_env
    return $rc
}

test_wake_times_cover_a_routine_with_several_weekdays() {
    setup_run_env
    local rc=0 dir out
    # playtest-build-night: Monday, Wednesday and Friday at 09:00, an array StartCalendarInterval.
    dir=$(_wake_fixture_dir 4 0)
    /bin/cat > "$dir/com.agentic-skills.routines.weekdays.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.agentic-skills.routines.weekdays</string>
  <key>StartCalendarInterval</key><array>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  </array></dict></plist>
EOF
    out=$(_derive "$dir" | /usr/bin/tr '\n' ' ')
    assert_equal "03:50:00 08:50:00 " "$out" "an array schedule gets its wake" || rc=1
    teardown_run_env
    return $rc
}
