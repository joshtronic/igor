def fabs: if . < 0 then -. else . end;
def fmt_usd: if . == null then "?" else (. as $v | (($v*100|round)/100) | tostring) end;
def fmt_dur: if . == null then "?" else
    (. as $s | ($s|floor) as $secs
     | if $secs < 60 then "\($secs)s"
       else "\($secs/60|floor)m\($secs%60)s" end)
  end;
if has("metrics") then
  "-- COST & TIMING (24h) --",
  (if .metrics.cost.now.has_data then
     "  spend: $" + (.metrics.cost.now.total_usd|fmt_usd)
     + (if .metrics.cost.delta_usd == null then " (no prior-period data to compare)"
        else (if .metrics.cost.delta_usd >= 0 then " (+$" else " (-$" end)
             + ((.metrics.cost.delta_usd|fabs)|fmt_usd) + " vs prior 24h)" end)
   else "  no cost data recorded" end),
  (.metrics.cost.now.by_site[]? | "    " + .site + ": $" + (.usd|fmt_usd)),
  (if .metrics.timing.now.has_data then
     "  ticks: " + (.metrics.timing.now.count|tostring) + " (median " + (.metrics.timing.now.median_s|fmt_dur)
     + ", p90 " + (.metrics.timing.now.p90_s|fmt_dur) + ", longest " + (.metrics.timing.now.max_s|fmt_dur) + ")"
     + (if .metrics.timing.delta_median_s == null then ""
        else (if .metrics.timing.delta_median_s >= 0 then " (median +" else " (median -" end)
             + ((.metrics.timing.delta_median_s|fabs)|fmt_dur) + " vs prior 24h)" end)
   else "  no tick-timing data recorded" end)
else empty end
