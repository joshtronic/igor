#!/usr/bin/env bash
# datetime.sh -- shared "yesterday" helper (igor#34).
#
# `date -d yesterday` and `date -d '-1 days'` mean "now minus 24 hours,"
# not "the previous calendar day." On a DST fall-back day (25 real hours)
# that reads wrong late in the evening: at 23:xx CST on 2026-11-01, now
# minus 24h lands at 00:xx CDT on 2026-11-01 itself -- "yesterday" comes
# back as TODAY. logwatch and emailwatch then reviewed an empty window and
# filed false no-output alarms (igor#31, #32, #33, stonks#7, #8).
#
# Anchoring on noon instead of "now" sidesteps this: noon is never the
# repeated fall-back hour nor the skipped spring-forward hour, so the
# calendar subtraction is unambiguous either way.
yesterday_date() {
  date -d "$(date +%F) 12:00 yesterday" +%F 2>/dev/null || date -v-1d -v12H +%F
}
