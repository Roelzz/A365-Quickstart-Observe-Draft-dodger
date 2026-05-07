#!/usr/bin/env bash
# Query the Microsoft Purview Audit log for Draft Dodger telemetry.
#
# Uses a persistent pwsh background process so you only sign in once per
# laptop session. State files live in /tmp:
#   /tmp/eo_session.log         pwsh + Connect-ExchangeOnline output
#   /tmp/eo_session.pwsh.pid    pwsh PID, used to reuse the session
#   /tmp/eo_loop.ps1            polling loop the pwsh process runs
#   /tmp/eo_query.ps1           per-invocation query body
#   /tmp/eo_signal              marker file the loop polls every 300 ms
#
# First invocation prints a device-code URL + code. Sign in once, then
# every subsequent invocation skips auth entirely (until reboot or
# pkill -f eo_loop).
#
# Every row returned by Search-UnifiedAuditLog is also persisted to a
# JSONL file under ./audit-results/ (override with OUTPUT_DIR=...)
# named "<UTC-stamp>-<sanitised-query>.jsonl". Each line is one JSON
# object with the PowerShell row envelope plus the AuditData JSON
# parsed inline at "AuditData", so you can grep/jq directly.
#
# Usage:
#   scripts/query-audit.sh                                       # last 1d, default GUID
#   scripts/query-audit.sh "Draft Dodger" 7                      # 7-day search by name
#   scripts/query-audit.sh fc3ad290-1d0e-491e-aca7-d09fc89ad656 3  # 3-day search by GUID
#   OUTPUT_DIR=/tmp scripts/query-audit.sh                       # custom output directory

set -euo pipefail

LOG=/tmp/eo_session.log
PID_FILE=/tmp/eo_session.pwsh.pid
LOOP_SCRIPT=/tmp/eo_loop.ps1
QUERY_FILE=/tmp/eo_query.ps1
SIGNAL_FILE=/tmp/eo_signal
QUERY="${1:-fc3ad290-1d0e-491e-aca7-d09fc89ad656}"
DAYS="${2:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/audit-results}"
mkdir -p "$OUTPUT_DIR"
TS=$(date +%Y%m%d-%H%M%S)
SAFE_QUERY=$(printf '%s' "$QUERY" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-40)
OUT_PATH="$OUTPUT_DIR/$TS-$SAFE_QUERY.jsonl"

start_session() {
    cat > "$LOOP_SCRIPT" <<'PWSH'
$ErrorActionPreference = 'Continue'
Import-Module ExchangeOnlineManagement
Write-Host '===CONNECTING==='
Connect-ExchangeOnline -Device -ShowBanner:$false
Write-Host '===CONNECTED==='
while ($true) {
    if (Test-Path '/tmp/eo_signal') {
        Remove-Item '/tmp/eo_signal' -Force
        Write-Host ('===QUERY_START ' + (Get-Date -Format o) + '===')
        try { . '/tmp/eo_query.ps1' } catch { Write-Host ('QUERY_ERROR: ' + $_.Exception.Message) }
        Write-Host '===QUERY_END==='
    }
    Start-Sleep -Milliseconds 300
}
PWSH
    nohup pwsh -NoLogo -NoProfile -File "$LOOP_SCRIPT" > "$LOG" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 5
    if grep -q "https://login" "$LOG"; then
        echo ""
        echo "=== First run — sign in to keep the session alive ==="
        grep "https://login" "$LOG" | tail -1
        echo ""
        echo "Waiting for connection (up to 5 min)..."
        local waited=0
        until grep -q "===CONNECTED===" "$LOG"; do
            sleep 3
            waited=$((waited + 3))
            if [ $waited -gt 300 ]; then
                echo "Timed out waiting for sign-in." >&2
                exit 1
            fi
        done
        echo "Connected."
    fi
}

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    : # session alive
else
    rm -f "$PID_FILE"
    start_session
fi

cat > "$QUERY_FILE" <<EOF
\$q = '$QUERY'
\$d = $DAYS
\$outPath = '$OUT_PATH'
Write-Host ("Audit search: '" + \$q + "', last " + \$d + " day(s)")
\$r = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-\$d) -EndDate (Get-Date) -FreeText \$q -ResultSize 5000
Write-Host ("rows: " + \$r.Count)
if (\$r.Count -gt 0) {
    \$r | Group-Object RecordType | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize | Out-String | Write-Host
    \$r | Select-Object -First 10 | Format-Table CreationDate, RecordType, Operations, UserIds -AutoSize | Out-String | Write-Host
    Write-Host '--- Sample AuditData (first row) ---'
    \$r | Select-Object -First 1 | ForEach-Object { Write-Host \$_.AuditData }

    # Persist every row to a JSONL file: PowerShell envelope + parsed AuditData inline
    \$lines = \$r | ForEach-Object {
        \$parsed = \$null
        if (\$_.AuditData) { try { \$parsed = \$_.AuditData | ConvertFrom-Json } catch { \$parsed = \$_.AuditData } }
        [pscustomobject]@{
            CreationDate = \$_.CreationDate
            RecordType   = \$_.RecordType.ToString()
            Operations   = \$_.Operations
            UserIds      = \$_.UserIds
            ResultIndex  = \$_.ResultIndex
            ResultCount  = \$_.ResultCount
            Identity     = \$_.Identity
            AuditData    = \$parsed
        } | ConvertTo-Json -Depth 12 -Compress
    }
    \$lines | Out-File -Encoding utf8 \$outPath
    Write-Host ('Wrote ' + \$r.Count + ' rows to ' + \$outPath)
}
EOF

SIZE_BEFORE=$(wc -c < "$LOG")
touch "$SIGNAL_FILE"

# Wait up to 90s for the query to complete
for _ in $(seq 1 90); do
    NEW=$(tail -c +$((SIZE_BEFORE + 1)) "$LOG" 2>/dev/null || true)
    if printf '%s' "$NEW" | grep -q "===QUERY_END==="; then
        printf '%s\n' "$NEW" | awk '/===QUERY_START/,/===QUERY_END===/'
        exit 0
    fi
    sleep 1
done
echo "Timed out waiting for query result. Last 50 log lines:"
tail -50 "$LOG"
exit 1
