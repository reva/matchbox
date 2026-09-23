# Evidence for the findings in ../readme.md

Committed so the numbers in the parent readme can be checked rather than taken
on trust. Ordinary run output stays gitignored; only this curated set is kept.

| File | What it is |
|------|------------|
| `2026-09-23-gc-and-cpu-scaling.csv` | `history.csv` rows for every unthrottled run behind the findings table, including the CPU scaling sweep and every GC configuration |
| `gc-g1.log` | `-Xlog:gc` from a G1 run, default `txServerCache` |
| `gc-parallelgc.log` | the same run with ParallelGC |
| `gc-g1-txcache-off.log` | G1 with `txServerCache=false` |
| `gc-parallelgc-txcache-off.log` | ParallelGC with `txServerCache=false` |

The JMeter HTML reports are not committed, they are tens of megabytes per run.
Regenerate any row with the command in the parent readme; each run writes its
own report under `results/`.

Pause statistics quoted in the parent readme were taken over the load window
only, excluding startup, which is allocation heavy and would otherwise dominate
the totals. The window is the last 95 seconds of each log:

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

Hardware: Apple silicon, 10 cores, Docker given 10 CPUs and 16 GiB. The load
generator runs on the same machine as the server, so absolute numbers are not
production figures. The comparisons between configurations are the useful part.

## Which run is which

`params` records the extra query string, but it was added after these runs, so
the `txServerCache` comparison is identified by timestamp instead:

| Timestamp | Configuration |
|-----------|---------------|
| `20260923T074548Z` | G1, default `txServerCache` |
| `20260923T074948Z` | ParallelGC, default `txServerCache` |
| `20260923T075515Z` | G1, `txServerCache=false` |
| `20260923T080014Z` | ParallelGC, `txServerCache=false` |

The four rows before those, at `20260923T0641`–`0701`, are the three G1 and
three ParallelGC repeats that the non-overlapping ranges are based on, and
`20260923T071048Z` is the ZGC probe. The CPU scaling sweep from 1 to 8 cores
used `docker update` against one container and so is not in this file; it is
quoted in the parent readme and is reproducible with `CPUS=n ./run.sh`.
