#!/bin/bash
# Counts to 100, printing a number every 4 seconds with a timestamp.
# If the Mac sleeps, the next line shows the gap, e.g. "(gap: 182s)".
last=$(date +%s)
for i in $(seq 1 100); do
    now=$(date +%s)
    gap=$((now - last))
    note=""
    [ "$i" -gt 1 ] && [ "$gap" -gt 6 ] && note="  (gap: ${gap}s)"
    echo "$(date +%H:%M:%S)  $i$note"
    last=$now
    if [ "$i" -lt 100 ]; then sleep 4; fi
done
