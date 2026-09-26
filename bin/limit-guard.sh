#!/bin/bash
# PreToolUse guard: once the 5-hour usage reaches 95% or the weekly usage
# reaches 99%, every tool call is denied with instructions to stop and
# schedule a resume one minute after the reset.
#
# Source: the usage cache shared with the status line, refreshed here through
# ~/.claude/usage-refresh.sh when it is over a minute old. A cache older than
# max_age, or a window whose reset has already passed, never blocks: stale
# data must not lock the session out.
#
# Thresholds: "limit_5h" and "limit_week" in ~/.claude/statusline.json
# (95 and 99 by default); set them with /limits.
# Mode: "limit_guard" in ~/.claude/statusline.json. true (the default) blocks;
# "low" blocks nothing and instead asks the user, once per session and reset
# window, to run /low-priority, which only the user can switch on; false is
# off. Emergency switch: touch /tmp/claude/limit-guard-off

cache="/tmp/claude/statusline-usage-cache.json"
max_age=600
five_limit=95
seven_limit=99

input=$(cat)
[ -f /tmp/claude/limit-guard-off ] && exit 0

config="$HOME/.claude/statusline.json"
if [ -f "$config" ]; then
    {
        read -r cfg_guard
        read -r cfg_five
        read -r cfg_seven
    } < <(jq -r '
        (if .limit_guard == false then "off" elif .limit_guard == "low" then "low" else "on" end),
        (.limit_5h // "" | if type == "number" and . >= 1 and . <= 100 then floor else "" end),
        (.limit_week // "" | if type == "number" and . >= 1 and . <= 100 then floor else "" end)
    ' "$config" 2>/dev/null)
    [ "$cfg_guard" = "off" ] && exit 0
    case "$cfg_five" in ''|*[!0-9]*) : ;; *) five_limit=$cfg_five ;; esac
    case "$cfg_seven" in ''|*[!0-9]*) : ;; *) seven_limit=$cfg_seven ;; esac
fi

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
# The tools needed to carry out the instruction itself stay allowed.
# ToolSearch among them: CronCreate may be a deferred tool whose schema has
# to be loaded before it can be called.
case "$tool" in
    ToolSearch|CronCreate|CronList|CronDelete|TaskStop|ScheduleWakeup|AskUserQuestion) exit 0 ;;
esac

# Bring the cache up to date before judging it. Left to the status line, it
# is refreshed only on renders, so the reading can be about 90s old; asked
# here, it is at most a minute old. The same lock and 429 backoff apply, so
# the endpoint still sees at most one request a minute.
[ -f "$HOME/.claude/usage-refresh.sh" ] && . "$HOME/.claude/usage-refresh.sh" >/dev/null 2>&1
[ -f "$cache" ] || exit 0

now=$(date +%s)
mtime=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null)
case "$mtime" in ''|*[!0-9]*) exit 0 ;; esac
[ $(( now - mtime )) -gt "$max_age" ] && exit 0

# One line per window over its limit: "<name> <pct> <reset epoch>".
over=$(jq -r --argjson now "$now" --argjson f "$five_limit" --argjson s "$seven_limit" '
    def epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
    [["5h", .five_hour, $f], ["weekly", .seven_day, $s]][]
    | select((.[1] | type) == "object" and (.[1].resets_at | type) == "string")
    | (.[1].resets_at | epoch) as $r
    | select($r > $now and (.[1].utilization // 0) >= .[2])
    | "\(.[0]) \(.[1].utilization | round) \($r)"
' "$cache" 2>/dev/null)
[ -n "$over" ] || exit 0

# Resume after the latest reset among the exceeded windows.
latest=0; summary=""
while read -r name pct reset; do
    [ "$reset" -gt "$latest" ] && latest=$reset
    summary+="${summary:+, }$name ${pct}% (reset $(date -d "@$reset" '+%d.%m %H:%M'))"
done <<< "$over"
# At least a minute after the reset, rounded up to a whole minute: cron has
# minute resolution, and rounding down can land on the reset itself. A
# one-shot CronCreate job on :00 or :30 may fire up to 90s early (seen here:
# reset 02:29:59, job "30 2" fired at 02:28:34 and hit the limit), so those
# two minutes are skipped.
resume=$(( (latest + 60 + 59) / 60 * 60 ))
case "$(date -d "@$resume" '+%M')" in 00|30) resume=$(( resume + 60 )) ;; esac
resume_hm=$(date -d "@$resume" '+%d.%m %H:%M')
cron_expr=$(date -d "@$resume" '+%-M %-H %-d %-m *')

reason="USAGE LIMIT GUARD: $summary. Stop all work now.
- If you are a subagent: do nothing else, end immediately and report that you stopped on the usage limit guard.
- If you are the main session: stop running agents (TaskStop), then call CronCreate with cron \"$cron_expr\" (local time $resume_hm, one minute after the reset) and a prompt that resumes the interrupted task from where it stopped. Then tell the user, in Russian, that work is paused until $resume_hm and why. Make no other tool calls."

# One line per guarded call, to see afterwards which sessions and agents ran
# into the guard and when: local time, mode, levels, session, agent, cwd, tool.
guard_log="$HOME/.claude/limit-guard.log"
log_guard() {
printf '%s\n' "$input" | jq -r --arg t "$(date '+%F %T')" --arg m "$1" --arg s "$summary" --arg r "$resume_hm" '
    [$t, $m, $s, "resume " + $r, "session=" + (.session_id // "?"),
     "agent=" + (.agent_type // .agent_id // "main"), "cwd=" + (.cwd // "?"), "tool=" + (.tool_name // "?")]
    | join("\t")' >> "$guard_log" 2>/dev/null
if [ "$(wc -l < "$guard_log" 2>/dev/null)" -gt 5000 ] 2>/dev/null; then
    tail -n 2500 "$guard_log" > "$guard_log.$$" 2>/dev/null && mv -f "$guard_log.$$" "$guard_log"
fi
}

# "low": the call goes ahead. The user is shown the notice once per session
# and reset window; hooks cannot run slash commands, so /low-priority stays
# the user's to type.
if [ "$cfg_guard" = "low" ]; then
    session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -dc 'A-Za-z0-9-')
    marker="/tmp/claude/limit-guard-low/${session:-unknown}-$latest"
    [ -f "$marker" ] && exit 0
    mkdir -p /tmp/claude/limit-guard-low 2>/dev/null && : > "$marker"
    log_guard "notify-low"
    jq -n --arg m "Лимит использования: $summary. Работа продолжается. Чтобы не упереться в лимит, запустите /low-priority." '{systemMessage: $m}'
    exit 0
fi

log_guard "deny"

jq -n --arg r "$reason" '{
    hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
    }
}'
