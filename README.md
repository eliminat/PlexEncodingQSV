# PlexEncodingQSV: FFmpeg Video Encoding Scripts for Plex Media Server

This repository contains a collection of Bash scripts designed to automate video transcoding for Plex media servers using Intel Quick Sync Video (QSV) hardware acceleration. These scripts optimize video files for streaming while preserving quality and reducing file sizes.

## Overview

The scripts provide automated video transcoding functionality using either AV1 or HEVC (H.265) codecs with Intel QSV hardware acceleration. They handle various aspects of the encoding process, including deinterlacing detection, high-quality audio normalization with Opus encoding, subtitle format conversion, and intelligent file replacement based on size comparison.

## Scripts Included

### 1. Encode.sh
This is the primary encoding script that processes individual video files using the AV1 codec via Intel QSV.

**Key Features:**
- Uses Intel QSV hardware acceleration with AV1 encoder (av1_qsv)
- Advanced AV1 encoding parameters: global quality 25, extended bitrate control, look-ahead depth 88, 7 B-frames with 180 GOP size
- Automatically detects and processes interlaced content with deinterlace_qsv filter
- High-quality audio processing with noise reduction, EBU R128 normalization, and transparent limiting
- Audio encoding using libopus codec with variable bitrate and dynamic bitrate allocation based on source (capped at 128kbps)
- Prioritizes English and Japanese audio streams with intelligent fallback handling
- Handles subtitle format conversion for compatibility (converts incompatible codecs to SRT)
- Implements file locking to prevent concurrent encoding jobs
- Only replaces original files if the new version is smaller and above 10MB threshold
- Generates detailed logs of the encoding process in `/plexdb/plexlogs/`
- Checks video duration to ensure complete encoding with 5-second tolerance margin
- Implements aggressive error detection and comprehensive cleanup on failure

### 2. Encode_HEVC.sh
Similar to Encode.sh but uses the HEVC (H.265) codec instead of AV1.

**Key Features:**
- Uses Intel QSV hardware acceleration with HEVC encoder (hevc_qsv)
- HEVC-optimized encoding parameters: look-ahead depth 99, main profile, mbbrc enabled, IDR interval 48
- Shares the same intelligent audio processing pipeline as Encode.sh with libopus encoding
- Same advanced audio filtering including SOXR resampling, stereo downmix for multi-channel audio, and EBU R128 normalization
- Suitable for devices with better HEVC compatibility than AV1
- Identical file handling, locking mechanism, and validation processes as Encode.sh

### 3. Audio_Only.sh
Creates audio-optimized copies of video files by copying the video stream unchanged while reprocessing audio streams with advanced filtering, normalization, and conversion to Opus codec.

**Key Features:**
- Copies video streams without re-encoding (maintains original quality and saves processing time)
- Processes audio streams with identical high-quality filtering pipeline as encoding scripts
- Uses libopus codec with dynamic bitrate allocation capped at 128kbps
- Applies same advanced audio processing: SOXR resampling, noise reduction, EBU R128 normalization, and transparent limiting
- Prioritizes English and Japanese audio streams with intelligent channel detection
- Maintains original video quality while optimizing audio for streaming
- Useful for improving audio quality without the time cost of video re-encoding

### 4. Encode_Dir.sh
A utility script that recursively processes all video files of a specified format in a directory tree.

**Key Features:**
- Finds all files with a specified extension (default: .mkv)
- Case-insensitive file matching for both extensions and filenames
- Recursively searches subdirectories using find command
- Passes each matching file to Encode.sh for AV1 processing
- Simple command-line interface accepting custom file extensions

### 5. ident_avc.sh
Identifies H.264/AVC encoded files and optionally processes them with AV1 or HEVC encoding.

**Key Features:**
- Scans video library using ffprobe to identify H.264/AVC encoded content
- Can automatically queue identified files for encoding with specified format (av1 or hevc)
- Handles large file lists efficiently using temporary files
- Supports both identification-only mode and automatic encoding mode
- Useful for systematic library upgrades from older H.264 codec
- Processes files safely with proper error handling for unreadable files

### 6. List-non1080p.sh
Scans video library and reports files that aren't 1080p resolution.

**Key Features:**
- Recursively examines video files (MKV, MP4, MOV, AVI) for resolution analysis
- Uses MediaInfo to extract accurate width and height information
- Defines "1080p-compatible" as width ≥1875 and height ≥695 to account for various aspect ratios
- Generates reports showing which files are below 1080p with exact resolutions
- Helps prioritize encoding efforts based on resolution requirements
- Essential for understanding library resolution distribution before batch processing

## Requirements

- Linux-based system with Bash shell
- Intel CPU with Quick Sync Video support (6th generation or newer recommended)
- FFmpeg compiled with Intel QSV support and libopus encoder
- MediaInfo for interlaced content detection and resolution analysis
- BC (basic calculator) for percentage calculations and duration validation
- MKVToolNix (mkvpropedit) for adding track statistics to output files
- At least 10MB of free space in the `/plexdb/plexlogs/temp` directory
- Sufficient storage space for temporary files during encoding

## Usage

### Processing a Single File

To encode a single video file using AV1:
```
./Encode.sh /path/to/your/video.mp4
```

To encode using HEVC instead:
```
./Encode_HEVC.sh /path/to/your/video.mp4
```

To process audio-only (video copied unchanged):
```
./Audio_Only.sh /path/to/your/video.mp4
```

### Processing Multiple Files

To encode all MKV files in the current directory and subdirectories:
```
./Encode_Dir.sh
```

To process files with a different extension (e.g., MP4):
```
./Encode_Dir.sh mp4
```

### Library Analysis and Identification

Identify H.264 files only (list mode):
```
./ident_avc.sh /path/to/library
```

Find H.264 files and encode to AV1:
```
./ident_avc.sh /path/to/library av1
```

Find H.264 files and encode to HEVC:
```
./ident_avc.sh /path/to/library hevc
```

List non-1080p files for resolution analysis:
```
./List-non1080p.sh /path/to/library
```

## How It Works

When you run an encoding script on a video file, it first acquires a lock file (`/plexdb/plexlogs/plex_encoding.lock`) to prevent multiple concurrent encoding processes that could overwhelm system resources. The script waits up to 8 hours to acquire the lock, checking every 5 minutes.

The script analyzes the video using MediaInfo to determine if it's interlaced, and applies Intel QSV deinterlacing filters if needed. Audio streams are intelligently processed with language priority (English first, then Japanese, then undefined languages) and advanced filtering including high-quality SOXR resampling, gentle noise reduction, EBU R128 normalization for consistent loudness, and transparent limiting.

FFmpeg is used with carefully optimized encoding parameters to transcode the video to either AV1 or HEVC format using Intel QSV hardware acceleration. Audio is processed through a sophisticated filter chain and encoded as Opus with variable bitrate and dynamic bitrate allocation based on source quality (capped at 128kbps). Incompatible subtitle formats are automatically converted to SRT for better compatibility.

After encoding, the script performs comprehensive validation including duration comparison (allowing 5-second tolerance for rounding) and size verification. If the encoded file is smaller than the original and above a minimum size threshold (10MB), it replaces the original file and adds track statistics metadata using mkvpropedit. Otherwise, it keeps the original and removes the encoded version. Detailed logs are generated throughout the process in the `/plexdb/plexlogs` directory with filenames including the encoder and quality settings.

## Encoding Parameters

Both scripts use carefully optimized encoding parameters for maximum quality and efficiency:

### AV1 Encoding (Encode.sh)
- Encoder: av1_qsv with Intel QSV hardware acceleration
- Global quality: 25 (balanced quality/size ratio)
- Preset: veryslow for maximum compression efficiency
- Extended bitrate control: enabled for consistent streaming performance
- Look-ahead depth: 88 frames for optimal compression decisions
- Adaptive I-frames and B-frames: enabled for dynamic optimization
- B-frames: 7 with GOP size 180 for efficient compression
- Tile encoding: 2x2 tiles for parallel processing
- Low power mode: disabled for maximum quality

### HEVC Encoding (Encode_HEVC.sh)
- Encoder: hevc_qsv with Intel QSV hardware acceleration
- Global quality: 25 (matching AV1 for consistent library standards)
- Preset: veryslow for maximum compression efficiency
- Profile: main for broad device compatibility
- Look-ahead depth: 99 frames (optimized for HEVC characteristics)
- Extended bitrate control and MBBRC: enabled
- IDR interval: 48 with GOP size 180
- B-frames: 7 with 6 reference frames

### Audio Processing (All Scripts)
- Codec: libopus with variable bitrate encoding
- Application: audio (optimized for general audio content)
- Resampling: SOXR with 28-bit precision and 1000ms async buffer
- Multi-channel downmix: Natural stereo downmix preserving center channel and LFE
- Noise reduction: Gentle FFT denoising (12dB NR, -45dB noise floor)
- Normalization: EBU R128 standard (-23 LUFS integrated, 20 LU range, -1.5 dBTP peak)
- Limiting: Transparent peak limiting at -0.3dB with 25ms attack, 200ms release
- Bitrate allocation: Dynamic based on source quality, capped at 128kbps

## Important Notes

The scripts implement sophisticated resource management with file locking to prevent system overload from concurrent encoding jobs. If an encoding job fails to acquire the lock after 8 hours of waiting, it automatically exits. Each script validates output duration matches input duration within a 5-second margin to ensure complete encoding.

Original files are only replaced if the encoded version is both smaller and above the minimum size threshold (10MB). The scripts automatically convert all output files to MKV container format for consistency and add track statistics metadata for better media player compatibility. Detailed logs are stored in `/plexdb/plexlogs` with filenames that include the original filename, encoder type, and quality settings.

Error detection is set to "aggressive" mode to catch potential encoding issues, and comprehensive cleanup functions ensure temporary files are properly removed even if the process is interrupted. The scripts handle various edge cases including files with special characters in names, multiple audio/subtitle streams, and different container formats.

## Customization

You may want to adjust the following parameters in the scripts for your specific needs:

**Quality Settings:**
- `global_quality`: Lower values (15-20) produce higher quality but larger files; higher values (30-35) create smaller files with reduced quality
- `min_output_size_mb`: Minimum acceptable size for encoded files (default: 10MB)

**Performance Settings:**
- `LOCK_TIMEOUT`: Maximum wait time for acquiring the encoding lock (default: 8 hours)
- `look_ahead_depth`: Higher values improve compression but increase encoding time
- Thread queue sizes and hardware acceleration parameters for specific hardware configurations

**Audio Settings:**
- Target bitrate caps in the `get_target_bitrate()` function (default: 128kbps maximum)
- EBU R128 normalization parameters (integrated loudness, loudness range, true peak)
- Noise reduction strength and limiting thresholds

**File Handling:**
- Supported video extensions in List-non1080p.sh
- Resolution thresholds for "1080p-compatible" content
- Log file retention and cleanup policies

## Using as a Plex Post-Processing Script

These scripts can be used as post-processing scripts in Plex DVR settings for automatic conversion of recorded content:

1. Set up Plex DVR to record your TV shows
2. In the DVR settings, locate the post-processing script option
3. Enter the full path to your chosen script:
   - For AV1: `/path/to/Encode.sh`
   - For HEVC: `/path/to/Encode_HEVC.sh`
   - For audio-only processing: `/path/to/Audio_Only.sh`
4. Plex will automatically pass recorded shows to the script for processing after recording completes

This enables automatic conversion of recorded content to save storage space while maintaining or improving quality through modern codec efficiency and advanced audio processing.

## Troubleshooting

**Encoding Failures:** Check the detailed log files in `/plexdb/plexlogs/` for specific error messages and FFmpeg output. Logs include the complete command line and all output for debugging.

**QSV Compatibility:** Ensure your Intel CPU supports QSV for the codec you're trying to use. AV1 requires 11th generation Intel CPUs or newer, while HEVC is supported on 6th generation and later.

**FFmpeg Configuration:** Verify that FFmpeg is compiled with proper Intel QSV support and libopus encoder. Test with: `ffmpeg -encoders | grep qsv` and `ffmpeg -encoders | grep opus`

**Performance Issues:** For systems with multiple GPUs, you may need to specify which GPU to use. Monitor system resources during encoding to ensure adequate cooling and power delivery.

**Lock File Issues:** If scripts consistently fail to acquire locks, check for stale lock files in `/plexdb/plexlogs/` and remove them manually if no encoding processes are actually running.

**Audio Processing Problems:** If audio processing fails, verify that the source files have valid audio streams and that the specified language tags are present in the metadata.
