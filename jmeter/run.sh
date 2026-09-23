#!/usr/bin/env bash
# Load test matchbox $validate against a local build, the published image, or a
# real instance. See readme.md.
#
#   ./run.sh --target local    --scenario steady --rate 5 --duration 5m
#   ./run.sh --target released --scenario ramp
#   ./run.sh --target targets/prod.private.env --scenario steady --rate 1
set -euo pipefail

cd "$(dirname "$0")"

TARGET=local
SCENARIO=steady
PROFILE_KEY=publish-documentreference-strict
RATE=""
DURATION=""
THREADS=""
WARMUP=""
METRICS=""
BUILD=0
KEEP_UP=0
ALLOW_REAL=0
FRESH=0
EXTRA_PARAMS=""
RAMP_STEPS="1,2,4,8,16,32"
RAMP_P95_MS=5000
RAMP_ERROR_RATE=0.02

die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

  --target NAME|PATH     targets/NAME.env, or a path to an env file  (default: local)
  --scenario NAME        smoke | steady | ramp                       (default: steady)
  --profile KEY          publish-documentreference-strict | document | document-strict
  --rate N               requests per second (steady). 0 means unthrottled
  --duration T           e.g. 300, 5m, 90s
  --threads N            JMeter thread pool size, not the load level
  --warmup N             warmup iterations excluded from results
  --metrics on|off|auto  sample actuator heap and cpu               (default: from target)
  --ramp-steps LIST      comma separated rates for the ramp scenario
  --params STR           extra query string appended to $validate, e.g. '&ig=pkg%23ver'
  --build                rebuild matchbox.jar before starting the local container
  --keep-up              leave the container running after the run
  --fresh                drop the cached IG package database first (slow cold start)
  --i-know-this-is-a-real-instance
                         required to raise the rate against a non-localhost host
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)        TARGET="$2"; shift 2 ;;
    --scenario)      SCENARIO="$2"; shift 2 ;;
    --profile)       PROFILE_KEY="$2"; shift 2 ;;
    --rate)          RATE="$2"; shift 2 ;;
    --duration)      DURATION="$2"; shift 2 ;;
    --threads)       THREADS="$2"; shift 2 ;;
    --warmup)        WARMUP="$2"; shift 2 ;;
    --metrics)       METRICS="$2"; shift 2 ;;
    --ramp-steps)    RAMP_STEPS="$2"; shift 2 ;;
    --params)        EXTRA_PARAMS="$2"; shift 2 ;;
    --build)         BUILD=1; shift ;;
    --keep-up)       KEEP_UP=1; shift ;;
    --fresh)         FRESH=1; shift ;;
    --i-know-this-is-a-real-instance) ALLOW_REAL=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

# --------------------------------------------------------------------------
# Target
# --------------------------------------------------------------------------
if [ -f "$TARGET" ]; then
  TARGET_FILE="$TARGET"
elif [ -f "targets/$TARGET.env" ]; then
  TARGET_FILE="targets/$TARGET.env"
else
  die "no target file for '$TARGET' (looked for ./$TARGET and targets/$TARGET.env)"
fi

# "." searches PATH for a bare name, so a relative path needs the ./ prefix and
# an absolute one must not get it.
case "$TARGET_FILE" in
  /*) ;;
  *) TARGET_FILE="./$TARGET_FILE" ;;
esac
set -a
# shellcheck disable=SC1090  # the target file is chosen at run time
. "$TARGET_FILE"
set +a

TARGET_NAME="${TARGET_NAME:-$(basename "$TARGET_FILE" .env)}"
HOST="${HOST:?HOST is not set in $TARGET_FILE}"
COMPOSE_PROFILE="${COMPOSE_PROFILE:-}"
METRICS="${METRICS:-${METRICS_DEFAULT:-auto}}"

case "$METRICS" in on|off|auto) ;; *) die "--metrics must be on, off or auto" ;; esac

# --------------------------------------------------------------------------
# Scenario defaults
# --------------------------------------------------------------------------
THREADS_EXPLICIT="$THREADS"
case "$SCENARIO" in
  smoke)  RATE="${RATE:-1}";  DURATION="${DURATION:-30}";  WARMUP="${WARMUP:-2}" ;;
  steady) RATE="${RATE:-5}";  DURATION="${DURATION:-300}"; WARMUP="${WARMUP:-10}" ;;
  ramp)   DURATION="${DURATION:-120}"; WARMUP="${WARMUP:-10}" ;;
  *) die "unknown scenario '$SCENARIO' (smoke, steady, ramp)" ;;
esac

# The timer paces threads rather than injecting arrivals, so every thread fires
# once as soon as it starts. Far more threads than the rate needs therefore
# produces an opening burst that the timer can only correct for afterwards: 64
# threads at a 1/s target measured 2.3/s at six times the real latency. Size
# the pool to the rate unless the caller insisted on a number.
threads_for_rate() {
  awk -v r="$1" 'BEGIN {
    if (r <= 0) { print 64; exit }
    n = int(r * 4); if (n < r * 4) n++
    if (n < 2) n = 2; if (n > 64) n = 64
    print n
  }'
}

# Accept 5m / 90s / 300
normalise_duration() {
  case "$1" in
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *)  echo "$1" ;;
  esac
}
DURATION="$(normalise_duration "$DURATION")"
[ "$DURATION" -gt 0 ] 2>/dev/null || die "--duration must be a positive number of seconds"

# Threads are a pool, not the load level, so the pool is deliberately larger
# than the target rate needs. Starting them all at once produces a burst of
# concurrent validations that inflates latency for the first part of the run,
# so spread the starts instead.
RAMPUP="${RAMPUP:-$(( DURATION / 6 ))}"
[ "$RAMPUP" -lt 5 ] && RAMPUP=5
[ "$RAMPUP" -gt 30 ] && RAMPUP=30

# --------------------------------------------------------------------------
# Guard rails for instances you did not start
# --------------------------------------------------------------------------
is_local_host=0
case "$HOST" in
  http://localhost:*|http://127.0.0.1:*|https://localhost:*|https://127.0.0.1:*|http://host.docker.internal:*) is_local_host=1 ;;
esac

if [ "$is_local_host" -eq 0 ] && [ "$ALLOW_REAL" -eq 0 ]; then
  if [ "$SCENARIO" = "ramp" ]; then
    die "ramp deliberately drives a target to its knee. $HOST is not localhost.
       If you really mean to do that to this instance, pass --i-know-this-is-a-real-instance"
  fi
  if [ "${RATE%%.*}" -gt 2 ] 2>/dev/null; then
    die "rate $RATE/s against a non-localhost host ($HOST).
       Keep it at 2/s or below, or pass --i-know-this-is-a-real-instance"
  fi
fi

# --------------------------------------------------------------------------
# Corpus
# --------------------------------------------------------------------------
PAYLOAD_INDEX="payloads/$PROFILE_KEY.csv"
PROFILE_FILE="payloads/$PROFILE_KEY.profile"
if [ ! -f "$PAYLOAD_INDEX" ]; then
  echo "Payload corpus missing, building it."
  ./extract-payloads.sh
fi
[ -f "$PAYLOAD_INDEX" ] || die "no corpus for profile key '$PROFILE_KEY'"
PROFILE_URL="$(cat "$PROFILE_FILE")"
IG_VERSION="$(cat payloads/.ig-version 2>/dev/null || echo unknown)"

# --------------------------------------------------------------------------
# JMeter
# --------------------------------------------------------------------------
JMETER_IMAGE="${JMETER_IMAGE:-justb4/jmeter:5.5}"
JMETER_CMD=""
if [ -n "${JMETER_HOME:-}" ] && [ -x "$JMETER_HOME/bin/jmeter" ]; then
  JMETER_CMD="$JMETER_HOME/bin/jmeter"
elif command -v jmeter >/dev/null 2>&1; then
  JMETER_CMD="$(command -v jmeter)"
elif command -v docker >/dev/null 2>&1; then
  JMETER_CMD="docker"
  echo "No local JMeter, using $JMETER_IMAGE."
  # Inside the container, the host's published ports are not on localhost.
  case "$HOST" in
    *//localhost:*|*//127.0.0.1:*)
      HOST="$(echo "$HOST" | sed -e 's#//localhost:#//host.docker.internal:#' -e 's#//127\.0\.0\.1:#//host.docker.internal:#')"
      ;;
  esac
else
  die "no JMeter found. Install it, set JMETER_HOME, or install Docker."
fi

# --------------------------------------------------------------------------
# Client certificates and truststore
# --------------------------------------------------------------------------
JAVA_SSL_ARGS=()
if [ -n "${CLIENT_CERT:-}" ]; then
  [ -f "$CLIENT_CERT" ] || die "CLIENT_CERT not found: $CLIENT_CERT (relative to jmeter/)"
  JAVA_SSL_ARGS+=(
    "-Djavax.net.ssl.keyStore=$CLIENT_CERT"
    "-Djavax.net.ssl.keyStoreType=${CLIENT_CERT_TYPE:-PKCS12}"
    "-Djavax.net.ssl.keyStorePassword=${CLIENT_CERT_PASSWORD:-}"
    # JMeter caches one SSL context per thread. Keep that on so the handshake
    # is not repeated per request, which would measure TLS, not validation.
    "-Dhttps.use.cached.ssl.context=true"
  )
  echo "Client certificate: $CLIENT_CERT (${CLIENT_CERT_TYPE:-PKCS12})"
fi
if [ -n "${CA_TRUSTSTORE:-}" ]; then
  [ -f "$CA_TRUSTSTORE" ] || die "CA_TRUSTSTORE not found: $CA_TRUSTSTORE (relative to jmeter/)"
  JAVA_SSL_ARGS+=(
    "-Djavax.net.ssl.trustStore=$CA_TRUSTSTORE"
    "-Djavax.net.ssl.trustStoreType=${CA_TRUSTSTORE_TYPE:-PKCS12}"
    "-Djavax.net.ssl.trustStorePassword=${CA_TRUSTSTORE_PASSWORD:-}"
  )
  echo "CA truststore:      $CA_TRUSTSTORE"
fi

AUTH_ARGS=()
if [ -n "${AUTH_HEADER_NAME:-}" ]; then
  AUTH_ARGS+=("-Jauthheadername=$AUTH_HEADER_NAME" "-Jauthheadervalue=${AUTH_HEADER_VALUE:-}")
fi

# --------------------------------------------------------------------------
# Container lifecycle
# --------------------------------------------------------------------------
COMPOSE=(docker compose -f compose/docker-compose.yml)
started_container=0

compose_down() {
  if [ "$started_container" -eq 1 ] && [ "$KEEP_UP" -eq 0 ]; then
    echo "Stopping $COMPOSE_PROFILE container."
    # Without -v, so the IG package cache survives. Re-downloading the CH ELM
    # dependency tree on every run dominates startup and makes the tuning loop
    # painful; --fresh wipes it when you actually want a cold start.
    "${COMPOSE[@]}" --profile "$COMPOSE_PROFILE" down >/dev/null 2>&1 || true
  fi
}
trap compose_down EXIT

if [ -n "$COMPOSE_PROFILE" ]; then
  command -v docker >/dev/null 2>&1 || die "COMPOSE_PROFILE is set but docker is not installed"

  if [ "$COMPOSE_PROFILE" = "local" ]; then
    JAR=../matchbox-server/target/matchbox.jar
    if [ "$BUILD" -eq 1 ] || [ ! -f "$JAR" ]; then
      echo "Building matchbox.jar (mvn -DskipTests package)."
      (cd .. && mvn -q -DskipTests package) || die "maven build failed"
    fi
    [ -f "$JAR" ] || die "expected $JAR after the build"
    [ -f compose/ig/ch.fhir.ig.ch-elm.tgz ] || ./extract-payloads.sh
  fi

  if [ "$FRESH" -eq 1 ]; then
    echo "Dropping the cached IG package database."
    "${COMPOSE[@]}" --profile "$COMPOSE_PROFILE" down -v >/dev/null 2>&1 || true
  fi

  export JAVA_OPTS CPUS MEM_LIMIT CHELM_IMAGE PORT
  echo "Starting matchbox (profile: $COMPOSE_PROFILE, JAVA_OPTS: ${JAVA_OPTS:-default})."
  "${COMPOSE[@]}" --profile "$COMPOSE_PROFILE" up -d --build
  started_container=1

  echo -n "Waiting for it to become healthy"
  for _ in $(seq 1 90); do
    state=$(docker inspect -f '{{.State.Health.Status}}' matchbox-loadtest 2>/dev/null || echo starting)
    [ "$state" = "healthy" ] && break
    if [ "$state" = "unhealthy" ]; then
      echo; docker logs --tail 40 matchbox-loadtest || true
      die "container went unhealthy"
    fi
    echo -n "."
    sleep 5
  done
  echo
  [ "$state" = "healthy" ] || { docker logs --tail 40 matchbox-loadtest || true; die "container never became healthy"; }
fi

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p results

run_once() {
  local rate="$1" tag="$2"
  local dir="results/$STAMP-$TARGET_NAME-$tag"
  mkdir -p "$dir"

  THREADS="${THREADS_EXPLICIT:-$(threads_for_rate "$rate")}"

  # The timer works in requests per minute and cannot express "no limit", so
  # unthrottled is just a rate the server will never keep up with.
  local rpm
  rpm="$(awk -v r="$rate" 'BEGIN { print (r <= 0) ? 6000000 : r * 60 }')"

  local props=(
    "-Jhost=$HOST"
    "-Jprofile=$PROFILE_URL"
    "-Jpayloadindex=$PAYLOAD_INDEX"
    "-Jrpm=$rpm"
    "-Jduration=$DURATION"
    "-Jthreads=$THREADS"
    "-Jrampup=$RAMPUP"
    "-Jwarmup=$WARMUP"
    "-Jmetrics=$METRICS"
    "-Jextraparams=$EXTRA_PARAMS"
    "-Jjtl=$dir/run.jtl"
    "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}"
  )

  echo
  echo "=== $TARGET_NAME / $SCENARIO / ${rate} req/s / ${DURATION}s / ${THREADS} threads / $PROFILE_KEY ==="

  local args=(
    -n -t loadtest.jmx -q user.properties
    -l "$dir/run.jtl" -j "$dir/jmeter.log"
    -e -o "$dir/report"
    "${props[@]}" "${JAVA_SSL_ARGS[@]+"${JAVA_SSL_ARGS[@]}"}"
  )

  if [ "$JMETER_CMD" = "docker" ]; then
    # Host networking is not dependable on Docker Desktop, so reach a locally
    # published port through the gateway alias instead.
    # -u keeps the result files owned by the caller, but that uid has no entry
    # in the image's /etc/passwd, so the JVM resolves user.home to "?" and
    # writes a junk ./?/ directory into the repo plus a broken xmlresolver
    # cache ("control.xml:1:1: Content is not allowed in prolog"). user.home is
    # read from the passwd entry at JVM start, too early for -Duser.home to fix
    # the preferences subsystem, so supply a passwd entry for the uid instead.
    printf 'root:x:0:0:root:/root:/bin/sh\njmeter:x:%s:%s:jmeter:/tmp:/bin/sh\n' \
      "$(id -u)" "$(id -g)" > .loadtest-passwd
    docker run --rm \
      -v "$PWD:/t" -w /t \
      -v "$PWD/.loadtest-passwd:/etc/passwd:ro" \
      --add-host=host.docker.internal:host-gateway \
      -u "$(id -u):$(id -g)" \
      "$JMETER_IMAGE" "${args[@]}"
  else
    "$JMETER_CMD" "${args[@]}"
  fi

  LT_TIMESTAMP="$STAMP" LT_TARGET="$TARGET_NAME" LT_SCENARIO="$tag" \
  LT_PROFILE_KEY="$PROFILE_KEY" LT_RATE="$rate" LT_DURATION="$DURATION" \
  LT_THREADS="$THREADS" LT_JAVA_OPTS="${JAVA_OPTS:-}" LT_CPUS="${CPUS:-}" \
  LT_IG_VERSION="$IG_VERSION" \
    ./summarize.sh "$dir/run.jtl" "$dir" results/history.csv

  LAST_DIR="$dir"
}

# True when the last history row breached a ramp threshold. Falls back to the
# HTTP percentile when the server reported no validation time.
breached() {
  awk -F, -v maxp95="$RAMP_P95_MS" -v maxerr="$RAMP_ERROR_RATE" '
    NR > 1 { err = $14; p95 = ($20 != "" ? $20 : $17) }
    END { exit (p95 > maxp95 || err > maxerr) ? 0 : 1 }
  ' results/history.csv
}

if [ "$SCENARIO" = "ramp" ]; then
  echo "Ramp: $RAMP_STEPS req/s, ${DURATION}s each."
  echo "Stops when validation p95 > ${RAMP_P95_MS}ms or error rate > $RAMP_ERROR_RATE."
  IFS=',' read -r -a steps <<< "$RAMP_STEPS"
  for step in "${steps[@]}"; do
    run_once "$step" "ramp-${step}rps"
    if breached "$LAST_DIR"; then
      echo "Threshold breached at ${step} req/s. Stopping the ramp."
      break
    fi
  done
  echo
  echo "Ramp results:"
  awk -F, -v stamp="$STAMP" '
    BEGIN { printf "  %7s %9s %8s %8s %7s\n", "rate/s", "achieved", "val p50", "val p95", "errors" }
    NR > 1 && $1 == stamp && $3 ~ /^ramp-/ {
      printf "  %7s %9.2f %8s %8s %6.2f%%\n", $10, $15, ($19 == "" ? "-" : $19), ($20 == "" ? "-" : $20), $14 * 100
    }
  ' results/history.csv
else
  run_once "$RATE" "$SCENARIO"
fi

echo "Report:  $LAST_DIR/report/index.html"
echo "History: results/history.csv"
