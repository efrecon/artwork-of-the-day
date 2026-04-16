#!/bin/sh


set -eu
# shellcheck disable=SC3040 # now part of POSIX, but not everywhere yet!
if set -o | grep -q 'pipefail'; then set -o pipefail; fi

# Root directory where this script is located
: "${AIC_ROOTDIR:="$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"}"

# Root URL for AIC API and IFFF images
: "${AIC_API:="https://api.artic.edu/api/v1"}"
: "${AIC_IIIF:="https://www.artic.edu/iiif/2"}"

# Seed for the random queries, can be set to a fixed value for reproducibility.
# Set to empty to loop until an image oriented as AIC_ORIENTATION is found.
: "${AIC_SEED=""}"

# Target resolution for the image.
: "${AIC_RESOLUTION:="1920x1080"}"

# Query to perform
: "${AIC_QUERY:="$AIC_ROOTDIR/queries/random-oil-painting.json"}"

# Name of the User-Agent header to identify the script to the API, can be set to a custom value or left empty to disable it
: "${AIC_USER_AGENT:="artwork-of-the-day/1.0 (https://github.com/efrecon/artwork-of-the-day)"}"

# Annotate the image with title, date and artist using ImageMagick if available, can be disabled with -b option
: "${AIC_ANNOTATE:="1"}"

# Background color for centering canvas. When non-empty, the downloaded image
# will be centered on a canvas of this color at the exact AIC_RESOLUTION.
: "${AIC_BACKGROUND:=""}"

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
while getopts ":B:br:s:S:r:q:vh-" opt; do
  case "$opt" in
    B) # Background color for centering canvas. When set, the image is centered on a canvas of this color at the requested resolution
      AIC_BACKGROUND=$OPTARG;;
    b) # Do not annotate the image with title, date and artist using ImageMagick if available
      AIC_ANNOTATE="0";;
    r) # Resolution of the target image, this will drive the orientation to loop through when the seed is not set. Default is 1920x1080
      AIC_RESOLUTION=$OPTARG;;
    q) # Query to perform, default is queries/random-oil-painting.json
      AIC_QUERY=$OPTARG;;
    S) # Seed for the random queries, empty to loop until a properly oriented image is found
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


# Wrapper around curl to add common options. No -f so that we can handle errors
# $@: curl arguments
run_curl() {
  curl \
    --silent \
    --show-error \
    --location \
    --retry 5 \
    --retry-delay 3 \
    --max-time 10 \
      "$@"
}


# Silence the command passed as an argument.
silent() { "$@" >/dev/null 2>&1 </dev/null; }


aic_query() {
  _qry=$(sed "s/%SEED%/${AIC_SEED}/g" < "$AIC_QUERY")
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

  # ARTWORK_ID=$(jq -r '.data[0].id' < "$_response")
  ARTWORK_TITLE=$(jq -r '.data[0].title' < "$_response")
  ARTWORK_DATE=$(jq -r '.data[0].date_display' < "$_response")
  ARTWORK_ARTIST=$(jq -r '.data[0].artist_display' < "$_response")
  ARTWORK_IMAGE_ID=$(jq -r '.data[0].image_id' < "$_response")
  rm -f "$_response"
}


# Verify required commands are available
silent command -v jq || error "jq command not found"



# When AIC_ORIENTATION is empty, derive it from AIC_RESOLUTION (WIDTHxHEIGHT)
if [ -n "$AIC_RESOLUTION" ]; then
  AIC_RESOLUTION_W=$(printf '%s' "${AIC_RESOLUTION%%x*}" | tr -d '[:space:]')
  AIC_RESOLUTION_H=$(printf '%s' "${AIC_RESOLUTION##*x}" | tr -d '[:space:]')
  if [ "$AIC_RESOLUTION_W" -gt "$AIC_RESOLUTION_H" ] 2>/dev/null; then
    AIC_ORIENTATION="landscape"
  elif [ "$AIC_RESOLUTION_H" -gt "$AIC_RESOLUTION_W" ] 2>/dev/null; then
    AIC_ORIENTATION="portrait"
  else
    AIC_ORIENTATION="square"
  fi
  trace "Derived orientation '%s' from resolution %s" "$AIC_ORIENTATION" "$AIC_RESOLUTION"
fi

# When AIC_SEED is empty, loop until we find a properly oriented image
if [ -z "$AIC_SEED" ]; then
  while true; do
    # Generate a new random seed on each iteration when looping for landscape
    AIC_SEED=$(awk 'BEGIN {srand(); print int(rand()*32768)}')
    trace "Trying with seed %s" "$AIC_SEED"

    aic_query

    # When looping for landscape, check orientation via IIIF before downloading
    _iiif_info=$(run_curl \
                    --header "AIC-User-Agent: $AIC_USER_AGENT" \
                    "${AIC_IIIF}/${ARTWORK_IMAGE_ID}/info.json")
    _width=$(printf '%s' "$_iiif_info" | jq -r '.width')
    _height=$(printf '%s' "$_iiif_info" | jq -r '.height')
    if [ "$AIC_ORIENTATION" = "landscape" ] && [ "$_width" -ge "$_height" ]; then
      trace "Found landscape image: %s (%sx%s)" "$ARTWORK_TITLE" "$_width" "$_height"
      AIC_SIZE="${AIC_RESOLUTION_W},"
      break
    elif [ "$AIC_ORIENTATION" = "portrait" ] && [ "$_height" -ge "$_width" ]; then
      trace "Found portrait image: %s (%sx%s)" "$ARTWORK_TITLE" "$_width" "$_height"
      AIC_SIZE=",${AIC_RESOLUTION_H}"
      break
    elif [ "$AIC_ORIENTATION" = "square" ] && [ "$_width" -eq "$_height" ]; then
      trace "Found square image: %s (%sx%s)" "$ARTWORK_TITLE" "$_width" "$_height"
      AIC_SIZE="${AIC_RESOLUTION_W},"
      break
    else
      info "Skipping %s: not %s (%sx%s)" "$ARTWORK_TITLE" "$AIC_ORIENTATION" "$_width" "$_height"
      continue
    fi
  done
else
  aic_query
fi


ARTWORK_URL="${AIC_IIIF}/${ARTWORK_IMAGE_ID}/full/${AIC_SIZE}/0/default.jpg"
OUTPUT="${1:-"-"}"

# Download to a temp file when output is stdout, otherwise download to the requested file
if [ "$OUTPUT" = "-" ]; then
  IMG_TMP="$(mktemp -u).jpg"
  IMG_PATH="$IMG_TMP"
else
  IMG_PATH="$OUTPUT"
fi
run_curl \
  --header "AIC-User-Agent: $AIC_USER_AGENT" \
  --output "$IMG_PATH" \
  "$ARTWORK_URL"
info "Downloaded artwork: %s (%s) by %s (path: %s)" "$ARTWORK_TITLE" "$ARTWORK_DATE" "$ARTWORK_ARTIST" "$IMG_PATH"

# Center the image on a colored canvas at the exact target resolution
if [ -n "$AIC_BACKGROUND" ] && [ -n "$AIC_RESOLUTION" ]; then
  trace "Centering image on %s %s canvas" "$AIC_RESOLUTION" "$AIC_BACKGROUND"
  if silent command -v magick; then
    _IM_CMD="magick"
  elif silent command -v convert; then
    _IM_CMD="convert"
  else
    warn "ImageMagick not found; skipping centering"
    _IM_CMD=""
  fi

  if [ -n "$_IM_CMD" ]; then
    _CENTER_TMP="$(mktemp -u).jpg"
    if ! "$_IM_CMD" \
          -size "${AIC_RESOLUTION_W}x${AIC_RESOLUTION_H}" "xc:${AIC_BACKGROUND}" \
          "$IMG_PATH" \
          -gravity center \
          -composite \
          "$_CENTER_TMP"; then
      warn "ImageMagick centering failed; leaving original image"
      rm -f "$_CENTER_TMP" || true
    else
      mv "$_CENTER_TMP" "$IMG_PATH"
      info "Centered image on %sx%s white canvas" "$AIC_RESOLUTION_W" "$AIC_RESOLUTION_H"
    fi
  fi
fi

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
      info "Annotated image at %s with title, date and artist" "$IMG_PATH"
    fi
  fi
fi

# If the output was requested to stdout, stream the (possibly annotated) image
if [ "$OUTPUT" = "-" ]; then
  cat "$IMG_PATH"
  rm -f "$IMG_PATH"
fi
