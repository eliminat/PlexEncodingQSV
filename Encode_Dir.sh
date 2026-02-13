#!/bin/bash

# ==============================================================================
# Encode_Dir.sh - Batch wrapper for Universal_Encode.sh
# ==============================================================================

# Default settings
EXT="mkv"
FLAGS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
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
            # Last non-flag argument is treated as the extension
            EXT=$(echo "$1" | tr '[:upper:]' '[:lower:]')
            shift
            ;;
    esac
done

ENCODER="/home/eliminat/scripts/Universal_Encode.sh"

# Find and encode all files with the specified extension (case-insensitive)
# Using -print0 and read -d '' for absolute filename safety
find . -type f -iregex ".*\\.$EXT" -print0 | while IFS= read -r -d '' file; do
    log_file="/plexdb/plexlogs/batch_process.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Batch processing: $file" | tee -a "$log_file"
    "$ENCODER" "${FLAGS[@]}" "$file"
done

echo "Batch processing complete."
