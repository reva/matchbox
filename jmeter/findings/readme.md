# Evidence for the findings in ../readme.md

`2026-09-23-gc-and-cpu-scaling.csv` holds the `history.csv` rows behind every
number quoted in the parent readme: the repeated G1 and ParallelGC runs, the ZGC
probe, the heap size comparison and the `txServerCache` comparison. It is kept
so the numbers can be checked rather than taken on trust. Ordinary run output
stays gitignored.

The schema is one column short of what `summarize.sh` writes today: `params` was
added after these runs. Nothing else has moved.

Hardware: Apple silicon, 10 cores, Docker given 10 CPUs and 16 GiB. The load
generator runs on the same machine as the server, so absolute numbers are not
production figures. The comparisons between configurations are the useful part.

## Which run is which

| Timestamp | Configuration |
|-----------|---------------|
| `20260923T0624`–`0632` | the CPU and heap size comparisons |
| `20260923T0636`–`0718` | the G1 and ParallelGC repeats the ranges are based on |
| `20260923T071048Z` | the ZGC probe |
| `20260923T074548Z` | G1, default `txServerCache` |
| `20260923T074948Z` | ParallelGC, default `txServerCache` |
| `20260923T075515Z` | G1, `txServerCache=false` |
| `20260923T080014Z` | ParallelGC, `txServerCache=false` |

The CPU scaling sweep from 1 to 8 cores used `docker update` against a single
container and so is not in this file. It is reproducible with `CPUS=n ./run.sh`.

## Reproducing the GC pause table

The raw `-Xlog:gc` output is not committed; it is tens of thousands of lines per
run and regenerating it takes five minutes:

```bash
JAVA_OPTS="-Xmx4g -Xms4g -XX:+UseG1GC -Xlog:gc" \
  ./run.sh --target local --scenario steady --rate 0 --duration 90 --keep-up
docker logs matchbox-loadtest > gc-g1.log
```

Pause statistics are taken over the load window only, excluding startup, which
is allocation heavy and would otherwise dominate the totals. The window is the
last 95 seconds of the log:

```sh
end=$(awk -F'[][]' '/Pause/{t=$2+0} END{print t}' gc-g1.log)
awk -F'[][]' -v s="$((${end%.*}-95))" '
  { t = $2 + 0 }
  t >= s && /Pause/ {
    if (match($0, /[0-9.]+ms$/)) { d = substr($0, RSTART, RLENGTH-2)+0; n++; tot += d; if (d>mx) mx=d }
    if (/Pause Full/) full++
  }
  END { printf "%d collections (%d full), %.0f ms total, %.1f ms max\n", n, full+0, tot, mx }
' gc-g1.log
```

The JMeter HTML reports are not committed either, at tens of megabytes per run.
Each run writes its own under `results/`.
