#!/usr/bin/env bash
# Slack notification helper for CI results.
# Source this file after common.sh; do not execute directly.
#
# Requires SLACK_WEBHOOK_URL or SLACK_BOT_TOKEN + SLACK_CHANNEL.
# For DMs: set SLACK_BOT_TOKEN and SLACK_CHANNEL to your Slack user ID (e.g. U01ABCDEF).

slack_post() {
    local text="$1"
    local thread_ts="${2:-}"

    if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
        _slack_post_webhook "${text}" "${thread_ts}"
    elif [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
        _slack_post_api "${text}" "${thread_ts}"
    else
        log_warn "No Slack credentials configured. Set SLACK_WEBHOOK_URL or SLACK_BOT_TOKEN."
        echo "${text}"
        return 0
    fi
}

slack_post_file() {
    local filepath="$1"
    local title="${2:-diagnostic bundle}"
    local thread_ts="${3:-}"

    if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
        local channel="${SLACK_CHANNEL:?SLACK_CHANNEL required for file uploads}"
        local args=(-F "file=@${filepath}" -F "channels=${channel}" -F "title=${title}")
        [[ -n "${thread_ts}" ]] && args+=(-F "thread_ts=${thread_ts}")
        curl -s -X POST "https://slack.com/api/files.upload" \
            -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
            "${args[@]}" >/dev/null 2>&1
    else
        log_warn "File upload requires SLACK_BOT_TOKEN. Posting content inline."
        local content
        content=$(head -c 3000 "${filepath}")
        slack_post "\`\`\`${content}\`\`\`" "${thread_ts}"
    fi
}

_slack_post_webhook() {
    local text="$1"
    local payload
    payload=$(python3 -c "import json,sys; print(json.dumps({'text': sys.stdin.read()}))" <<< "${text}")
    curl -sf -X POST "${SLACK_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "${payload}" >/dev/null 2>&1 || log_warn "Slack webhook post failed"
}

_slack_post_api() {
    local text="$1"
    local thread_ts="${2:-}"
    local channel="${SLACK_CHANNEL:?SLACK_CHANNEL required}"
    local payload
    payload=$(python3 -c "
import json, sys
channel = sys.argv[1]
thread_ts = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
d = {'channel': channel, 'text': sys.stdin.read()}
if thread_ts:
    d['thread_ts'] = thread_ts
print(json.dumps(d))
" "${channel}" "${thread_ts}" <<< "${text}")
    curl -sf -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>/dev/null || log_warn "Slack API post failed"
}

send_email() {
    local subject="$1"
    local body="$2"
    local to="${CI_EMAIL_TO:-}"
    local from="${CI_EMAIL_FROM:-agent-sandbox-ci@redhat.com}"
    local smtp="${CI_SMTP_SERVER:-smtp.corp.redhat.com}"
    local smtp_port="${CI_SMTP_PORT:-25}"

    if [[ -z "${to}" ]]; then
        log_warn "CI_EMAIL_TO not set, skipping email notification"
        return 0
    fi

    python3 -c "
import smtplib, sys
from email.mime.text import MIMEText
msg = MIMEText(sys.stdin.read(), 'plain', 'utf-8')
msg['Subject'] = sys.argv[1]
msg['From'] = sys.argv[2]
msg['To'] = sys.argv[3]
try:
    with smtplib.SMTP(sys.argv[4], int(sys.argv[5]), timeout=10) as s:
        s.sendmail(sys.argv[2], [sys.argv[3]], msg.as_string())
    print('Email sent', file=sys.stderr)
except Exception as e:
    print(f'Email failed: {e}', file=sys.stderr)
" "${subject}" "${from}" "${to}" "${smtp}" "${smtp_port}" <<< "${body}" 2>&1 | while read -r line; do log_info "${line}"; done
}

notify_success() {
    local total_tests="$1"
    local duration="$2"
    local stack_info="$3"

    local msg="*Nightly CI passed* -- ${total_tests} tests in ${duration}
Cluster: virtlab725 | ${stack_info}"
    slack_post "${msg}"
    send_email "Agent Sandbox CI: PASS ${total_tests}" "${msg}"
}

notify_failure() {
    local passed="$1"
    local failed="$2"
    local total="$3"
    local duration="$4"
    local stack_info="$5"
    local failed_tests="$6"
    local diagnostic_file="${7:-}"

    local msg="*Nightly CI failed* -- ${passed}/${total} passed, ${failed} failed in ${duration}
Failed tests:
${failed_tests}
Cluster: virtlab725 | ${stack_info}"

    local response
    response=$(slack_post "${msg}")
    local thread_ts
    thread_ts=$(echo "${response}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null || true)

    if [[ -n "${diagnostic_file}" && -f "${diagnostic_file}" ]]; then
        slack_post_file "${diagnostic_file}" "Diagnostic bundle" "${thread_ts}"
    fi

    local email_body="${msg}"
    if [[ -n "${diagnostic_file}" && -f "${diagnostic_file}" ]]; then
        email_body+="

--- Diagnostic Bundle ---
$(head -c 50000 "${diagnostic_file}")"
    fi
    send_email "Agent Sandbox CI: FAIL ${failed}/${total}" "${email_body}"
}
