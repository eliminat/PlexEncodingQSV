#!/bin/bash

# ==============================================================================
# Universal_Encode.sh - Unified Intel Arc A380 QSV Encoding Pipeline
# Supports: AV1, HEVC, and Remux (Copy-Video) modes
# ==============================================================================

# --- Initialization ---
if [ $# -eq 0 ]; then
    echo "Usage: $0 [--hevc | --copy-video] <input_file>"
    exit 1
fi

# Default Configuration
ENCODER_TYPE="av1"
ENCODER_CMD="av1_qsv"
GLOBAL_QUALITY=25
MIN_OUTPUT_SIZE_MB=10
LOCK_FILE="/plexdb/plexlogs/plex_encoding.lock"
LOCK_TIMEOUT=$((8 * 3600))
LOCK_WAIT_INTERVAL=300

# Parse Arguments
INPUT_VIDEO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hevc) ENCODER_TYPE="hevc"; ENCODER_CMD="hevc_qsv"; shift ;;
        --copy-video) ENCODER_TYPE="copy"; ENCODER_CMD="copy"; shift ;;
        --quality) GLOBAL_QUALITY="$2"; shift 2 ;;
        *) INPUT_VIDEO="$1"; shift ;;
    esac
done

# Absolute path handling
if [[ "$INPUT_VIDEO" != /* ]]; then
    INPUT_VIDEO="$(pwd)/$INPUT_VIDEO"
fi

VIDEO_NAME=$(basename "$INPUT_VIDEO")
VIDEO_NAME_NO_EXT="${VIDEO_NAME%.*}"
LOG_FILE="/plexdb/plexlogs/${VIDEO_NAME_NO_EXT}_${ENCODER_TYPE}_encode_log.txt"
TEMP_OUTPUT="/plexdb/plexlogs/temp/${VIDEO_NAME_NO_EXT}_temp_${ENCODER_TYPE}.mkv"

# --- Infrastructure ---
mkdir -p /plexdb/plexlogs/temp

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

cleanup() {
    log_message "Cleanup: Removing temp files and releasing lock"
    [ -f "$TEMP_OUTPUT" ] && rm -f "$TEMP_OUTPUT"
    flock -u 100 2>/dev/null
}
trap cleanup EXIT INT TERM

# --- Lock Acquisition ---
exec 100>$LOCK_FILE || exit 1
lock_start=$(date +%s)
while ! flock -n 100; do
    if (( $(date +%s) - lock_start >= LOCK_TIMEOUT )); then
        log_message "Error: Lock timeout. Exiting."
        exit 1
    fi
    log_message "Waiting for another encoding process..."
    sleep $LOCK_WAIT_INTERVAL
done

# --- Technical Analysis (JSON Probing) ---
log_message "Analyzing: $VIDEO_NAME"

V_JSON=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile,pix_fmt,r_frame_rate,color_primaries,color_transfer,color_space -of json "$INPUT_VIDEO")

V_CODEC=$(echo "$V_JSON" | jq -r '.streams[0].codec_name')
V_PROFILE=$(echo "$V_JSON" | jq -r '.streams[0].profile')
V_PIX_FMT=$(echo "$V_JSON" | jq -r '.streams[0].pix_fmt')
V_FPS_RAW=$(echo "$V_JSON" | jq -r '.streams[0].r_frame_rate')
V_COLOR_PRI=$(echo "$V_JSON" | jq -r '.streams[0].color_primaries // empty')
V_COLOR_TRC=$(echo "$V_JSON" | jq -r '.streams[0].color_transfer // empty')
V_COLOR_SPC=$(echo "$V_JSON" | jq -r '.streams[0].color_space // empty')

# Handle FPS and GOP
V_FPS=$(echo "scale=2; $V_FPS_RAW" | bc -l)
GOP_SIZE=$(echo "$V_FPS * 10 / 1" | bc 2>/dev/null)
if [[ -z "$GOP_SIZE" ]] || [[ "$GOP_SIZE" -le 0 ]]; then GOP_SIZE=240; fi

# HWAccel Decision
USE_HWACCEL=true
if [[ "$V_CODEC" == "h264" ]] && [[ "$V_PROFILE" == "High 10" || "$V_PIX_FMT" == "yuv420p10le" ]]; then
    USE_HWACCEL=false
    log_message "H.264 High 10 detected: Using software decode fallback."
fi

# --- Smart Stream Mapping Engine ---
AUDIO_MAPS=()
AUDIO_OPTS=()
ST_COUNT=0

# Gather all audio stream info in JSON
A_JSON=$(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language:stream=channels:stream=bit_rate -of json "$INPUT_VIDEO")

# Define priority logic in shell
get_indices() {
    echo "$A_JSON" | jq -r ".streams[] | select(.tags.language != null and (.tags.language | test(\"$1\"; \"i\"))) | .index"
}

ENG_STREAMS=$(get_indices "eng")
JPN_STREAMS=$(get_indices "jpn")
UND_STREAMS=$(echo "$A_JSON" | jq -r '.streams[] | select(.tags.language == null or .tags.language == "und") | .index')

# Deduplicate indices while preserving order
ALL_STREAMS=$(printf "%s\n%s\n%s" "$ENG_STREAMS" "$JPN_STREAMS" "$UND_STREAMS" | grep -v '^$' | awk '!x[$0]++')

# Fallback: If no priorities found, take everything
[ -z "$ALL_STREAMS" ] && ALL_STREAMS=$(echo "$A_JSON" | jq -r '.streams[].index')

FILTER_COMPLEX=""
for IDX in $ALL_STREAMS; do
    CHANNELS=$(echo "$A_JSON" | jq -r ".streams[] | select(.index == $IDX) | .channels")
    LANG=$(echo "$A_JSON" | jq -r ".streams[] | select(.index == $IDX) | .tags.language // \"und\"")
    SRC_BITRATE=$(echo "$A_JSON" | jq -r ".streams[] | select(.index == $IDX) | .bit_rate // 128000")
    
    if [[ ! "$SRC_BITRATE" =~ ^[0-9]+$ ]]; then SRC_BITRATE=128000; fi
    T_BITRATE=$(( SRC_BITRATE > 128000 ? 128000 : SRC_BITRATE ))
    T_BITRATE_K="$(( T_BITRATE / 1000 ))k"

    F_NAME="[a$ST_COUNT]"
    CHAIN="[0:$IDX]aresample=resampler=soxr:precision=28:async=1000"
    [ "$CHANNELS" -gt 2 ] && CHAIN+=",pan=stereo|FL=0.5*FC+0.707*FL+0.5*BL+0.5*LFE|FR=0.5*FC+0.707*FR+0.5*BR+0.5*LFE"
    CHAIN+=",afftdn=nr=12:nf=-45,loudnorm=I=-23:LRA=20:TP=-1.5:linear=true,alimiter=limit=-0.3dB"
    
    FILTER_COMPLEX+="$CHAIN$F_NAME;"
    AUDIO_MAPS+=("-map" "$F_NAME")
    AUDIO_OPTS+=("-b:a:$ST_COUNT" "$T_BITRATE_K" "-metadata:s:a:$ST_COUNT" "language=$LANG")
    ((ST_COUNT++))
done

# --- FFmpeg Command construction ---
CMD=("ffmpeg" "-hide_banner" "-loglevel" "info" "-thread_queue_size" "2048")
CMD+=("-analyzeduration" "500M" "-probesize" "500M" "-fflags" "+genpts")

if [ "$ENCODER_TYPE" != "copy" ] && [ "$USE_HWACCEL" = true ]; then
    CMD+=("-hwaccel" "qsv" "-hwaccel_output_format" "qsv")
fi
CMD+=("-i" "file:$INPUT_VIDEO")

if [ "$ENCODER_TYPE" = "copy" ]; then
    CMD+=("-c:v" "copy")
else
    CMD+=("-c:v" "$ENCODER_CMD")
    CMD+=("-global_quality:v" "$GLOBAL_QUALITY" "-preset" "veryslow")
    CMD+=("-look_ahead" "1" "-look_ahead_depth" "80" "-extbrc" "1")
    CMD+=("-g" "$GOP_SIZE" "-bf" "7" "-refs" "5" "-low_power" "0")
    [ "$ENCODER_TYPE" = "av1" ] && CMD+=("-tile_cols" "2" "-tile_rows" "2" "-adaptive_i" "1" "-adaptive_b" "1")
    
    # Valid Color Metadata Only
    [[ "$V_COLOR_PRI" =~ ^(bt709|bt2020|smpte170m)$ ]] && CMD+=("-color_primaries" "$V_COLOR_PRI")
    [[ "$V_COLOR_TRC" =~ ^(bt709|smpte2084|arib-std-b67)$ ]] && CMD+=("-color_trc" "$V_COLOR_TRC")
    [[ "$V_COLOR_SPC" =~ ^(bt709|bt2020nc|bt2020c)$ ]] && CMD+=("-colorspace" "$V_COLOR_SPC")
    
    if mediainfo --Inform="Video;%ScanType%" "$INPUT_VIDEO" | grep -q "Interlaced"; then
        CMD+=("-vf" "deinterlace_qsv")
    fi
fi

CMD+=("-map" "0:v:0" "${AUDIO_MAPS[@]}" "-map" "0:s?" "-map_chapters" "0" "-map_metadata" "0")
[ -n "$FILTER_COMPLEX" ] && CMD+=("-filter_complex" "${FILTER_COMPLEX%;}")
CMD+=("-c:a" "libopus" "${AUDIO_OPTS[@]}" "-vbr" "on" "-application" "audio")
CMD+=("-c:s" "copy" "-max_muxing_queue_size" "8192")
CMD+=("-movflags" "+faststart" "-fps_mode" "cfr" "file:$TEMP_OUTPUT")

# --- Execution ---
log_message "Executing: ${CMD[*]}"
"${CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
FF_EXIT=${PIPESTATUS[0]}

# --- Verification ---
if [ $FF_EXIT -ne 0 ]; then
    log_message "FFmpeg reported failure (Exit Code: $FF_EXIT). Aborting replacement."
    exit 1
fi

if [ ! -f "$TEMP_OUTPUT" ] || [ $(du -m "$TEMP_OUTPUT" | cut -f1) -lt $MIN_OUTPUT_SIZE_MB ]; then
    log_message "Error: Output file invalid or too small. Aborting replacement."
    exit 1
fi

I_SIZE=$(du -b "$INPUT_VIDEO" | cut -f1)
O_SIZE=$(du -b "$TEMP_OUTPUT" | cut -f1)

if [ "$O_SIZE" -lt "$I_SIZE" ] || [ "$ENCODER_TYPE" == "copy" ]; then
    mkvpropedit "$TEMP_OUTPUT" --add-track-statistics-tags
    mv "$TEMP_OUTPUT" "${INPUT_VIDEO%.*}.mkv"
    [ "${INPUT_VIDEO##*.}" != "mkv" ] && rm "$INPUT_VIDEO"
    log_message "Success: Encoded file replaced original."
else
    log_message "No savings ($O_SIZE >= $I_SIZE). Keeping original."
fi

exit 0
