#!/bin/bash

# Directory to scan, default to current directory if not provided
SCAN_DIR="${1:-.}"

# Find video files recursively (add/remove extensions as needed)
find "$SCAN_DIR" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.avi" \) | while read -r file; do
    # Extract width and height using mediainfo
    width=$(mediainfo --Inform="Video;%Width%" "$file")
    height=$(mediainfo --Inform="Video;%Height%" "$file")

    # Skip if width or height is missing
    if [[ -z "$width" || -z "$height" ]]; then
        continue
    fi

    # Check for valid 1080p resolutions (1920x1080 or 1920x800)
   if [[ "$width" -ge 1875 && "$height" -ge 695 ]]; then
        # This is "close enough" to 1080p, skip it
        continue
    fi

    # If here, this is lower than 1080p
    echo "$file (resolution: ${width}x${height})"
done
