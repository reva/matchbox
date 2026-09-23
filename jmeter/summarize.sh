#!/bin/sh
# Turn a JMeter .jtl into a printed summary and a row in history.csv.
#
# Reports HTTP latency and, separately, the server side validation time that
# matchbox puts in the OperationOutcome. Against a remote instance those differ
# by network time, and only the second says anything about the server.
#
# Samples labelled prepare-* (readiness, actuator probe, warmup) are excluded,
# and metrics-* samples contribute only the heap reading.
#
# Usage:  summarize.sh <run.jtl> <run-dir> <history.csv>
# Run metadata is read from the LT_* environment variables set by run.sh.
set -eu

JTL="$1"
OUT="$2"
HISTORY="$3"

[ -f "$JTL" ] || { echo "no jtl at $JTL" >&2; exit 2; }
mkdir -p "$OUT"

work="${TMPDIR:-/tmp}/summarize.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

# Split the jtl into one file per series plus a counters file. JMeter quotes
# fields that contain commas (the matchbox version banner does), so the columns
# cannot simply be split on commas.
awk -v work="$work" '
function csvsplit(line, arr,   i, n, c, field, inq) {
	n = 0; field = ""; inq = 0
	for (i = 1; i <= length(line); i++) {
		c = substr(line, i, 1)
		if (inq) {
			if (c == "\"") {
				if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ }
				else inq = 0
			} else field = field c
		} else {
			if (c == "\"") inq = 1
			else if (c == ",") { arr[++n] = field; field = "" }
			else field = field c
		}
	}
	arr[++n] = field
	return n
}
NR == 1 {
	n = csvsplit($0, head)
	for (i = 1; i <= n; i++) col[head[i]] = i
	next
}
{
	n = csvsplit($0, f)
	label = f[col["label"]]

	if (label ~ /^metrics-/) {
		mu = f[col["memoryused"]] + 0
		if (mu > heap) heap = mu
		next
	}
	if (label ~ /^prepare-/) {
		if (label == "prepare-readiness" && f[col["success"]] != "true") {
			readycode = f[col["responseCode"]]
			readymsg  = f[col["responseMessage"]]
		}
		next
	}

	total++
	if (f[col["success"]] != "true") failed++
	code = f[col["responseCode"]]
	codes[code]++

	e = f[col["elapsed"]] + 0
	if (e >= 0) print e > (work "/elapsed")

	v = f[col["validationms"]] + 0
	if (v >= 0) { print v > (work "/validation") }

	ts = f[col["timeStamp"]] + 0
	if (ts > 0) {
		if (first == 0 || ts < first) first = ts
		if (ts > last) last = ts
	}

	# The server reports a banner like "powered by matchbox 4.1.13, hapi-fhir
	# ...". Keep just the version so history.csv stays readable.
	mb = f[col["matchbox"]]
	if (mb != "" && mb != "---" && match(mb, /matchbox [^,]+/))
		versions[substr(mb, RSTART + 9, RLENGTH - 9)] = 1

	sid = f[col["sessionid"]]
	if (sid != "" && sid != "---") sessions[sid] = 1
}
END {
	vs = ""
	for (v in versions) vs = (vs == "" ? v : vs ";" v)
	cs = ""
	for (c in codes) cs = (cs == "" ? "" : cs ", ") c "=" codes[c]
	ns = 0
	for (s in sessions) ns++
	printf "total=%d\nfailed=%d\nfirst=%d\nlast=%d\nheap=%d\nversions=%s\ncodes=%s\nsessions=%d\nreadycode=%s\nreadymsg=%s\n", \
		total + 0, failed + 0, first + 0, last + 0, heap + 0, \
		(vs == "" ? "unknown" : vs), cs, ns, readycode, readymsg > (work "/counters")
}
' "$JTL"

# Declared here so the script still behaves under set -u if the awk pass above
# produced nothing, and so it is visible where these come from.
total=0; failed=0; first=0; last=0; heap=0
versions=unknown; codes=; sessions=0; readycode=; readymsg=
# shellcheck disable=SC1091  # generated above, not a checked-in file
. "$work/counters"

if [ "$total" -eq 0 ]; then
	if [ -n "$readycode" ]; then
		# Almost always this: readiness failed and stopped the test before any
		# load was sent. Say that rather than "no samples".
		echo "the target did not respond to GET /fhir/metadata, so the test stopped before sending any load:" >&2
		echo "  $readycode $readymsg" >&2
	else
		echo "no \$validate samples in the jtl" >&2
	fi
	exit 2
fi

# Nearest-rank percentile from a file of numbers, one per line.
pct() {
	f="$1"; p="$2"
	[ -s "$f" ] || { echo ""; return; }
	n=$(wc -l < "$f" | tr -d ' ')
	k=$(awk -v n="$n" -v p="$p" 'BEGIN { k = int(p * n / 100); if (k * 100 < p * n) k++; print (k < 1 ? 1 : k) }')
	sed -n "${k}p" "$f"
}

for series in elapsed validation; do
	[ -f "$work/$series" ] || : > "$work/$series"
	sort -n "$work/$series" > "$work/$series.sorted"
done

http_p50=$(pct "$work/elapsed.sorted" 50)
http_p95=$(pct "$work/elapsed.sorted" 95)
http_p99=$(pct "$work/elapsed.sorted" 99)
val_p50=$(pct "$work/validation.sorted" 50)
val_p95=$(pct "$work/validation.sorted" 95)
val_p99=$(pct "$work/validation.sorted" 99)
val_n=$(wc -l < "$work/validation.sorted" | tr -d ' ')

# Wall clock from the first to the last request start. A very short run can
# leave that at zero, so fall back to the slowest request.
read_stats=$(awk -v first="$first" -v last="$last" -v total="$total" -v failed="$failed" '
BEGIN {
	span = (last - first) / 1000
	if (span <= 0) span = 1
	printf "%.2f %.5f", total / span, (total ? failed / total : 0)
}')
rps=$(echo "$read_stats" | cut -d' ' -f1)
errrate=$(echo "$read_stats" | cut -d' ' -f2)

fmt() { [ -z "$1" ] && printf -- "-" || printf "%.0f" "$1"; }

printf '\n'
printf '  target            %s  (%s)\n' "${LT_TARGET:-}" "${LT_SCENARIO:-}"
printf '  matchbox          %s\n' "$versions"
printf '  samples           %s  (%s failed, %s%%)\n' "$total" "$failed" \
	"$(awk -v r="$errrate" 'BEGIN { printf "%.2f", r * 100 }')"
printf '  throughput        %s req/s   (requested %s/s)\n' "$rps" "${LT_RATE:--}"
printf '  http ms           p50 %s   p95 %s   p99 %s\n' "$(fmt "$http_p50")" "$(fmt "$http_p95")" "$(fmt "$http_p99")"
if [ "$val_n" -gt 0 ]; then
	printf '  validation ms     p50 %s   p95 %s   p99 %s    <- server side\n' \
		"$(fmt "$val_p50")" "$(fmt "$val_p95")" "$(fmt "$val_p99")"
else
	printf '  validation ms     not reported by the server\n'
fi
[ "$heap" -gt 0 ] && printf '  heap peak         %s GiB\n' \
	"$(awk -v h="$heap" 'BEGIN { printf "%.2f", h / 1073741824 }')"
printf '  response codes    %s\n' "$codes"
# One engine for the whole run is the healthy case. More than one means engines
# are being built per request, which is expensive and happens under a lock.
[ "$sessions" -gt 1 ] && printf '  engines used      %s  (expected 1, engines are being rebuilt)\n' "$sessions"
printf '\n'

if [ ! -f "$HISTORY" ]; then
	mkdir -p "$(dirname "$HISTORY")"
	printf 'timestamp,target,scenario,profile_key,matchbox_version,ig_version,java_opts,cpus,threads,requested_rate_per_s,duration_s,samples,failed,error_rate,achieved_rps,http_p50,http_p95,http_p99,validation_p50,validation_p95,validation_p99,heap_bytes_peak,run_dir\n' > "$HISTORY"
fi

# java_opts contains spaces and commas, so quote it.
printf '%s,%s,%s,%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
	"${LT_TIMESTAMP:-}" "${LT_TARGET:-}" "${LT_SCENARIO:-}" "${LT_PROFILE_KEY:-}" \
	"$versions" "${LT_IG_VERSION:-}" "${LT_JAVA_OPTS:-}" "${LT_CPUS:-}" \
	"${LT_THREADS:-}" "${LT_RATE:-}" "${LT_DURATION:-}" \
	"$total" "$failed" "$errrate" "$rps" \
	"$http_p50" "$http_p95" "$http_p99" \
	"$val_p50" "$val_p95" "$val_p99" \
	"$heap" "$(basename "$OUT")" >> "$HISTORY"
