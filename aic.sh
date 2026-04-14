#!/bin/sh


set -eu
# shellcheck disable=SC3040 # now part of POSIX, but not everywhere yet!
if set -o | grep -q 'pipefail'; then set -o pipefail; fi

# Root directory where this script is located
: "${AIC_ROOTDIR:="$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"}"

# Root URL for AIC API and IFFF images
: "${AIC_API:="https://api.artic.edu/api/v1"}"
: "${AIC_IIIF:="https://www.artic.edu/iiif/2"}"

# Random seed for the random queries, can be set to a fixed value for
# reproducibility
: "${AIC_SEED:="$(awk 'BEGIN {srand(); print srand()}')"}"

# Output image size
: "${AIC_SIZE:="843"}"

# Query to perform
: "${AIC_QUERY:="$AIC_ROOTDIR/queries/random-oil-painting.json"}"

# Name of the User-Agent header to identify the script to the API, can be set to a custom value or left empty to disable it
: "${AIC_USER_AGENT:="artwork-of-the-day/1.0 (https://github.com/efrecon/artwork-of-the-day)"}"

# Annotate the image with title, date and artist using ImageMagick if available, can be disabled with -b option
: "${AIC_ANNOTATE:="1"}"

# Verbosity level, can be increased with -v option
: "${AIC_VERBOSE:=0}"

usage() {
  # This uses the comments behind the options to show the help. Not extremely
  # correct, but effective and simple.
  echo "$0 picks an artwork per day from the Art Institute of Chicago" && \
    grep "[[:space:]].)[[:space:]][[:space:]]*#" "$0" |
    sed 's/#//' |
    sed -E 's/([a-zA-Z-])\)/-\1/'
  printf \\nEnvironment:\\n
  set | grep '^AIC_' | sed 's/^AIC_/    AIC_/g'
  exit "${1:-0}"
}

# Parse named arguments using getopts
while getopts ":bs:S:q:vh-" opt; do
  case "$opt" in
    b) # Do not annotate the image with title, date and artist using ImageMagick if available
      AIC_ANNOTATE="0";;
    q) # Query to perform, default is queries/random-oil-painting.json
      AIC_QUERY=$OPTARG;;
    S) # Random seed for the random queries, can be set to a fixed value for reproducibility
      AIC_SEED=$OPTARG;;
    s) # Output image size, default is 843 (the size of the largest image available for all artworks)
      AIC_SIZE=$OPTARG;;
    v) # Increase verbosity each time repeated
      AIC_VERBOSE=$(( AIC_VERBOSE + 1 ));;
    h) # Show this help
      usage 0;;
    -) # Takes name of destination file as argument, empty or "-" means stdout
      break;;
    *)
      usage 1;;
  esac
done
shift $((OPTIND -1))


# PML: Poor Man's Logging on stderr
_log() {
  printf '[%s] [%s] [%s] ' \
    "$(basename "$0")" \
    "${1:-LOG}" \
    "$(date +'%Y%m%d-%H%M%S')" \
    >&2
  shift
  _fmt="$1"
  shift
  # shellcheck disable=SC2059 # ok, we want to use printf format
  printf "${_fmt}\n" "$@" >&2
}
trace() { [ "$AIC_VERBOSE" -ge "2" ] && _log DBG "$@" || true ; }
info() { [ "$AIC_VERBOSE" -ge "1" ] && _log NFO "$@" || true ; }
warn() { _log WRN "$@"; }
error() { _log ERR "$@" && exit 1; }


# Silently download a file using curl
# $1: URL
# $2: output file (optional, default: basename of URL)
download() {
  run_curl -o "${2:-$(basename "$1")}" "$1"
}


# Wrapper around curl to add common options. No -f so that we can handle errors
# $@: curl arguments
run_curl() {
  curl -sSL --retry 5 --retry-delay 3 --max-time 10 "$@"
}


# Silence the command passed as an argument.
silent() { "$@" >/dev/null 2>&1 </dev/null; }



# Verify required commands are available
silent command -v jq || error "jq command not found"
_qry=$(sed "s/%SEED%/${AIC_SEED}/g" < "$AIC_ROOTDIR/queries/random-oil-painting.json")
_response=$(mktemp)

STATUS=$(run_curl \
            --header "Content-Type: application/json; charset=UTF-8" \
            --header "AIC-User-Agent: $AIC_USER_AGENT" \
            --data "$_qry" \
            --write-out '%{http_code}' \
            "${AIC_API}/search" \
            --output "$_response")
if [ "$STATUS" -ne 200 ]; then
  error "API request failed with status $STATUS"
fi

cat "$_response"

ARTWORK_ID=$(jq -r '.data[0].id' < "$_response")
ARTWORK_TITLE=$(jq -r '.data[0].title' < "$_response")
ARTWORK_DATE=$(jq -r '.data[0].date_display' < "$_response")
ARTWORK_ARTIST=$(jq -r '.data[0].artist_display' < "$_response")
ARTWORK_IMAGE_ID=$(jq -r '.data[0].image_id' < "$_response")


ARTWORK_URL="${AIC_IIIF}/${ARTWORK_IMAGE_ID}/full/${AIC_SIZE},/0/default.jpg"
OUTPUT="${1:-"-"}"

# Download to a temp file when output is stdout, otherwise download to the requested file
if [ "$OUTPUT" = "-" ]; then
  IMG_TMP="$(mktemp -u).jpg"
  run_curl \
    --header "AIC-User-Agent: $AIC_USER_AGENT" \
    --output "$IMG_TMP" \
    "$ARTWORK_URL"
  IMG_PATH="$IMG_TMP"
else
  run_curl \
    --header "AIC-User-Agent: $AIC_USER_AGENT" \
    --output "$OUTPUT" \
    "$ARTWORK_URL"
  IMG_PATH="$OUTPUT"
fi
rm -f "$_response"
info "Downloaded artwork: %s (%s) by %s (path: %s)" "$ARTWORK_TITLE" "$ARTWORK_DATE" "$ARTWORK_ARTIST" "$IMG_PATH"

# Annotate image with title, date and artist using ImageMagick if available
if [ "$AIC_ANNOTATE" = "0" ]; then
  info "Annotation disabled, skipping"
else
  trace "Annotating image with title, date and artist using ImageMagick if available"
  if silent command -v magick; then
    IM_CMD="magick"
  elif silent command -v convert; then
    IM_CMD="convert"
  else
    warn "ImageMagick not found; skipping annotation"
    IM_CMD=""
  fi

  if [ -n "$IM_CMD" ]; then
    TEXT="$(printf '%s (%s) - %s' "$ARTWORK_TITLE" "$ARTWORK_DATE" "$ARTWORK_ARTIST")"
    ANNOT_TMP="$(mktemp -u).jpg"

    # Draw white text with a thin black stroke for readability in the lower-left corner
    if ! "$IM_CMD" "$IMG_PATH" \
          -gravity SouthWest \
          -fill white \
          -stroke '#000000' \
          -strokewidth 2 \
          -pointsize 24 \
          -annotate +10+10 "$TEXT" \
          "$ANNOT_TMP"; then
      warn "ImageMagick annotation failed; leaving original image"
      rm -f "$ANNOT_TMP" || true
    else
      mv "$ANNOT_TMP" "$IMG_PATH"
    fi
  fi
fi

# If the output was requested to stdout, stream the (possibly annotated) image
if [ "$OUTPUT" = "-" ]; then
  cat "$IMG_PATH"
  rm -f "$IMG_PATH"
fi