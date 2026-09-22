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
`.jtl`, the JMeter HTML report, `jmeter.log` and `summary.json`, and appends a
row to `results/history.csv`. That file is the tuning log: it records
`java_opts`, `cpus`, `threads`, the requested rate, the IG version and the
matchbox version next to the results, so runs stay comparable.

## Targets

A target is an env file in `targets/`. `--target NAME` resolves
`targets/NAME.env`; a path is also accepted.

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
JAVA_OPTS="-Xmx4g -Xms4g -XX:+UseG1GC"
CPUS=4
MEM_LIMIT=6g
```

then rerun the same scenario and diff the history rows. `cpus` is pinned so
results are comparable across machines and so you can measure how throughput
scales with cores, which matters because validation is CPU bound.

Matchbox caches the IG dependency tree it downloads from packages2.fhir.org in
its H2 database, which is kept in a named volume between runs. The first run of
a target pays that download; later ones do not. `--fresh` drops the cache when
you want a genuine cold start.

Note that `matchbox-server/Dockerfile` hardcodes `java -Xmx12g` and ignores
`JAVA_OPTS`, which also means the heap ignores the container memory limit.
`compose/docker-compose.yml` replaces the entrypoint to make `JAVA_OPTS` work.
If the upstream entrypoint changes, that override needs updating.

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

Set these in the target file. Paths are relative to `jmeter/`.

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
  -out certs/client.p12 -name client
```

```bash
keytool -importcert -noprompt -alias ca -file ca.pem \
  -keystore certs/truststore.p12 -storetype PKCS12 -storepass changeit
```

The TLS session is cached per thread, so the handshake cost is paid once per
thread rather than per request. Otherwise you would be measuring TLS.

### Header auth

```sh
AUTH_HEADER_NAME=Authorization
AUTH_HEADER_VALUE=Bearer eyJ...
```

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
