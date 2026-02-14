#!/bin/bash

# ==============================================================================
# Library_Scanner.sh - Unified Plex Library Analysis (Optimized for HDD)
# ==============================================================================

# --- Configuration & Defaults ---
ENCODER="/home/eliminat/scripts/Universal_Encode.sh"
MIN_BPP_THRESHOLD="0.02"
SCAN_DIR="."
MODE="report"
OUTPUT_FILE=""
INPUT_FILE=""
SKIP_ENCODED=true
PARALLEL_JOBS=8
LIMIT=0
ONLY_RES="" # Filter for specific tier (SD, 720p, 1080p, 2K, 4K, NON_STD)

# --- Usage ---
usage() {
    echo "Usage: $0 [directory] [options]"
    echo ""
    echo "Modes:"
    echo "  --report           Generate a detailed library report (Default)"
    echo "  --recommend        Generate recommendation hit-list"
    echo "  --auto             Auto-encode recommendations"
    echo ""
    echo "Filters:"
    echo "  --only-res <tier>  Only process specific tier (SD, 1080p, 4K, NON_STD, etc.)"
    echo "  --limit <n>        Stop after <n> files"
    echo "  --all              Don't skip AV1/HEVC files"
    echo ""
    echo "I/O:"
    echo "  --input <file>     Load a previous recommendation file for --auto mode"
    echo "  --output <file>    Save results to a file"
    exit 1
}

# --- Parse Arguments ---
[ $# -eq 0 ] && usage
SCAN_DIR="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --report) MODE="report"; shift ;;
        --recommend) MODE="recommend"; shift ;;
        --auto) MODE="auto"; shift ;;
        --only-res) ONLY_RES="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --all) SKIP_ENCODED=false; shift ;;
        --input) INPUT_FILE="$2"; shift 2 ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[ -n "$OUTPUT_FILE" ] && exec > >(tee -a "$OUTPUT_FILE")

analyze_file() {
    local file="$1"
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    local probe=$(ffprobe -v error -show_streams -show_format -of json "$file" 2>/dev/null)
    [ -z "$probe" ] && return 1

    local v_stream=$(echo "$probe" | jq -r '.streams[] | select(.codec_type=="video")')
    local v_codec=$(echo "$v_stream" | jq -r '.codec_name')
    local width=$(echo "$v_stream" | jq -r '.width')
    local height=$(echo "$v_stream" | jq -r '.height')
    local fps_raw=$(echo "$v_stream" | jq -r '.r_frame_rate')
    local bitrate=$(echo "$probe" | jq -r '.format.bit_rate // empty')

    if [[ -z "$width" || "$width" == "null" || "$width" -eq 0 ]]; then return 3; fi
    
    # 1. Tiering logic
    local longest=$(( width > height ? width : height ))
    local tier="SD"; local rec_codec="--hevc"
    if [ "$longest" -ge 3800 ]; then tier="4K"; rec_codec="--av1";
    elif [ "$longest" -ge 2000 ]; then tier="2K"; rec_codec="--av1";
    elif [ "$longest" -ge 1900 ]; then tier="1080p"; rec_codec="--av1";
    elif [ "$longest" -ge 1200 ]; then tier="720p"; rec_codec="--av1"; fi

    # --- Extension Check (Override Tier) ---
    if [[ "$ext" != "mp4" && "$ext" != "mkv" ]]; then
        tier="NON_STD"
        # Preserve existing resolution logic for encoder choice
    fi

    # Filter by specific resolution if requested
    if [ -n "$ONLY_RES" ] && [ "$tier" != "$ONLY_RES" ]; then return 4; fi

    # Skip logic (Unless NON_STD, we skip if already modern codec)
    if [ "$SKIP_ENCODED" = true ] && [[ "$tier" != "NON_STD" ]]; then
        if [[ "$v_codec" == "av1" || "$v_codec" == "hevc" ]]; then return 2; fi
    fi

    # 2. Quality Logic (BPP)
    local fps=$(echo "scale=2; $fps_raw" | bc -l 2>/dev/null)
    [[ -z "$fps" || "$fps" == "0" ]] && fps="24"
    local bpp="0"; local elig="YES"; local reason="Codec: $v_codec"

    if [[ "$tier" == "NON_STD" ]]; then
        elig="YES"
        reason="Incompatible container (.$ext). Re-encode to MKV recommended."
    elif [[ -n "$bitrate" && "$bitrate" != "null" ]]; then
        bpp=$(echo "scale=6; $bitrate / ($width * $height * $fps)" | bc -l)
        if (( $(echo "$bpp < $MIN_BPP_THRESHOLD" | bc -l) )); then
            elig="LOW_QUALITY"; reason="Low BPP ($bpp)";
        fi
    else elig="UNKNOWN"; reason="Bitrate unknown"; fi

    echo "$file|$tier|$v_codec|$elig|$rec_codec|$reason"
}

export -f analyze_file
export MIN_BPP_THRESHOLD SKIP_ENCODED ONLY_RES

# --- Scan Loop ---
echo "Scanning $SCAN_DIR (Max Jobs: $PARALLEL_JOBS)..."

if [[ "$MODE" == "auto" && -n "$INPUT_FILE" ]]; then
    while IFS='|' read -r file tier codec elig rec_codec reason; do
        if [[ "$elig" == "YES" ]]; then
            echo "--- Automatically Queuing: $file ($reason) ---"
            "$ENCODER" "$rec_codec" "$file"
        fi
    done < "$INPUT_FILE"
    exit 0
fi

# We look for ALL common video extensions to catch legacy files
find "$SCAN_DIR" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.flv" -o -iname "*.ts" \) -print0 | \
{
    count=0
    while IFS= read -r -d '' file; do
        ((count++))
        if [ "$LIMIT" -ne 0 ] && [ "$count" -gt "$LIMIT" ]; then break; fi
        
        (
            result=$(analyze_file "$file")
            status=$?
            if [ $status -eq 0 ]; then
                IFS='|' read -r f_path f_tier f_codec f_elig f_rec f_reason <<< "$result"
                case "$MODE" in
                    report) printf "[%-7s] %-10s | %-11s | %s\n" "$f_tier" "$f_codec" "$f_elig" "$f_path" ;;
                    recommend) [[ "$f_elig" == "YES" ]] && echo "$f_path|$f_tier|$f_codec|$f_elig|$f_rec|$f_reason" ;;
                    auto) [[ "$f_elig" == "YES" ]] && "$ENCODER" "$f_rec" "$file" ;;
                esac
            fi
        ) &

        if [[ $(jobs -r | wc -l) -ge $PARALLEL_JOBS ]]; then wait -n; fi
    done
    wait
}

echo "Scan Complete."
