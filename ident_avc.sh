#!/bin/bash

# Usage: ./ident_avc.sh [directory] [encode_format]
# encode_format: av1 or hevc

# Default to current working directory if no directory is specified
folder="${1:-.}"

# Check if encoding format is specified and valid
encode_format=""
if [ -n "$2" ]; then
    if [ "$2" = "av1" ]; then
        encode_format="av1"
    elif [ "$2" = "hevc" ]; then
        encode_format="hevc"
    else
        echo "Unknown encoding format: $2" >&2
        echo "Usage: $0 [directory] [av1|hevc]" >&2
        exit 1
    fi
fi

# Recursively find all files, handle all special characters robustly
find "$folder" -type f -print0 | while IFS= read -r -d '' file; do
    # Check if file is readable
    [[ -r "$file" ]] || continue

    # Use ffprobe to get the codec of the first video stream
    codec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null)

    # If codec is h264 (AVC), process file
    if [[ "$codec" == "h264" ]]; then
        if [ "$encode_format" = "av1" ]; then
            echo "Encoding to AV1: $file"
            Encode.sh "$file"
        elif [ "$encode_format" = "hevc" ]; then
            echo "Encoding to HEVC: $file"
            Encode_HEVC.sh "$file"
        else
            echo "$file"
        fi
    fi
done
