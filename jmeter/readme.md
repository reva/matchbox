# Load testing matchbox

Measures `$validate` throughput and latency against a matchbox built from this
working tree, the published `matchbox-ch-elm` image, or an instance you did not
start. The point is a tuning loop: change one thing, rerun the same command,
compare rows in `results/history.csv`.

CH ELM is the workload because it is a realistic, profile-heavy validation whose
example resources ship with the IG. Nothing here is specific to it beyond the
corpus and the profile URLs in `extract-payloads.sh`.

## Quick start

```bash
cd jmeter
./run.sh --target released --scenario smoke
```

Pulls the published image, waits for it to load the IG, warms it up, runs for 30
seconds and prints a summary. No JMeter installation needed: without `jmeter` on
`PATH` or `JMETER_HOME` set, the run happens in a container.

To measure your own changes:

```bash
./run.sh --target local --scenario steady --rate 5 --duration 5m --build
```

## What you get

```
  target            released  (smoke)
  matchbox          4.1.16
  samples           46  (0 failed, 0.00%)
  throughput        1.03 req/s   (requested 1/s)
  http ms           p50 505   p95 745   p99 1093
  validation ms     p50 478   p95 706   p99 1084    <- server side
  heap peak         3.78 GiB
  process cpu       mean 19%   peak 39%   <- of the JVM's visible cpus
  response codes    200=46
```

**Two latencies, because they answer different questions.** `http ms` is the
round trip as the client sees it. `validation ms` is what matchbox reports in
the OperationOutcome (`$.issue[0].extension[0].extension[?(@.url ==
'total')].valueDuration.value`). Against localhost they agree; against a remote
instance they diverge by network and TLS time, and only the second says anything
about the server. Optimise against that one.

**`process cpu` answers the first question about any ceiling**: whether the
server is CPU bound. Near 100% means a faster collector or more cores will help.
Well under it means the ceiling is elsewhere and JVM tuning will not move it. A
saturated 4 CPU container reads 85% mean, 99% peak on this workload. Both this
and `heap peak` come from actuator, sampled every 5 seconds; when actuator is
unreachable the line says so rather than disappearing.

Each run writes `results/<timestamp>-<target>-<scenario>/` with the raw `.jtl`,
the JMeter HTML report and `jmeter.log`, and appends a row to
`results/history.csv`. That file is the tuning log: it records `java_opts`,
`cpus`, `threads`, the requested rate, the IG version and the matchbox version
next to the results, so runs stay comparable.

## Targets

A target is an env file in `targets/`. `--target NAME` resolves
`targets/NAME.env`; a path also works.

The file is sourced, so what it sets acts as a default for that target.
Precedence is **command line, then target file, then scenario default.**

| Target | What it is | Tunable |
|---|---|---|
| `local` | built from this working tree, CH ELM loaded | yes |
| `released` | the published `matchbox-ch-elm` image | heap and cpu only |
| your own | an instance you did not start | no |

`local` and `released` are started and stopped by `run.sh` through
`compose/docker-compose.yml`. Both publish `http://localhost:8080/matchboxv3`,
so the test does not care which is up. Use `PORT=8081` if 8080 is busy.

`local` needs `matchbox-server/target/matchbox.jar`. `run.sh` builds it with
`mvn -DskipTests package` if missing; `--build` forces a rebuild. The Angular
frontend is not part of that build.

### Tuning the local target

Edit `targets/local.env`, or override per run, which is how you sweep one knob:

```bash
CPUS=8 ./run.sh --target local --scenario steady --rate 0
```

`JAVA_OPTS`, `CPUS` and `MEM_LIMIT` all work that way. `cpus` is pinned so
results are comparable across machines and so core scaling is measurable.

Matchbox caches the IG dependency tree it downloads from packages2.fhir.org in
its H2 database, kept in a named volume between runs. The first run of a target
pays that download; `--fresh` drops it when you want a genuine cold start.

`JAVA_OPTS` is this harness's name for the flags under test, whichever image is
running. The server image takes them through `JDK_JAVA_OPTIONS`, which the java
launcher reads by itself, so `local` needs no entrypoint override; setting it
replaces the image defaults (`-XX:MaxRAMPercentage=70`,
`-XX:+ExitOnOutOfMemoryError`, `-XX:+UseStringDeduplication`) so a run measures
exactly the flags you gave it. The `released` image predates all of that, so
`compose/docker-compose.yml` still replaces its entrypoint.

## Measuring an instance you did not start

```bash
cp targets/remote.env.example targets/prod.private.env
./run.sh --target targets/prod.private.env --scenario smoke --rate 1
```

`*.private.env` and `certs/` are gitignored.

Read this first:

- **You are adding load to something probably serving real traffic.** `run.sh`
  refuses `ramp`, `--rate 0` and any rate above 2/s against a non-localhost host
  unless you pass `--i-know-this-is-a-real-instance`. That flag is the whole
  safety mechanism.
- **You do not control warmup.** The instance may be cold, warm for a week, or
  behind a load balancer spreading requests over pods in different states.
- **Other traffic is in your numbers**, and yours is in theirs. Results from a
  shared instance are not comparable with local runs.
- **`/actuator` is usually blocked**, so `heap peak` and `process cpu` will say
  they were not sampled, naming the URL and response code. `--metrics on` forces
  the attempt anyway.

### Mutual TLS

Set these in the target file. Paths are relative to `jmeter/` and must stay
inside it, because JMeter runs in a container that mounts only this directory.

```sh
CLIENT_CERT=certs/client.p12
CLIENT_CERT_PASSWORD=...
CLIENT_CERT_TYPE=PKCS12

CA_TRUSTSTORE=certs/truststore.p12
CA_TRUSTSTORE_PASSWORD=...
CA_TRUSTSTORE_TYPE=PKCS12
```

The truststore is only needed when the server certificate comes from a private
CA; without it the handshake fails with a PKIX path error.

```bash
openssl pkcs12 -export -inkey client.key -in client.crt \
  -out certs/client.p12 -name client \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

keytool -importcert -noprompt -alias ca -file ca.pem \
  -keystore certs/truststore.p12 -storetype PKCS12 -storepass changeit
```

The `-keypbe`/`-certpbe`/`-macalg` arguments matter. OpenSSL 3 defaults to PBES2
with AES-256, which a JRE older than 8u301 cannot read, and the default JMeter
image ships Java 8u275. Without them JMeter logs a warning, continues with no
client certificate, and the server answers 400 or 401, which reads as a server
fault. `run.sh` opens both keystores with that same JVM before each run and
refuses to start if either fails.

Given a `.p12` you cannot re-export, use a newer JRE instead:

```bash
JMETER_IMAGE=alpine/jmeter:latest ./run.sh --target targets/prod.private.env --scenario smoke
```

That image is JMeter 5.6.3 on Java 8u492, and native on arm64 so it avoids
emulation. It is not the default only because the committed findings were
measured with `justb4/jmeter:5.5`, and the load generator is part of what those
numbers reflect.

TLS sessions are cached per thread, so the handshake is paid once per thread
rather than per request. Otherwise you would be measuring TLS.

### Header auth

```sh
AUTH_HEADER_NAME=Authorization
AUTH_HEADER_VALUE=Bearer eyJ...
```

### Working up to a real measurement

Start with `--scenario smoke --rate 1`. A failure there stops before any load is
sent and prints the response code; `400`, `401` or `403` is authentication, not
capacity.

Then check the corpus matches the IG the instance serves, otherwise you are
measuring validation failures rather than validation. `response codes 200=n`
with no failures is the check; `CHELM_VERSION=x.y.z ./extract-payloads.sh`
rebuilds against a different release.

Only then measure.

## Rate, threads and finding the ceiling

Two different models, and the distinction decides what your numbers mean.

**Fixed arrival rate** (`--rate 5`) sends 5 requests per second whether or not
earlier ones have been answered. Concurrency is the output. This models traffic
from many independent callers, and answers "can it handle 5/s".

**Fixed concurrency** (`--rate 0 --threads 4`) keeps 4 requests in flight at all
times, each thread sending again as soon as the previous answer arrives.
Throughput is the output. This answers "what can it do", and is the right mode
for finding a ceiling.

Concurrency, throughput and latency are tied together by `concurrency =
throughput × latency`, so you can only choose two. That product is also the
check that a run did what you asked: 16.5 req/s at a 515 ms p50 is 8.5 in
flight, near enough to ten allowing for ramp-up. Well below your thread count
means the client was the bottleneck, not the server.

| Scenario | Default | Purpose |
|---|---|---|
| `smoke` | 1/s, 30s | is the target reachable and sane |
| `steady` | 5/s, 300s | the baseline you compare tuning runs against |
| `ramp` | 1,2,4,8,16,32/s, 120s each | find the rate at which it falls over |

`ramp` runs `steady` at increasing rates and stops when the achieved rate falls
below 0.9 of the requested one, validation p95 exceeds 5000 ms, or errors exceed
2%, printing which threshold tripped. The first of those is the definition of
the ceiling and usually arrives first. Adjust with `--ramp-steps 8,10,12,14`.

Threads are a pool, not the load level. With a fixed rate they only need to be
numerous enough to sustain it, and `run.sh` sizes them at four per unit of rate
unless you pass `--threads`. Starts are spread over a ramp-up of up to 30
seconds, because starting them at once produces an opening burst the timer can
only correct afterwards.

### More threads is not more throughput

4 CPU container, 4g heap, G1, `PublishDocumentReferenceStrict`, 60s unthrottled
after warmup:

| threads | req/s | validation p50 | in flight |
|--------:|------:|---------------:|----------:|
| 1 | 5.20 | 162 ms | 0.8 |
| 4 | 16.5 | 195 ms | 3.2 |
| 10 | 16.5 | 515 ms | 8.5 |
| 20 | 16.4 | 1086 ms | 17.8 |

The 4 and 10 rows are means of three runs each, 16.70/17.19/15.73 against
14.73/16.34/18.52. The ranges overlap almost completely: going from 4 to 10
threads bought no throughput and multiplied latency by 2.6. Past the knee, added
concurrency becomes queue depth.

Pick the thread count from what you want to learn. At or below the core count
finds peak throughput; above it shows how the service degrades when callers pile
up, which is what a queue backlog looks like in production.

One caveat on the fixed-rate mode: JMeter is natively closed-loop, and the
Constant Throughput Timer paces existing threads rather than injecting arrivals.
Under overload it quietly degrades back into closed-loop behaviour, so latency
is understated once the achieved rate stops matching the requested one. Trust
`--rate` numbers while those two agree; past that, switch to `--rate 0`.

## Comparing two configurations

The goal is a before and after that survives "how do you know?". Use one
command, unchanged across both sides:

```bash
./run.sh --target targets/ref.private.env --scenario steady \
  --rate 0 --threads 4 --duration 180 --warmup 20 \
  --i-know-this-is-a-real-instance
```

**Interleave the runs** — A, B, A, B, A, B, not three A then three B. A shared
environment drifts over tens of minutes and a block design turns that drift into
a fake result.

**Repeat at least three times a side.** Identical back-to-back runs vary by 10
to 15%, and by a factor of two at p95.

**Quote ranges, not means.** "16.7, 17.2, 15.7 against 21.1, 20.4, 22.0" is an
argument; "16.5 against 21.2" is an assertion. Compare `achieved_rps` and
`validation_p50`, and keep p95 out of the headline: real, but too noisy at three
runs to carry a claim.

### When each change needs a pull request

Interleaving assumes flipping the configuration is cheap. On a governed
environment it is not.

Measuring changes nothing, so it needs no pull request. Take the whole "before"
side before anything is merged.

If there is room, one pull request still buys interleaving: stand a *second*
deployment beside the existing one with the tuned flags, its own service and the
same limits. Both configurations then exist in the same time window, which beats
alternating one deployment, and it is one pull request to add and one to remove.
You need to address that instance directly rather than through a load balancer
that would spread requests across both.

Failing that, sequential is still worth doing. Five runs a side rather than
three, spread across a day. Let the controlled local measurement carry the
argument and treat the real environment as confirmation that the effect
transferred. Write the expected improvement down before the change merges; a
prediction that lands is much harder to argue with than the same numbers
explained afterwards.

What you cannot do sequentially is rule out something else changing between the
two windows. You can notice it: if the spread on one side is much wider than the
other, something moved, and the comparison should say so.

### What to change first

| Change | Effect |
|---|---|
| `-XX:+UseParallelGC` | +29% throughput, 45% lower p95, less heap |
| a heap that fits the container | removes most of the GC pressure |
| about 4 CPUs | past this throughput stops scaling |

Those first two together took a simulated 8 CPU / 16Gi deployment from 7.92 to
23.87 req/s, p99 from 10770 to 1778 ms, and RSS from 11.31 to 4.83 GiB. That was
measured against the old image, whose entrypoint hardcoded `-Xmx12g`.

Since 4.1.18 the image sizes the heap at `-XX:MaxRAMPercentage=70` and turns on
`-XX:+UseStringDeduplication`, so the heap half of that result is already in the
default and only the collector is left to change. Add to the default rather than
replacing it:

```yaml
env:
  - name: JDK_JAVA_OPTIONS
    value: >-
      -XX:MaxRAMPercentage=70
      -XX:+ExitOnOutOfMemoryError
      -XX:+UseStringDeduplication
      -XX:+UseParallelGC
```

`JDK_JAVA_OPTIONS` is read by the java launcher itself, so there is no command
or entrypoint to override. On an older image the entrypoint hardcodes `-Xmx12g`
and ignores everything, and the only way in is replacing the command.

Note that 70% of a 16Gi limit is still 11.2 GiB of heap, which is far more than
this workload needs; measured live heap is under 2 GiB. Lowering the percentage,
or the container limit, is worth testing on its own.

For a remote target `history.csv` cannot record `java_opts` or `cpus`, because
`run.sh` did not start the instance. Write the pod's CPU limit, memory limit and
JVM flags down beside the baseline by hand, or the number will not mean anything
later.

## Payload corpus

`extract-payloads.sh` fetches the CH ELM package from the FHIR registry and
extracts the example resources, so this repository does not depend on a checkout
of `matchbox-ch-elm` next to it. `run.sh` calls it when `payloads/` is missing.

```bash
./extract-payloads.sh                                        # default version
CHELM_VERSION=1.14.0 ./extract-payloads.sh                   # a different one
CHELM_TGZ=../../matchbox-ch-elm/src/ch.fhir.ig.ch-elm.tgz ./extract-payloads.sh
```

| `--profile` key | Resources | Count |
|---|---|---|
| `publish-documentreference-strict` | `DocumentReference-Publish-*` | 6 |
| `document` | `Bundle-*Doc-*` | 72 |
| `document-strict` | `Bundle-*Doc-*` | 72 |

The default is `publish-documentreference-strict`. Both corpora average 5 to 6
KiB per payload, so the choice changes variety rather than size.

The same tarball goes to `compose/ig/` and is loaded by the local server, so
payloads and server always come from one IG version. `extract-payloads.sh` warns
if `compose/application.yaml` pins a different one.

## Findings from the first tuning pass

M-series Mac, 10 cores, Docker limited to 4 CPUs for matchbox, CH ELM 1.15.1,
`PublishDocumentReferenceStrict`, unthrottled for 90s after warmup. Every
configuration was a fresh container so JVM pool sizes match the CPU quota. The
load generator shares the machine with the server, so absolute numbers are not
production figures; the comparisons are the useful part. Raw rows are in
`findings/`.

| Configuration | runs | mean req/s | range | mean p95 | heap peak |
|---|---:|---:|---|---:|---:|
| 4 cpu, 4g, G1 | 4 | 15.43 | 13.27–16.98 | 2907 ms | 3.6 GiB |
| 4 cpu, 4g, Parallel | 4 | **19.84** | 17.75–22.16 | **1586 ms** | 2.7 GiB |
| 4 cpu, 4g, ZGC | 1 | 7.20 | | 5951 ms | 4.0 GiB |
| 8 cpu, 4g, G1 | 1 | 14.56 | | 3470 ms | 3.6 GiB |
| 4 cpu, 8g, G1 | 1 | 14.59 | | 3618 ms | 7.0 GiB |

**Use ParallelGC.** The G1 and Parallel ranges do not overlap over four runs
each: 29% more throughput, 45% lower p95, less heap. One flag.

The reason is not the obvious one. Over the same load window ParallelGC pauses
roughly twice as much as G1:

| | G1 | Parallel |
|---|---:|---:|
| collections in ~95s | 154 | 286 |
| total pause | 8.4 s | 16.2 s |
| share of wall clock | 8.9 % | 17.1 % |
| longest pause | 302 ms | 1650 ms |
| full collections | 0 | 2 |

Parallel wins despite stopping the application for longer, because it avoids
G1's concurrent marking threads competing for the same four cores and the write
barriers G1 needs on reference writes. On a CPU-limited container that
concurrent overhead costs more than the extra pause time.

The trade is real: Parallel's longest pause was 1650 ms against G1's 302 ms, and
pause length grows with heap. Do not carry this to a much larger heap or a
service with a strict tail-latency SLA. GC takes 9 to 17 percent of wall clock
either way, which says this workload allocates heavily.

**Throughput stops scaling at about four cores.** 2.65, 6.49 and 16.41 req/s at
1, 2 and 4 cores, then 14.56 at 8, inside the 4 core range. That the collector
moves throughput by 29% while doubling cores moves it by nothing points at
allocation and GC as the constraint. Size at about four cores and scale out.

**More heap does not help.** 4g to 8g changed throughput by nothing measurable
and made p99 worse, 4386 to 7711 ms. Peak usage under a 4g cap is 2.7–3.7 GiB,
so heap was never the constraint.

**Do not set `txServerCache: false`.**
[Issue #422](https://github.com/ahdis/matchbox/issues/422) reports the default
causing growing memory and validation times. That is no longer true on this
version: turning it off roughly halves throughput on both collectors, 15.36 to
8.20 on G1 and 18.95 to 10.57 on Parallel. The issue is closed and
org.hl7.fhir.core has moved on several versions, so the advice in it is stale.
The ParallelGC advantage shows in both rows, an independent replication.

**A hypothesis tested and rejected.** `MatchboxEngineSupport.getMatchboxEngine`
is `synchronized` on a singleton, and without an `ig` parameter it called
`getCanonicalResource` inside that lock, converting a resource from R5 only to
use the result as a null check. Passing `ig` skips the branch entirely and made
no difference, 19.82 against 19.84 req/s. Wasted work, but not the ceiling.
Reproduce with `--params '&ig=ch.fhir.ig.ch-elm%231.15.1'`.

Engine caching works: every request in a run reports the same `sessionId`.

## Running it

A POSIX shell with `awk` and `sort`, plus JMeter. The aggregation in
`summarize.sh` is plain awk, matching the rest of the repository.

Docker is needed only for the `local` and `released` targets, since it is what
starts the container. Measuring an instance you did not start needs no Docker.

JMeter is resolved in this order:

| | Used when |
|---|---|
| `$JMETER_HOME/bin/jmeter` | `JMETER_HOME` set, wrapper executable, no space in the path |
| `java -jar $JMETER_HOME/bin/ApacheJMeter.jar` | `JMETER_HOME` set but the wrapper unusable |
| `jmeter` from `PATH` | neither of the above |
| `$JMETER_IMAGE` in Docker | no local JMeter at all |

An unpacked archive and a `java` on `PATH` are therefore enough.
`JMETER_JAVA_OPTS` sets the load generator's heap, default `-Xms1g -Xmx1g`, the
same as JMeter's own wrapper.

### Windows

Use Git Bash, which ships with Git for Windows and provides `bash`, `awk`,
`sort`, `curl` and `tar`, or WSL:

```bash
export JMETER_HOME=/c/tools/apache-jmeter-5.6.3
./run.sh --target targets/ref.private.env --scenario smoke --rate 1
```

`bin/jmeter` does not need to be executable: an archive extracted on Windows
loses the bit, and an install under `C:\Program Files` breaks JMeter's wrapper
outright with `Could not find or load main class Files...`. Both cases fall back
to starting `ApacheJMeter.jar` with `java`. Both fallbacks are tested; running
on Windows itself is not.

Without any POSIX shell, `run.sh` and `summarize.sh` will not run but JMeter
will. Build the corpus on a machine that has a shell, copy `payloads/` across,
and drive JMeter directly:

```
java -jar %JMETER_HOME%\bin\ApacheJMeter.jar ^
  -n -t loadtest.jmx -q user.properties ^
  -l run.jtl -j jmeter.log -e -o report ^
  -Jhost=https://matchbox.example.ch/matchboxv3 ^
  -Jprofile=http://fhir.ch/ig/ch-elm/StructureDefinition/PublishDocumentReferenceStrict ^
  -Jpayloadindex=payloads/publish-documentreference-strict.csv ^
  -Jrpm=60 -Jduration=300 -Jthreads=4 -Jrampup=10 -Jwarmup=2 -Jmetrics=off ^
  -Djavax.net.ssl.keyStore=certs/client.p12 ^
  -Djavax.net.ssl.keyStoreType=PKCS12 ^
  -Djavax.net.ssl.keyStorePassword=...
```

Run it from this directory; `payloadindex` and the paths inside it are relative
to the working directory. `rpm` is per minute, so 60 is 1/s, and there is no
"unlimited" — use a number the server cannot reach. You then read
`report/index.html`, which does not carry the server-side `validation ms` or a
`history.csv` row. Both come from `summarize.sh`, which can process the `.jtl`
afterwards on any machine with a shell:

```bash
LT_TARGET=ref LT_SCENARIO=steady ./summarize.sh run.jtl . history.csv
```

## Troubleshooting

**`port is already allocated`** — something else is on 8080. Use `PORT=8081`.

**`error getting credentials` pulling the released image** — a broken `gcloud`
docker credential helper. The registry is public:

```bash
DOCKER_CONFIG=$(mktemp -d) docker pull europe-west6-docker.pkg.dev/ahdis-ch/ahdis/matchbox-ch-elm:1.15.1
```

**`container never became healthy`** — loading the IG and generating snapshots
takes a minute or two cold. `run.sh` waits for the Spring Boot readiness probe,
not the port: `/fhir/metadata` answers well before the engine is usable, and the
server logs `ValidationEngine is not yet initialized` during that window. Past a
few minutes, check `docker logs matchbox-loadtest`.

**`validation ms not reported by the server`** — the response carried no timing
extension. Check the matchbox version; the whole summary leans on it.

**`process cpu not sampled`** — the line names the response code and the URL the
probe asked for. No probe row in `run.jtl` at all means metrics were switched
off before it ran, so check `METRICS=` in the target file.

## The other JMeter assets here

`run.sh` is additive. Everything below predates it and is unchanged.

| | What it is |
|---|---|
| `memory.jmx`, `memory_dev.jmx`, `memory_fast.jmx` | heap and validation time over a fixed iteration count, plotted as custom graphs in the report. Run with `./jmeter.sh` and friends |
| `multi-ig.jmx`, `jmeter_multi_ig.sh` | the same across several implementation guides, driven by `multi-ig.csv` |
| `measure_startup.py` | startup time, engine creation and the first three validations of a matchbox-ch-elm image, a fresh container per run |
| `claude-jmeter-check.md` | the runbook for the per-release ch-elm memory and performance check, with its historical results |

They answer a different question from this harness: memory behaviour over a
fixed number of iterations rather than throughput under a controlled load. All
of them need a local JMeter at the hardcoded path inside the scripts, for
example:

```bash
/Applications/apache-jmeter-5.6.2/bin/jmeter.sh \
  -q ./user.properties -t ./memory.jmx -l ./memory.jtl -o ./report -e
```
