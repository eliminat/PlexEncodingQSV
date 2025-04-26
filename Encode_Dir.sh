#!/bin/bash

# Default extension
EXT="mkv"

# Check if an argument is provided
if [ $# -eq 1 ]; then
    EXT=$(echo "$1" | tr '[:upper:]' '[:lower:]')
fi

# Find and encode all files with the specified extension (case-insensitive for both extension and filename)
find . -type f -iregex ".*\.$EXT" -exec /home/eliminat/scripts/Encode.sh {} \;

echo "Encoding complete for all *.$EXT files (case-insensitive) in the current directory and subdirectories."

