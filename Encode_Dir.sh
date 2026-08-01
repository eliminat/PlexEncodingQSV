#!/bin/bash

# ==============================================================================
# Encode_Dir.sh - Batch wrapper for Encode.sh
# ==============================================================================

# Default settings
EXT="mkv|avi"
DIR="."
FLAGS=()

# Exit cleanly if user presses Ctrl+C (SIGINT) or sends SIGTERM
trap "echo ''; echo 'Batch processing aborted by user.'; exit 130" INT TERM

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir|-d)
            DIR="$2"
            if [[ ! -d "$DIR" ]]; then
                echo "Error: Directory does not exist: $DIR" >&2
                exit 1
            fi
            shift 2
            ;;
        --hevc)
            FLAGS+=("--hevc")
            shift
            ;;
        --copy-video|--audio-only)
            FLAGS+=("--copy-video")
            shift
            ;;
        --quality)
            FLAGS+=("--quality" "$2")
            shift 2
            ;;
        -*)
            # Pass any other flags (like --quality) directly to the encoder
            FLAGS+=("$1")
            shift
            ;;
        *)
            # Last non-flag argument is treated as the extension or directory
            if [[ "$1" == */* || "$1" == "." || "$1" == ".." ]]; then
                DIR="$1"
                if [[ ! -d "$DIR" ]]; then
                    echo "Error: Directory does not exist: $DIR" >&2
                    exit 1
                fi
            elif [[ -d "$1" && ! "$1" =~ ^(mkv|avi|mp4|m4v|mov|flv|webm|wmv)$ ]]; then
                DIR="$1"
            else
                VAL="${1,,}"
                EXT="${VAL//,/|}"
            fi
            shift
            ;;
    esac
done

ENCODER="/home/eliminat/scripts/Encode.sh"

# Find and encode all files with the specified extension (case-insensitive)
# Using -print0 and read -d '' for absolute filename safety
while IFS= read -r -d '' file; do
    log_file="/plexdb/plexlogs/batch_process.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Batch processing: $file" | tee -a "$log_file"
    "$ENCODER" "${FLAGS[@]}" "$file" < /dev/null
    # If encoder was interrupted by Ctrl+C, exit the loop immediately
    if [[ $? -eq 130 ]]; then
        exit 130
    fi
done < <(find "$DIR" -regextype posix-extended -type f -iregex ".*\\.(${EXT})" -print0)

echo "Batch processing complete."
