#!/usr/bin/env bash
# Build the load test payload corpus from a CH ELM implementation guide package.
#
# The package is fetched from the FHIR registry by default so this repository
# does not depend on a checkout of matchbox-ch-elm sitting next to it. A version
# the registry does not have yet, such as a ci-build, is taken from the
# matchbox-ch-elm repository instead, which is what its image is built from.
# Point CHELM_TGZ at a local .tgz to use one you already have.
#
#   ./extract-payloads.sh                    # fetch the default version
#   CHELM_VERSION=1.14.0 ./extract-payloads.sh
#   CHELM_TGZ=../../matchbox-ch-elm/src/ch.fhir.ig.ch-elm.tgz ./extract-payloads.sh
set -euo pipefail

cd "$(dirname "$0")"

CHELM_VERSION="${CHELM_VERSION:-1.16.0}"
CHELM_TGZ="${CHELM_TGZ:-}"
REGISTRY="${CHELM_REGISTRY:-https://packages.fhir.org}"
FALLBACK_URL="${CHELM_FALLBACK_URL:-https://raw.githubusercontent.com/ahdis/matchbox-ch-elm/main/src/ch.fhir.ig.ch-elm.tgz}"
OUT=payloads

# Each profile key maps to a profile canonical URL and the example resources
# that are valid instances of it. $validate needs the profile passed explicitly
# because the CH ELM examples do not carry meta.profile.
profile_url() {
  case "$1" in
    publish-documentreference-strict) echo "http://fhir.ch/ig/ch-elm/StructureDefinition/PublishDocumentReferenceStrict" ;;
    document)                         echo "http://fhir.ch/ig/ch-elm/StructureDefinition/ch-elm-document" ;;
    document-strict)                  echo "http://fhir.ch/ig/ch-elm/StructureDefinition/ch-elm-document-strict" ;;
    *) return 1 ;;
  esac
}

example_glob() {
  case "$1" in
    publish-documentreference-strict) echo "DocumentReference-Publish-*.json" ;;
    document|document-strict)         echo "Bundle-*Doc-*.json" ;;
    *) return 1 ;;
  esac
}

PROFILE_KEYS="publish-documentreference-strict document document-strict"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "$CHELM_TGZ" ]; then
  [ -f "$CHELM_TGZ" ] || { echo "CHELM_TGZ not found: $CHELM_TGZ" >&2; exit 1; }
  echo "Using local package: $CHELM_TGZ"
  cp "$CHELM_TGZ" "$work/package.tgz"
else
  url="$REGISTRY/ch.fhir.ig.ch-elm/$CHELM_VERSION"
  echo "Fetching $url"
  if ! curl -fsSL -o "$work/package.tgz" "$url"; then
    echo "Not in the registry, fetching $FALLBACK_URL"
    curl -fsSL -o "$work/package.tgz" "$FALLBACK_URL" \
      || { echo "Download failed. Set CHELM_TGZ to a local package instead." >&2; exit 1; }
  fi
fi

tar xzf "$work/package.tgz" -C "$work"

version=$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$work/package/package.json" | head -1)
if [ -n "$CHELM_TGZ" ]; then
  CHELM_VERSION="$version"
elif [ "$version" != "$CHELM_VERSION" ]; then
  echo "Expected ch.fhir.ig.ch-elm $CHELM_VERSION, the package is $version." >&2
  echo "Set CHELM_TGZ or CHELM_FALLBACK_URL to a package of that version." >&2
  exit 1
fi

# Packages built by newer IG Publishers keep the examples in package/examples/
# (1.16.0 on), older ones in package/example/.
examples=""
for d in examples example; do
  [ -d "$work/package/$d" ] && { examples="$work/package/$d"; break; }
done
[ -n "$examples" ] || { echo "No package/examples/ or package/example/ in the package" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

for key in $PROFILE_KEYS; do
  url="$(profile_url "$key")"
  glob="$(example_glob "$key")"
  dir="$OUT/$key"
  mkdir -p "$dir"

  # shellcheck disable=SC2086
  files=$(cd "$examples" && ls $glob 2>/dev/null || true)
  if [ -z "$files" ]; then
    echo "  $key: no examples matched $glob, skipping" >&2
    rmdir "$dir"
    continue
  fi

  # JMeter reads this with a CSV Data Set Config. One payload path per line,
  # resolved relative to the jmeter/ directory.
  index="$OUT/$key.csv"
  : > "$index"
  count=0
  for f in $files; do
    cp "$examples/$f" "$dir/$f"
    echo "payloads/$key/$f" >> "$index"
    count=$((count + 1))
  done

  echo "$url" > "$OUT/$key.profile"
  bytes=$(cat "$dir"/*.json | wc -c | tr -d ' ')
  echo "  $key: $count payloads, $bytes bytes total"
  echo "      profile $url"
done

echo "$CHELM_VERSION" > "$OUT/.ig-version"

# The locally built server loads the same package from compose/ig, so fetch it
# once and use it for both the payloads and the server configuration.
mkdir -p compose/ig
cp "$work/package.tgz" compose/ig/ch.fhir.ig.ch-elm.tgz

echo
echo "Corpus written to jmeter/$OUT (ch.fhir.ig.ch-elm#$CHELM_VERSION)"
echo "IG package placed at jmeter/compose/ig/ch.fhir.ig.ch-elm.tgz"

configured=$(sed -n 's/^ *version: \(.*\)$/\1/p' compose/application.yaml | head -1 | tr -d ' ')
if [ -n "$configured" ] && [ "$configured" != "$CHELM_VERSION" ]; then
  echo
  echo "WARNING: compose/application.yaml pins ch.fhir.ig.ch-elm $configured but" >&2
  echo "         this corpus is $CHELM_VERSION. Update application.yaml, or the" >&2
  echo "         server will validate against a different IG than the payloads" >&2
  echo "         were taken from." >&2
fi
