# Load testing matchbox

Measures `$validate` throughput and latency against a matchbox you built from
this working tree, against the published `matchbox-ch-elm` image, or against a
real instance. The point is a tuning loop: change something, rerun the same
scenario, compare rows in `results/history.csv`.

CH ELM is used as the workload because it is a realistic, profile-heavy
validation and its example resources are published with the IG. Nothing here is
specific to CH ELM beyond the corpus and the profile URLs in
`extract-payloads.sh`.

## Quick start

```bash
cd jmeter
./run.sh --target released --scenario smoke
```

That pulls the published image, waits for it to load the IG, warms it up, runs
for 30 seconds and prints a summary. No JMeter installation is needed: if
`jmeter` is not on your `PATH` and `JMETER_HOME` is unset, the run happens in a
container.

To measure your own changes instead:

```bash
./run.sh --target local --scenario steady --rate 5 --duration 5m --build
```

## What gets measured

```
  target            released  (smoke)
  matchbox          4.1.13
  samples           46  (0 failed, 0.00%)
  throughput        1.03 req/s   (requested 1/s)
  http ms           p50 505   p95 745   p99 1093
  validation ms     p50 478   p95 706   p99 1084    <- server side
  heap peak         3.78 GiB
  response codes    200=46
```

Two latencies are reported because they answer different questions.

`http ms` is the full round trip as the client sees it. `validation ms` is what
matchbox itself reports in the OperationOutcome:

```
$.issue[0].extension[0].extension[?(@.url == 'total')].valueDuration.value
```

Against localhost the two are within a few milliseconds. Against a remote
instance they diverge by network and TLS time, and only `validation ms` tells
you anything about the server. Optimise against that one.

`heap peak` comes from `/actuator/metrics/jvm.memory.used`, sampled every 5
seconds alongside the load.

Each run writes `results/<timestamp>-<target>-<scenario>/` containing the raw
`.jtl`, the JMeter HTML report and `jmeter.log`, and appends a row to
`results/history.csv`. That file is the tuning log: it records
`java_opts`, `cpus`, `threads`, the requested rate, the IG version and the
matchbox version next to the results, so runs stay comparable.

## Targets

A target is an env file in `targets/`. `--target NAME` resolves
`targets/NAME.env`; a path is also accepted.

The target file is sourced, so anything it sets acts as a default for that
target. Command line flags win over it, and a scenario default applies only when
neither set a value: **command line, then target file, then scenario default.**

| Target     | What it is                                  | Tunable |
|------------|---------------------------------------------|---------|
| `local`    | built from this working tree, CH ELM loaded | yes     |
| `released` | the published `matchbox-ch-elm` image       | heap and cpu only |
| your own   | an instance you did not start               | no      |

`local` and `released` are started and stopped by `run.sh` through
`compose/docker-compose.yml`. Both publish `http://localhost:8080/matchboxv3`,
so the test does not care which is running. Use `PORT=8081` if 8080 is busy.

`local` needs `matchbox-server/target/matchbox.jar`. `run.sh` builds it with
`mvn -DskipTests package` if it is missing; pass `--build` to force a rebuild
after changing code. The Angular frontend is not part of that build.

### Tuning the local target

Edit `targets/local.env`:

```sh
JAVA_OPTS="${JAVA_OPTS:--Xmx4g -Xms4g -XX:+UseG1GC}"
CPUS="${CPUS:-4}"
MEM_LIMIT="${MEM_LIMIT:-6g}"
```

then rerun the same scenario and diff the history rows. All three can also be
set per run from the environment, which is how you sweep one knob:

```bash
CPUS=8 ./run.sh --target local --scenario steady --rate 0
```

`cpus` is pinned so results are comparable across machines and so you can
measure how throughput scales with cores. It scales cleanly to about four; see
the findings below for where it stops.

Matchbox caches the IG dependency tree it downloads from packages2.fhir.org in
its H2 database, which is kept in a named volume between runs. The first run of
a target pays that download; later ones do not. `--fresh` drops the cache when
you want a genuine cold start.

The `released` target uses a published image built before the entrypoint
honoured `JAVA_OPTS`, so `compose/docker-compose.yml` replaces its entrypoint to
make the setting take effect. The `local` target needs no such override.

## Measuring a real instance

Copy the template and keep it out of git:

```bash
cp targets/remote.env.example targets/prod.private.env
./run.sh --target targets/prod.private.env --scenario steady --rate 1
```

`*.private.env` and `certs/` are gitignored.

Read this before you do it:

- **You are adding load to something that is probably serving real traffic.**
  `run.sh` refuses `ramp` against a non-localhost host, and refuses a rate above
  2/s, unless you pass `--i-know-this-is-a-real-instance`. That flag is the
  whole safety mechanism; there is nothing else stopping you.
- **You do not control warmup.** The instance may be cold, may have been warm
  for a week, or may be behind a load balancer spreading your requests over
  several pods with different states. The warmup phase here only warms whatever
  it happens to reach.
- **Other traffic is in your numbers.** Results from a shared instance are not
  comparable with local runs. `history.csv` records the target name so you can
  keep them apart, but nothing prevents you from comparing them by mistake.
- **`/actuator` is usually blocked.** `METRICS=auto` probes it once and turns
  heap sampling off if it is unreachable, rather than filling the run with
  failed samples. `--metrics on` forces the attempt, which is how you find out
  whether it is exposed.

### Mutual TLS

Set these in the target file. Paths are relative to `jmeter/`, and must stay
inside it: JMeter runs in a container that only mounts this directory.

```sh
CLIENT_CERT=certs/client.p12
CLIENT_CERT_PASSWORD=...
CLIENT_CERT_TYPE=PKCS12

CA_TRUSTSTORE=certs/truststore.p12
CA_TRUSTSTORE_PASSWORD=...
CA_TRUSTSTORE_TYPE=PKCS12
```

`run.sh` turns these into the corresponding `javax.net.ssl.*` system properties.
The truststore is only needed when the server certificate comes from a private
CA; without it the handshake fails with a PKIX path error.

Building the keystores from PEM files:

```bash
openssl pkcs12 -export -inkey client.key -in client.crt \
  -out certs/client.p12 -name client \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
```

```bash
keytool -importcert -noprompt -alias ca -file ca.pem \
  -keystore certs/truststore.p12 -storetype PKCS12 -storepass changeit
```

The `-keypbe`/`-certpbe`/`-macalg` arguments are not decoration. OpenSSL 3
defaults to PBES2 with AES-256, which a JRE older than 8u301 cannot read, and
the default JMeter image ships Java 8u275. Without them JMeter logs a warning,
carries on with no client certificate, and the server answers 400 or 401, which
looks like a server problem rather than a keystore one. `run.sh` opens both
keystores with that same JVM before starting a run and refuses to continue if
either fails, so this shows up as a clear error.

If you are given a `.p12` you cannot re-export, run JMeter on a newer JRE
instead:

```bash
JMETER_IMAGE=alpine/jmeter:latest ./run.sh --target targets/prod.private.env --scenario smoke
```

That image is JMeter 5.6.3 on Java 8u492 and is also native on arm64, so it
does not run under emulation. It is not the default only because the committed
findings were measured with `justb4/jmeter:5.5`, and the load generator is part
of what those numbers reflect.

The TLS session is cached per thread, so the handshake cost is paid once per
thread rather than per request. Otherwise you would be measuring TLS.

### Header auth

```sh
AUTH_HEADER_NAME=Authorization
AUTH_HEADER_VALUE=Bearer eyJ...
```

### First run against a new instance

Work up in three steps rather than starting from a scenario that sends load.

```bash
# 1. Does it answer at all, and does the client certificate work?
./run.sh --target targets/ref.private.env --scenario smoke --rate 1 --duration 30
```

A failure here stops before any load is sent and prints the response code.
`400`, `401` or `403` means authentication, not capacity.

```bash
# 2. Is the corpus the right one?
```

The payloads have to match the IG the instance actually serves, otherwise you
are measuring validation failures. `response codes  200=n` with no failures is
the check; `CHELM_VERSION=x.y.z ./extract-payloads.sh` rebuilds the corpus
against a different release.

```bash
# 3. A real measurement.
./run.sh --target targets/ref.private.env --scenario steady --rate 2 --duration 5m
```

Anything above 2/s needs `--i-know-this-is-a-real-instance`. Agree that with
whoever operates the instance first; on a shared environment your numbers
include their traffic and vice versa.

Compare `validation_p50` across runs, not `achieved_rps`: against a throttled
remote target throughput only tells you the timer worked.

## Scenarios

| Scenario | Default                       | Purpose |
|----------|-------------------------------|---------|
| `smoke`  | 1/s, 30s, 2 threads           | is the target reachable and sane |
| `steady` | 5/s, 300s, 16 threads         | the baseline you compare tuning runs against |
| `ramp`   | 1,2,4,8,16,32/s, 120s each    | find the rate at which it falls over |

`ramp` runs `steady` repeatedly at increasing rates and stops when validation
p95 exceeds 5000 ms or the error rate exceeds 2%, then prints a rate-versus-
latency table. Adjust the steps with `--ramp-steps 1,2,3,4`.

Threads are a connection pool, not the load level. The arrival rate is set by a
Constant Throughput Timer; threads only need to be numerous enough to sustain
it. At roughly 500 ms per validation, one thread sustains about 2/s. Thread
starts are spread over a ramp-up of up to 30 seconds, because starting sixteen
threads at once produces a burst of concurrent validations that inflates
latency for the first part of the run.

`--rate 0` means unthrottled: the timer is set to a rate the server will never
reach, so threads run flat out.

## Payload corpus

`extract-payloads.sh` fetches the CH ELM package from the FHIR registry and
extracts the example resources, so this repository does not depend on a
checkout of `matchbox-ch-elm` sitting next to it. `run.sh` calls it
automatically when `payloads/` is missing.

```bash
./extract-payloads.sh                                        # default version
CHELM_VERSION=1.14.0 ./extract-payloads.sh                   # a different one
CHELM_TGZ=../../matchbox-ch-elm/src/ch.fhir.ig.ch-elm.tgz ./extract-payloads.sh
```

| `--profile` key                    | Resources | Count |
|------------------------------------|-----------|-------|
| `publish-documentreference-strict` | `DocumentReference-Publish-*` | 6 |
| `document`                         | `Bundle-*Doc-*` | 72 |
| `document-strict`                  | `Bundle-*Doc-*` | 72 |

The default is `publish-documentreference-strict`, matching what `memory.jmx`
already tested. Use `--profile document` for a wider and more varied corpus.

The same tarball is placed in `compose/ig/` and loaded by the local server, so
the payloads and the server always come from one IG version.
`extract-payloads.sh` warns if `compose/application.yaml` pins a different one.

## Findings from the first tuning pass

Measured on an M-series Mac, 10 cores, Docker limited to 4 CPUs for matchbox,
CH ELM 1.15.1, profile `PublishDocumentReferenceStrict`, unthrottled for 90s
after warmup. Every configuration was a fresh container so that JVM pool sizes
match the CPU quota.

| Configuration      | runs | mean req/s | range        | mean p95 | heap peak |
|--------------------|-----:|-----------:|--------------|---------:|----------:|
| 4 cpu, 4g, G1      |    4 |      15.43 | 13.27–16.98  |  2907 ms |   3.6 GiB |
| 4 cpu, 4g, Parallel|    4 |  **19.84** | 17.75–22.16  |**1586 ms**|  2.7 GiB |
| 4 cpu, 4g, ZGC     |    1 |       7.20 |              |  5951 ms |   4.0 GiB |
| 8 cpu, 4g, G1      |    1 |      14.56 |              |  3470 ms |   3.6 GiB |
| 4 cpu, 8g, G1      |    1 |      14.59 |              |  3618 ms |   7.0 GiB |

**Use ParallelGC.** The G1 and Parallel ranges do not overlap over four runs
each: 29% more throughput, 45% lower p95, and less heap. This is one flag.

The reason is not the obvious one. With `-Xlog:gc` captured over the same load
window (see `findings/readme.md` to regenerate it), ParallelGC pauses roughly
twice as much as G1:

| | G1 | Parallel |
|---------------------|--------:|---------:|
| collections in ~95s |     154 |      286 |
| total pause         |   8.4 s |   16.2 s |
| share of wall clock |   8.9 % |   17.1 % |
| longest pause       |  302 ms |  1650 ms |
| full collections    |       0 |        2 |

So Parallel wins despite stopping the application for longer. What it avoids is
G1's concurrent work: marking threads that run alongside the application and
compete for the same four cores, plus the write barriers G1 needs on reference
writes. On a CPU-limited container that concurrent overhead costs more than the
extra pause time, and validation gets more CPU.

That trade has a real cost. Parallel's longest pause here was 1650 ms against
G1's 302 ms, and pause length grows with heap, so this result should not be
carried over to a much larger heap or to a service with a strict tail-latency
SLA. It holds for a small heap on few cores, which is what these containers are.

GC also takes 9 to 17 percent of wall clock either way, which is the real
signal: this workload allocates heavily.

**Validation is allocation bound past about four cores, not CPU bound.**
Throughput scales cleanly from 1 to 4 cores (2.65, 6.49, 16.41 req/s, so
roughly 4 validations per second per core), then stops: 8 cores measured 14.56,
inside the 4 core range. That the collector choice moves throughput by 29% while
doubling the cores moves it by nothing points at allocation and GC as the
constraint. Size instances at about four cores and scale out rather than up.

**More heap does not help.** 4g to 8g changed throughput by nothing measurable
and made p99 worse (4386 to 7711 ms). Peak usage is 2.7–3.7 GiB under a 4g cap,
so the heap was never the constraint.

**Do not set `txServerCache: false`.** [Issue #422](https://github.com/ahdis/matchbox/issues/422)
reports that the default (`true`) caused growing memory and validation times,
and that turning it off helped. That is no longer true on this version: turning
it off roughly halves throughput, on both collectors.

| `txServerCache` | G1    | Parallel |
|-----------------|------:|---------:|
| `true` (default)| 15.36 |    18.95 |
| `false`         |  8.20 |    10.57 |

The issue is closed and org.hl7.fhir.core has moved on several versions since it
was filed, so the advice in it is stale. Keep the default. Usefully, the
ParallelGC advantage shows up in both rows (+23% and +29%), which is an
independent replication of the result above under a different configuration.

**A second hypothesis tested and rejected.** `MatchboxEngineSupport.getMatchboxEngine`
is `synchronized` on a singleton, and for a request without an `ig` parameter it
calls `MatchboxEngine.getCanonicalResource` inside that lock, which does two
`fetchResource` calls plus a full R5 to R4 conversion of the profile and then
discards the converted resource, since the result is only used as a null check.
Passing `ig` skips that branch entirely. It made no difference (19.82 against
19.84 req/s over two runs), so the conversion is wasted work but not the
throughput ceiling. Reproduce with:

```bash
./run.sh --target local --scenario steady --rate 0 \
  --params '&ig=ch.fhir.ig.ch-elm%231.15.1'
```

Engine caching is working: every request in a run reports the same `sessionId`,
so no engine is built per request.

Caveat on all of the above: the load generator runs on the same machine as the
server, so absolute numbers are not production figures. The comparisons between
configurations are the useful part.

## Interpreting results

Single runs are noisy. On a laptop with other containers running, back-to-back
identical runs varied by a factor of two at p95. Before concluding that a change
helped, run the same scenario at least three times per configuration and compare
`validation_p50`, which is far more stable than p95.

`compose/application.yaml` mirrors `matchbox-ch-elm/src/application.yaml`. If
that file changes upstream, update this one, otherwise you are benchmarking a
configuration you do not ship. Note that `txServer` points the instance at
itself, so terminology lookups are in-process and part of what you are
measuring.

## Dependencies

A POSIX shell with `awk` and `sort`, plus JMeter. Nothing else: the aggregation
in `summarize.sh` is plain awk, matching the rest of the repository, which has
no Python sources of its own.

Docker is needed only for the `local` and `released` targets, because it is what
starts the matchbox container. Measuring an instance you did not start needs no
Docker at all, as long as JMeter itself can run without it.

JMeter is resolved in this order:

| | Used when |
|---|---|
| `$JMETER_HOME/bin/jmeter` | `JMETER_HOME` is set and the wrapper is executable |
| `java -jar $JMETER_HOME/bin/ApacheJMeter.jar` | `JMETER_HOME` is set but the wrapper is not executable |
| `jmeter` from `PATH` | neither of the above |
| `$JMETER_IMAGE` in Docker | no local JMeter at all |

The second row means an unpacked JMeter archive and a `java` on `PATH` are
enough. `JMETER_JAVA_OPTS` sets the load generator's heap, default `-Xms1g
-Xmx1g`, the same as JMeter's own wrapper.

### Running on Windows

Use Git Bash, which ships with Git for Windows and provides `bash`, `awk`,
`sort`, `curl` and `tar`, or use WSL. Download and unpack Apache JMeter, then:

```bash
export JMETER_HOME=/c/tools/apache-jmeter-5.6.3
./run.sh --target targets/ref.private.env --scenario smoke --rate 1
```

There is no need to make `bin/jmeter` executable: an archive extracted on
Windows usually loses the bit, and `run.sh` falls back to starting
`ApacheJMeter.jar` with `java` directly. An install under `C:\Program Files`
takes the same fallback, because JMeter's wrapper script fails on a space in its
own path with `Could not find or load main class Files...`.

Both fallbacks are tested; running on Windows itself is not, so treat this as
the expected route rather than a verified one.

#### Without any POSIX shell

`run.sh` and `summarize.sh` will not run under `cmd` or PowerShell. JMeter
itself will, so drive it directly. Build the payload corpus once on any machine
that has a shell, copy `payloads/` across, and then:

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

Run it from this directory: `payloadindex` and the paths inside it are relative
to the working directory. `rpm` is the arrival rate per minute, so 60 is 1/s;
there is no "unlimited", so use a number the server cannot reach.

You then read `report/index.html` instead of the printed summary. What you lose
is the server side `validation ms`, which is the number worth optimising against
on a remote instance, and the `history.csv` row that makes runs comparable. Both
come from `summarize.sh`, so run the `.jtl` through it later on a machine that
has a shell:

```bash
LT_TARGET=ref LT_SCENARIO=steady ./summarize.sh run.jtl . history.csv
```

## The older memory profiling plan

`memory.jmx`, `memory_dev.jmx` and `memory_fast.jmx` with their `jmeter*.sh`
wrappers predate this and are unchanged. They plot heap and validation time over
a fixed number of iterations, which is a different question from throughput
under load. They still require a local JMeter at the hardcoded path inside those
scripts.

## Troubleshooting

**`port is already allocated`** — something else is on 8080. Use `PORT=8081`.

**`error getting credentials` when pulling the released image** — a broken
`gcloud` docker credential helper. The registry is public, so the pull works
without credentials:

```bash
DOCKER_CONFIG=$(mktemp -d) docker pull europe-west6-docker.pkg.dev/ahdis-ch/ahdis/matchbox-ch-elm:1.15.1
```

**`container never became healthy`** — loading the IG and generating snapshots
takes a minute or two on a cold start, and `run.sh` waits for the Spring Boot
readiness probe rather than for the port to open. `/fhir/metadata` answers well
before the validation engine is usable, so it is not a readiness signal; the
server logs `ValidationEngine is not yet initialized, waiting for
initialization of packages` during that window. If it persists past a few
minutes, `docker logs matchbox-loadtest`.

**`validation ms  not reported by the server`** — the response had no timing
extension. Check the matchbox version; the extension is what the whole summary
leans on.
