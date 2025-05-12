# FFmpeg Video Encoding Scripts for Plex Media Server

This repository contains a collection of Bash scripts designed to automate video transcoding for Plex media servers using Intel Quick Sync Video (QSV) hardware acceleration. These scripts optimize video files for streaming while preserving quality and reducing file sizes.

## Overview

The scripts provide automated video transcoding functionality using either AV1 or HEVC (H.265) codecs with Intel QSV hardware acceleration. They handle various aspects of the encoding process, including deinterlacing detection, audio normalization, subtitle format conversion, and intelligent file replacement based on size comparison.

## Scripts Included

### 1. Encode.sh

This is the primary encoding script that processes individual video files using the AV1 codec via Intel QSV.

**Key Features:**
- Uses Intel QSV hardware acceleration with AV1 encoder
- Automatically detects and processes interlaced content
- Normalizes audio to stereo AAC at 256k with volume adjustment
- Handles subtitle format conversion for compatibility
- Implements file locking to prevent concurrent encoding jobs
- Only replaces original files if the new version is smaller
- Generates detailed logs of the encoding process
- Checks video duration to ensure complete encoding
- Implements advanced error detection

### 2. Encode_HEVC.sh

Similar to Encode.sh but uses the HEVC (H.265) codec instead of AV1.

**Key Features:**
- Utilizes Intel QSV hardware acceleration with HEVC encoder
- Shares the same intelligent processing features as Encode.sh
- Optimized encoding parameters for HEVC compression
- Suitable for devices with better HEVC than AV1 compatibility

### 3. Encode_Dir.sh

A utility script that recursively processes all video files of a specified format in a directory tree.

**Key Features:**
- Finds all files with a specified extension (default: .mkv)
- Case-insensitive file matching
- Recursively searches subdirectories
- Passes each matching file to Encode.sh for processing

## Requirements

- Linux-based system
- Intel CPU with Quick Sync Video support
- FFmpeg compiled with Intel QSV support
- MediaInfo for interlaced content detection
- BC (basic calculator) for percentage calculations
- At least 10MB of free space in the `/plexdb/plexlogs/temp` directory

## Usage

### Processing a Single File

To encode a single video file using AV1:

    /path/to/Encode.sh /path/to/your/video.mp4

To encode using HEVC instead:

    /path/to/Encode_HEVC.sh /path/to/your/video.mp4

### Processing Multiple Files

To encode all MKV files in the current directory and subdirectories:

    /path/to/Encode_Dir.sh

To process files with a different extension (e.g., MP4):

    /path/to/Encode_Dir.sh mp4

## How It Works

1. When you run an encoding script on a video file, it first checks if another encoding process is running using a lock file.
2. The script analyzes the video to determine if it's interlaced, and applies appropriate deinterlacing filters if needed.
3. FFmpeg is then used with optimized encoding parameters to transcode the video to either AV1 or HEVC format.
4. Audio is downmixed to stereo, normalized, and encoded as AAC at 256kbps.
5. Incompatible subtitle formats are converted to SRT for better compatibility.
6. After encoding, the script compares the size of the original and encoded files.
7. If the encoded file is smaller (and above a minimum size threshold), it replaces the original file; otherwise, it keeps the original and deletes the encoded version.
8. Detailed logs are generated throughout the process in the `/plexdb/plexlogs` directory.

## Encoding Parameters

Both scripts use carefully optimized encoding parameters:

### AV1 Encoding (Encode.sh)
- Encoder: av1_qsv
- Global quality: 25
- Preset: veryslow
- Extended bitrate control: enabled
- Look-ahead depth: 88
- Adaptive I-frames and B-frames: enabled
- Temporal and spatial adaptive quantization: enabled
- B-frames: 7
- GOP size: 180
- Low power mode: disabled

### HEVC Encoding (Encode_HEVC.sh)
- Encoder: hevc_qsv
- Global quality: 25
- Preset: veryslow
- Profile: main
- Look-ahead depth: 40
- Extended bitrate control: enabled

## Important Notes

- The scripts use a locking mechanism to prevent multiple encoding jobs from running simultaneously, which could overload your system.
- If an encoding job fails to acquire the lock after 8 hours of waiting, it will exit automatically.
- The scripts verify output duration matches input duration to ensure complete encoding.
- Original files are only replaced if the encoded version is smaller and above a minimum size threshold (10MB).
- The scripts convert all output files to MKV container format.
- Detailed logs are stored in `/plexdb/plexlogs` with filenames that include the original filename, encoder, and quality settings.
- Error detection is set to "aggressive" to catch potential issues during the encoding process.

## Customization

You may want to adjust the following parameters in the scripts for your specific needs:

- `global_quality`: Lower values produce higher quality but larger files
- `min_output_size_mb`: Minimum acceptable size for encoded files
- `LOCK_TIMEOUT`: Maximum wait time for acquiring the encoding lock
- Audio encoding parameters like bitrate and normalization levels
- Thread queue size and hardware acceleration parameters for specific hardware configurations

## Using as a Plex Post-Processing Script

These scripts can be used as post-processing scripts in Plex DVR settings:

1. Set up Plex DVR to record your TV shows
2. In the DVR settings, find the post-processing script option
3. Enter the full path to the Encode.sh or Encode_HEVC.sh script
4. Plex will automatically pass recorded shows to the script for processing after recording is complete

This allows automatic conversion of recorded content to save space while maintaining quality.

## Troubleshooting

- If encoding fails, check the log files in `/plexdb/plexlogs/` for specific error messages
- Ensure your Intel CPU supports QSV for the codec you're trying to use
- Verify that FFmpeg is compiled with proper QSV support
- For systems with multiple GPUs, you may need to specify which GPU to use
```
