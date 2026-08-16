#!/bin/bash
# ==============================================================================
# Encode.sh (Audited, Optimized, & Fully Documented)
# Unified Intel Arc A380 QSV Encoding Pipeline for Plex / Media Archiving
#
# Hardware Assumptions:
#   - CPU: AMD Ryzen 5 5500 (6 Cores, 12 Threads) - Lacks integrated graphics.
#   - GPU: Discrete Intel Arc A380 (Sparkle Elf 6GB GDDR6, Resizable BAR active).
#   - Driver: Legally constrained to 'i915' kernel driver for system stability.
#   - OS/Kernel: Linux 7.0.9 CachyOS, glibc 2.43.
#
# System Characteristics:
#   - Strictly single-concurrency via global flock file descriptor lock.
#   - Prioritizes maximum quality above all (80 lookahead depth, ICQ=25).
#   - Fully handles 10-bit H.264 software decode fallbacks without crashes.
# ==============================================================================

# --- Pre-flight Checks ---
# Ensure all critical binaries are available on the PATH prior to execution.
for TOOL in ffmpeg ffprobe jq bc mediainfo mkvpropedit; do
    if ! command -v "$TOOL" &>/dev/null; then
        echo "Error: Required tool '$TOOL' is not installed or not in PATH." >&2
        exit 1
    fi
done

# --- Usage Validation ---
if [ $# -eq 0 ]; then
    echo "Usage: $0 [--hevc | --copy-video | --copy-only] <input_file>"
    exit 1
fi

# Default Configuration Variables
ENCODER_TYPE="av1"                     # Target container codec (default is AV1)
ENCODER_CMD="av1_qsv"                  # Intel QuickSync (QSV) AV1 encoder binary
GLOBAL_QUALITY=25                      # Base Intelligent Constant Quality (ICQ) target
QUALITY_SET=false                      # Track if quality was explicitly set by user
MIN_OUTPUT_SIZE_MB=10                  # Safe size threshold to prevent replacing original with empty files
LOCK_FILE="/plexdb/plexlogs/plex_encoding.lock" # Global concurrency lock location
LOCK_TIMEOUT=$((8 * 3600))             # 8-hour timeout for queueing encodes
LOCK_WAIT_INTERVAL=300                 # Sleep interval (5 minutes) when waiting in queue

# --- Command Line Argument Parser ---
INPUT_VIDEO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hevc) 
            ENCODER_TYPE="hevc"
            ENCODER_CMD="hevc_qsv"
            shift 
            ;;
        --copy-video|--copy-only) 
            ENCODER_TYPE="copy"
            ENCODER_CMD="copy"
            shift 
            ;;
        --quality) 
            GLOBAL_QUALITY="$2"
            QUALITY_SET=true
            shift 2 
            ;;
        --*) 
            echo "Error: Unknown option $1"
            exit 1 
            ;;
        *) 
            INPUT_VIDEO="$1"
            shift 
            ;;
    esac
done

# Resolve absolute path for input to prevent issues with relative folder changes.
INPUT_VIDEO=$(realpath "$INPUT_VIDEO")

if [[ ! -f "$INPUT_VIDEO" ]]; then
    echo "Error: Input file does not exist: $INPUT_VIDEO"
    exit 1
fi

VIDEO_NAME=$(basename "$INPUT_VIDEO")
VIDEO_NAME_NO_EXT="${VIDEO_NAME%.*}"
LOG_FILE="/plexdb/plexlogs/${VIDEO_NAME_NO_EXT}_${ENCODER_TYPE}_encode_log.txt"

# Temporary transcode output target (removed on failure/cleanup, promoted on success)
TEMP_OUTPUT="/plexdb/plexlogs/temp/${VIDEO_NAME_NO_EXT}_temp_${ENCODER_TYPE}.mkv"

# --- Infrastructure Setup ---
mkdir -p /plexdb/plexlogs/temp

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Cleanup Routine: Executed on exit, interruption, or termination.
# Deletes leftover temp files and releases the file descriptor lock.
cleanup() {
    log_message "Cleanup: Removing temp files and releasing lock"
    [ -f "$TEMP_OUTPUT" ] && rm -f "$TEMP_OUTPUT"
    flock -u 100 2>/dev/null
}
trap cleanup EXIT INT TERM

# --- Lock Acquisition (Concurrency Gate) ---
# Opens the lock file under file descriptor 100.
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

# Probing video properties (codec, profile, pixel format, frame rate, colorspace, and resolution)
V_JSON=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile,pix_fmt,r_frame_rate,color_primaries,color_transfer,color_space,width,height -of json "$INPUT_VIDEO")

if [[ -z "$V_JSON" || "$V_JSON" == "{}" ]]; then
    log_message "Error: Failed to probe video stream for $VIDEO_NAME"
    exit 1
fi

V_CODEC=$(echo "$V_JSON" | jq -r '.streams[0].codec_name // empty')
V_PROFILE=$(echo "$V_JSON" | jq -r '.streams[0].profile // empty')
V_PIX_FMT=$(echo "$V_JSON" | jq -r '.streams[0].pix_fmt // empty')
V_FPS_RAW=$(echo "$V_JSON" | jq -r '.streams[0].r_frame_rate // empty')
V_COLOR_PRI=$(echo "$V_JSON" | jq -r '.streams[0].color_primaries // empty')
V_COLOR_TRC=$(echo "$V_JSON" | jq -r '.streams[0].color_transfer // empty')
V_COLOR_SPC=$(echo "$V_JSON" | jq -r '.streams[0].color_space // empty')
V_WIDTH=$(echo "$V_JSON" | jq -r '.streams[0].width // empty')
V_HEIGHT=$(echo "$V_JSON" | jq -r '.streams[0].height // empty')

if [[ -z "$V_CODEC" ]]; then
    log_message "Error: Could not determine video codec for $VIDEO_NAME"
    exit 1
fi

# Fallback defaults for video dimensions if probe data is missing.
if [[ -z "$V_WIDTH" ]]; then V_WIDTH=1920; fi
if [[ -z "$V_HEIGHT" ]]; then V_HEIGHT=1080; fi

# Detect if the video is black and white (monochrome)
IS_BW=false
if [[ "$V_PIX_FMT" == gray* ]]; then
    IS_BW=true
    log_message "Format metadata confirmed: Video is grayscale."
else
    # Determine a safe seek point (avoiding black screens in intros)
    SEEK_POINT=60
    DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT_VIDEO" | cut -d'.' -f1)
    if [[ "$DURATION" =~ ^[0-9]+$ ]]; then
        if [ "$DURATION" -le 120 ]; then
            SEEK_POINT=$(( DURATION / 5 ))
        else
            SEEK_POINT=120
        fi
    fi

    log_message "Analyzing color saturation at ${SEEK_POINT}s to detect B&W content..."
    SATAVG=$(ffmpeg -nostdin -ss "$SEEK_POINT" -t 2 -i "$INPUT_VIDEO" -vf signalstats,metadata=print:key=lavfi.signalstats.SATAVG -f null - 2>&1 | \
             grep "lavfi.signalstats.SATAVG" | cut -d'=' -f2 | \
             awk '{sum+=$1; count++} END {if (count > 0) print sum/count; else print -1}')

    if (( $(echo "$SATAVG >= 0 && $SATAVG < 0.5" | bc -l) )); then
        IS_BW=true
        log_message "Visual analysis confirmed: Video is Black & White (SATAVG: $SATAVG)."
    else
        log_message "Visual analysis confirmed: Video is Color (SATAVG: $SATAVG)."
    fi
fi

# Auto-adjust quality for 4K B&W content if not explicitly overridden by the user and not in copy mode
if [ "$QUALITY_SET" = false ] && [ "$ENCODER_TYPE" != "copy" ] && [[ "$V_HEIGHT" -gt 1080 ]] && [ "$IS_BW" = true ]; then
    GLOBAL_QUALITY=28
    log_message "4K B&W video detected: Adjusting default quality target to 28."
fi

# Handle FPS and GOP (Group of Pictures)
# Uses 'bc' to calculate exact frame rates.
# Forces scale=0 to drop decimals and ensure a clean integer GOP size (10-second target).
V_FPS=$(echo "scale=2; $V_FPS_RAW" | bc -l)
GOP_SIZE=$(echo "scale=0; ($V_FPS * 10) / 1" | bc 2>/dev/null)
if [[ -z "$GOP_SIZE" ]] || [[ "$GOP_SIZE" -le 0 ]]; then GOP_SIZE=240; fi

# Hardware Acceleration Decision Tree
# Strategy: Hardware capability whitelist for Intel Arc A380 (DG2/Xe).
#
# IMPORTANT: ffmpeg's '-decoders' list is NOT a reliable capability check. Codecs like
# 'vc1_qsv' are compiled into ffmpeg via oneVPL/libmfx and appear in the decoder list,
# but the Arc DG2 GPU cannot execute them at runtime, producing:
#   "Error querying IO surface: unsupported (-3)"
#   "Error submitting packet to decoder: Function not implemented"
#
# The only reliable guard is an explicit whitelist of what Arc DG2 can actually decode.
# Source: Intel Arc/Xe HW capabilities (no VC-1, no VP6/7, no legacy codecs).
# Ref: https://www.intel.com/content/www/us/en/docs/onevpl/developer-reference-media-intel-hardware/1-1/overview.html
#
# To update this list for a different GPU, run:
#   ffmpeg -init_hw_device qsv=hw -f lavfi -i testsrc=duration=0.1 \
#     -vf hwupload,hwdownload -c:v <codec>_qsv -f null - 2>&1
# and verify each codec actually completes without 'IO surface: unsupported'.
declare -A QSV_HW_DECODABLE=(
    ["h264"]=1 ["hevc"]=1 ["av1"]=1 ["vp9"]=1
    ["vp8"]=1  ["mpeg2video"]=1 ["mjpeg"]=1
)

USE_HWACCEL=true
if [[ -z "${QSV_HW_DECODABLE[$V_CODEC]+_}" ]]; then
    USE_HWACCEL=false
    log_message "Codec '$V_CODEC' is not in the Arc DG2 QSV hw-decode whitelist: Using software decode fallback."
elif [[ "$V_CODEC" == "h264" ]] && [[ "$V_PROFILE" == "High 10" || "$V_PIX_FMT" == "yuv420p10le" ]]; then
    USE_HWACCEL=false
    log_message "H.264 High 10 / 10-bit detected: QSV unsupported on Arc DG2. Using software decode fallback."
fi

# --- Smart Stream Mapping Engine ---
AUDIO_MAPS=()
AUDIO_OPTS=()
ST_COUNT=0

# Probe stream directories for all audio and subtitle components.
A_JSON=$(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language:stream=channels:stream=bit_rate -of json "$INPUT_VIDEO")
S_JSON=$(ffprobe -v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language -of json "$INPUT_VIDEO")

# Helper function to extract stream indices matching a target language tag.
get_audio_indices() {
    echo "$A_JSON" | jq -r ".streams[] | select(.tags.language != null and (.tags.language | test(\"$1\"; \"i\"))) | .index"
}

# Enforce Language Ordering Priority (English -> Japanese -> Undefined/Fallback).
ENG_A_STREAMS=$(get_audio_indices "eng")
JPN_A_STREAMS=$(get_audio_indices "jpn")
UND_A_STREAMS=$(echo "$A_JSON" | jq -r '.streams[] | select(.tags.language == null or .tags.language == "und") | .index')

# Deduplicate audio streams while strictly preserving priority order.
ALL_A_STREAMS=$(printf "%s\n%s\n%s" "$ENG_A_STREAMS" "$JPN_A_STREAMS" "$UND_A_STREAMS" | grep -v '^$' | awk '!x[$0]++')

# Fallback: if no priority matches are found, process all available audio streams.
[ -z "$ALL_A_STREAMS" ] && ALL_A_STREAMS=$(echo "$A_JSON" | jq -r '.streams[].index')

# --- Audio Filtergraph Construction (2-Pass Linear Loudness Engine) ---
# Implements EBU R128 (-23 LUFS / -1.5 dBTP) with full dynamic range preservation.
# Pass 1: Measures integrated loudness, true peak, LRA, threshold, and offset via loudnorm JSON.
# Pass 2: Applies exact linear gain scaling using pre-measured values (linear=true).
FILTER_COMPLEX=""
for IDX in $ALL_A_STREAMS; do
    CHANNELS=$(echo "$A_JSON" | jq -r ".streams[] | select(.index == $IDX) | .channels")
    LANG=$(echo "$A_JSON" | jq -r ".streams[] | select(.index == $IDX) | .tags.language // \"und\"")
    SRC_BITRATE=$(echo "$A_JSON" | jq -r ".streams[] | select(.index == $IDX) | .bit_rate // 128000")

    # If source bitrate cannot be determined, fallback to standard 128kbps.
    if [[ ! "$SRC_BITRATE" =~ ^[0-9]+$ ]]; then SRC_BITRATE=128000; fi
    
    # Cap target audio bitrate at 128k (highly transparent for Opus stereo downmixes).
    T_BITRATE=$(( SRC_BITRATE > 128000 ? 128000 : SRC_BITRATE ))
    T_BITRATE_K="$(( T_BITRATE / 1000 ))k"

    # Build pre-normalization filter chain: soxr resampler + optional stereo downmix + afftdn denoiser.
    PRE_CHAIN="aresample=resampler=soxr:precision=28:async=1000"
    [ "$CHANNELS" -gt 2 ] && PRE_CHAIN+=",pan=stereo|FL=0.5*FC+0.707*FL+0.5*BL+0.5*LFE|FR=0.5*FC+0.707*FR+0.5*BR+0.5*LFE"
    PRE_CHAIN+=",afftdn=nr=12:nf=-45"

    # --- Pass 1: Loudness Measurement Probe (audio-only, no GPU, no disk output) ---
    log_message "Measuring audio loudness (Pass 1) for stream $IDX ($LANG)..."
    RAW_PROBE=$(ffmpeg -hide_banner -nostdin -i "file:$INPUT_VIDEO" \
        -filter_complex "[0:$IDX]${PRE_CHAIN},loudnorm=I=-23:LRA=20:TP=-1.5:print_format=json[a]" \
        -map "[a]" -vn -sn -dn -f null - 2>&1)
    PROBE_EXIT=$?

    if [[ $PROBE_EXIT -ne 0 ]]; then
        log_message "Error: Audio probe (Pass 1) failed on stream $IDX (Exit Code: $PROBE_EXIT). Aborting."
        exit 1
    fi

    # Extract the trailing JSON measurement block from ffmpeg stderr output.
    LOUDNORM_JSON=$(echo "$RAW_PROBE" | sed -n '/^{$/,/^}$/p' | tail -n 12)

    # Strict JSON validation guard: catch malformed or shifted output immediately.
    if ! echo "$LOUDNORM_JSON" | jq -e . >/dev/null 2>&1; then
        log_message "Error: Failed to parse valid loudnorm JSON from stream $IDX probe. Aborting."
        exit 1
    fi

    M_I=$(echo "$LOUDNORM_JSON" | jq -r '.input_i // empty')
    M_TP=$(echo "$LOUDNORM_JSON" | jq -r '.input_tp // empty')
    M_LRA=$(echo "$LOUDNORM_JSON" | jq -r '.input_lra // empty')
    M_THRESH=$(echo "$LOUDNORM_JSON" | jq -r '.input_thresh // empty')
    OFFSET=$(echo "$LOUDNORM_JSON" | jq -r '.target_offset // empty')

    # --- Pass 2 Filter Chain Decision ---
    # Silence Protection: If stream is pure silence (-inf), bypass loudnorm to prevent
    # AGC noise floor amplification. Route directly through the peak limiter.
    if [[ "$M_I" == "-inf" || "$M_I" == "inf" || -z "$M_I" ]]; then
        log_message "Notice: Stream $IDX measured as silent or non-finite (input_i: ${M_I:-empty}). Bypassing loudnorm."
        CHAIN="[0:$IDX]${PRE_CHAIN},alimiter=limit=0.8414:level=0"
    else
        # Finite Linear Normalization: Feed all 5 pre-measured values into loudnorm with linear=true.
        # This applies a single, exact mathematical gain offset across the entire stream,
        # preserving 100% of the original dynamic range without AGC pumping.
        #   alimiter: Peak limiter hard cap at -1.5 dBTP (linear value 0.8414 = 10^(-1.5/20)).
        #   level=0: Disables auto-leveling to prevent boosting quieter sections.
        log_message "Pass 1 Measured: I=${M_I} LUFS, TP=${M_TP} dBTP, LRA=${M_LRA} LU, Thresh=${M_THRESH} LUFS, Offset=${OFFSET} LU"
        CHAIN="[0:$IDX]${PRE_CHAIN},loudnorm=I=-23:LRA=20:TP=-1.5:measured_I=${M_I}:measured_TP=${M_TP}:measured_LRA=${M_LRA}:measured_thresh=${M_THRESH}:offset=${OFFSET}:linear=true,alimiter=limit=0.8414:level=0"
    fi

    # Assign unique filter label and append to filtergraph with clean delimiter (no trailing semicolons).
    F_NAME="[a$ST_COUNT]"
    [ -n "$FILTER_COMPLEX" ] && FILTER_COMPLEX+=";"
    FILTER_COMPLEX+="$CHAIN$F_NAME"
    AUDIO_MAPS+=("-map" "$F_NAME")
    AUDIO_OPTS+=("-b:a:$ST_COUNT" "$T_BITRATE_K" "-ar:a:$ST_COUNT" "48000" "-metadata:s:a:$ST_COUNT" "language=$LANG")
    ((ST_COUNT++))
done

# Subtitle Mapping (User Constraint: English-only subtitle streams preserved).
# Dynamic Transcoding: Convert incompatible 'mov_text' to 'srt' for Matroska compatibility.
SUB_MAPS=()
SUB_OPTS=()
ENG_S_DATA=$(echo "$S_JSON" | jq -r '.streams[] | select(.tags.language != null and (.tags.language | test("eng"; "i"))) | "\(.index):\(.codec_name)"' 2>/dev/null)
SUB_COUNT=0
for ENTRY in $ENG_S_DATA; do
    IDX=${ENTRY%%:*}
    CODEC=${ENTRY#*:}
    SUB_MAPS+=("-map" "0:$IDX")
    if [[ "$CODEC" == "mov_text" ]]; then
        SUB_OPTS+=("-c:s:$SUB_COUNT" "srt")
    else
        SUB_OPTS+=("-c:s:$SUB_COUNT" "copy")
    fi
    ((SUB_COUNT++))
done

# --- Resolution-Based Tiling Optimization Fork ---
# Optimizing AV1 tiling boundaries:
#   - 4K: 2x2 grid (4 tiles). Essential for multi-threaded parallel client software decoding.
#   - 1080p: 1x0 grid (2 horizontal tiles). Offers balanced FHD compression efficiency.
#   - 720p/below: 0x0 grid (1 tile). Disables tiling to maximize compression on small frames.
if [[ "$V_HEIGHT" -gt 1080 ]]; then
    TILE_OPTS=("-tile_cols:v" "2" "-tile_rows:v" "2")
elif [[ "$V_HEIGHT" -gt 720 ]]; then
    TILE_OPTS=("-tile_cols:v" "1" "-tile_rows:v" "0")
else
    TILE_OPTS=("-tile_cols:v" "0" "-tile_rows:v" "0")
fi

# --- FFmpeg Command Assembly ---
CMD=("ffmpeg" "-nostdin" "-hide_banner" "-loglevel" "info" "-thread_queue_size" "2048")
CMD+=("-analyzeduration" "500M" "-probesize" "500M" "-fflags" "+genpts")

# Initialize hardware device context node for QSV.
# Must be executed globally if encoding is active to prevent session initialization failures.
if [ "$ENCODER_TYPE" != "copy" ]; then
    CMD+=("-init_hw_device" "qsv=hw" "-filter_hw_device" "hw")
fi

# If using native hardware decode, configure QSV decoders.
# Allocates extra hardware frames (128 surfaces) to buffer the high lookahead depth (80 frames).
if [ "$ENCODER_TYPE" != "copy" ] && [ "$USE_HWACCEL" = true ]; then
    CMD+=("-hwaccel" "qsv" "-hwaccel_output_format" "qsv" "-extra_hw_frames" "128")
fi
CMD+=("-i" "file:$INPUT_VIDEO")

# --- Video Filter Chain Setup ---
VF_CHAIN=""
if [ "$ENCODER_TYPE" != "copy" ]; then
    # Deinterlacing Fork
    if mediainfo --Inform="Video;%ScanType%" "$INPUT_VIDEO" | grep -q "Interlaced"; then
        if [ "$USE_HWACCEL" = true ]; then
            VF_CHAIN="deinterlace_qsv"
        else
            # Swaps to software yadif filter if hardware fallback is active to prevent filtergraph crashes.
            VF_CHAIN="yadif=mode=0:parity=-1:deint=0"
        fi
    fi

    # For software decoding fallbacks, upload CPU frames to QSV VRAM surfaces.
    # Pre-allocates a fixed surface pool of 128 frames for the lookahead buffer.
    if [ "$USE_HWACCEL" = false ]; then
        if [ -n "$VF_CHAIN" ]; then
            VF_CHAIN="${VF_CHAIN},hwupload=extra_hw_frames=128,format=qsv"
        else
            VF_CHAIN="hwupload=extra_hw_frames=128,format=qsv"
        fi
    fi
fi

if [ -n "$VF_CHAIN" ]; then
    CMD+=("-vf" "$VF_CHAIN")
fi

# Set Video Encoder Options
if [ "$ENCODER_TYPE" = "copy" ]; then
    CMD+=("-c:v" "copy")
else
    CMD+=("-c:v" "$ENCODER_CMD")
    CMD+=("-global_quality:v" "$GLOBAL_QUALITY" "-preset" "veryslow")
    
    # Priority #1 Quality: Maintain 80-frame QSV lookahead depth for high-fidelity rate control.
    CMD+=("-look_ahead_depth:v" "80" "-extbrc:v" "1")
    CMD+=("-g:v" "$GOP_SIZE" "-bf:v" "7" "-refs:v" "5" "-low_power:v" "0")
    
    # AV1-specific configurations: Resolution-adaptive tiling and adaptive frame sizing.
    [ "$ENCODER_TYPE" = "av1" ] && CMD+=("${TILE_OPTS[@]}" "-adaptive_i:v" "1" "-adaptive_b:v" "1")

    # Enforce color primaries metadata mapping to prevent color shifting during playback.
    [[ "$V_COLOR_PRI" =~ ^(bt709|bt2020|smpte170m)$ ]] && CMD+=("-color_primaries" "$V_COLOR_PRI")
    [[ "$V_COLOR_TRC" =~ ^(bt709|smpte2084|arib-std-b67)$ ]] && CMD+=("-color_trc" "$V_COLOR_TRC")
    [[ "$V_COLOR_SPC" =~ ^(bt709|bt2020nc|bt2020c)$ ]] && CMD+=("-colorspace" "$V_COLOR_SPC")
fi

# Stream mapping and general muxing controls.
CMD+=("-map" "0:v:0" "${AUDIO_MAPS[@]}" "${SUB_MAPS[@]}" "-map_chapters" "0" "-map_metadata" "0")

[ -n "$FILTER_COMPLEX" ] && CMD+=("-filter_complex" "${FILTER_COMPLEX%;}")
CMD+=("-c:a" "libopus" "${AUDIO_OPTS[@]}" "-vbr" "on" "-application" "audio")
if [ "$ENCODER_TYPE" != "copy" ]; then
    CMD+=("${SUB_OPTS[@]}")
else
    CMD+=("-c:s" "copy")
fi
CMD+=("-max_muxing_queue_size" "8192")
if [[ "$TEMP_OUTPUT" == *.mp4 || "$TEMP_OUTPUT" == *.mov ]]; then
    CMD+=("-movflags" "+faststart")
fi
CMD+=("-fps_mode" "cfr" "file:$TEMP_OUTPUT")

# --- Execution Phase ---
log_message "Executing: ${CMD[*]}"

# Check if THP is active on the host kernel (either always or madvise).
# If so, export the GLIBC_TUNABLES flag to leverage Transparent Huge Pages (THP),
# which reduces CPU TLB misses and accelerates CPU-bound audio filters and deinterlacing.
THP_SETTING=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
if [[ "$THP_SETTING" == *"[always]"* ]] || [[ "$THP_SETTING" == *"[madvise]"* ]]; then
    log_message "THP enabled. Using GLIBC_TUNABLES for Huge Pages."
    export GLIBC_TUNABLES=glibc.malloc.hugetlb=1
fi

# Launch transcode pipeline, capture output, and capture PIPESTATUS exit code.
"${CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
FF_EXIT="${PIPESTATUS[0]}"

# --- Verification & Post-transcode Engine ---
if [ "${FF_EXIT:-0}" -ne 0 ]; then
    log_message "FFmpeg reported failure (Exit Code: ${FF_EXIT:-unknown}). Aborting replacement."
    exit "${FF_EXIT:-1}"
fi

# Prevent replacing movies with zero-byte or corrupt files by enforcing minimum size.
if [ ! -f "$TEMP_OUTPUT" ] || [ $(du -m "$TEMP_OUTPUT" | cut -f1) -lt $MIN_OUTPUT_SIZE_MB ]; then
    log_message "Error: Output file invalid or too small. Aborting replacement."
    exit 1
fi

I_SIZE=$(du -b "$INPUT_VIDEO" | cut -f1)
O_SIZE=$(du -b "$TEMP_OUTPUT" | cut -f1)

# Compile Size Reduction Metrics.
I_MB=$(( I_SIZE / 1024 / 1024 ))
O_MB=$(( O_SIZE / 1024 / 1024 ))
if [ "$I_SIZE" -gt 0 ]; then
    SAVED_PERCENT=$(echo "scale=2; ($I_SIZE - $O_SIZE) * 100 / $I_SIZE" | bc -l)
else
    SAVED_PERCENT="0.00"
fi
log_message "!!!!! Input size: ${I_MB}MB | Output size: ${O_MB}MB | Change: ${SAVED_PERCENT}% !!!!!"

# If size reduction achieved, swap the files.
if [ "$O_SIZE" -lt "$I_SIZE" ] || [ "$ENCODER_TYPE" == "copy" ]; then
    # Add track statistics tags to the Matroska container.
    mkvpropedit "$TEMP_OUTPUT" --add-track-statistics-tags
    
    TARGET_PATH="${INPUT_VIDEO%.*}.mkv"
    
    # Transactional File Replacement:
    # If the target path is identical to the input path (e.g. source is already MKV),
    # we move the original to a .bak backup file, write the new file to the target,
    # and only delete the backup once the move operations complete successfully.
    # On any failure, we immediately roll back the backup file to prevent data loss.
    if [ "$TARGET_PATH" = "$INPUT_VIDEO" ]; then
        BACKUP_PATH="${INPUT_VIDEO}.bak"
        log_message "Performing transactional replacement on MKV source..."
        if mv "$INPUT_VIDEO" "$BACKUP_PATH" && mv "$TEMP_OUTPUT" "$TARGET_PATH"; then
            rm -f "$BACKUP_PATH"
            log_message "Success: Encoded file replaced original."
        else
            log_message "Error: Failed replacing file. Restoring original from backup..."
            [ -f "$BACKUP_PATH" ] && mv "$BACKUP_PATH" "$INPUT_VIDEO"
            exit 1
        fi
    else
        # If changing container format (e.g. MP4 to MKV), copy temp output to target,
        # then delete the original MP4 input file.
        if mv "$TEMP_OUTPUT" "$TARGET_PATH"; then
            rm -f "$INPUT_VIDEO"
            log_message "Success: Encoded file created and original removed."
        else
            log_message "Error: Failed moving temp file to target."
            exit 1
        fi
    fi
else
    log_message "No savings ($O_SIZE >= $I_SIZE). Keeping original."
fi

exit 0
