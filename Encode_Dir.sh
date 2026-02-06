#!/bin/bash

# Default extension
EXT="mkv"
ENCODER="~/scripts/Encode.sh"
CODEC="AV1"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hevc)
            ENCODER="~/scripts/Encode_HEVC.sh"
            CODEC="HEVC"
            shift
            ;;
        --audio-only)
            ENCODER="~/scripts/Audio_Only.sh"
            CODEC="Audio"
            shift
            ;;
        *)
            EXT=$(echo "$1" | tr '[:upper:]' '[:lower:]')
            shift
            ;;
    esac
done

# Find and encode all files with the specified extension (case-insensitive)
find . -type f -iregex ".*\\.$EXT" -exec "$ENCODER" {} \;

echo "Encoding complete for all *.$EXT files (case-insensitive) in the current directory and subdirectories using $CODEC."
