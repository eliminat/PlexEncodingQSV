# Intel Arc A380 Universal Encoding Migration Plan

## 1. System Analysis & Objectives
*   **Hardware:** Intel Arc A380 (Discrete DG2 GPU).
*   **Primary Goal:** Consolidate `Encode.sh`, `Encode_HEVC.sh`, and `Audio_Only.sh` into a single `Universal_Encode.sh`.
*   **Key Improvements:**
    *   Fix audio language selection logic (handle English, Japanese, and Undefined properly).
    *   Implement `--copy-video` mode (replaces Audio_Only.sh).
    *   Transition from `eval` to **Bash Arrays** for absolute filename safety.
    *   Preserve HDR10 metadata for 4K content.

## 2. Identified Bugs & Solutions
### A. The "Singular Variable" Audio Bug
*   **Issue:** Legacy scripts use `jpn_audio_idx` (singular) but fill `jpn_audio_idxs` (array). Mismatched logic causes Japanese/Undefined tracks to be missed.
*   **Solution:** Use `ffprobe` to build a priority-ordered list of ALL audio streams.
    *   Priority: `eng` -> `jpn` -> `und` -> `any remaining`.

### B. Filename Safety
*   **Issue:** `eval` with `printf %q` is brittle and prone to failure with complex brackets/quotes.
*   **Solution:** Construct the command as an array: `ffmpeg_cmd=("ffmpeg" "-i" "file:$input" ... )`. Execute as `"${ffmpeg_cmd[@]}"`.

### C. HDR Metadata Passthrough
*   **Issue:** Side-data (Mastering Display) is often lost during hardware transcodes.
*   **Solution:** Explicitly probe and map `-color_primaries`, `-color_trc`, and `-colorspace`. Ensure `-pix_fmt p010le` is used for 10-bit sources.

## 3. The "Universal" Architecture
The new script will support:
*   `--av1`: Sets `av1_qsv` (Default).
*   `--hevc`: Sets `hevc_qsv`.
*   `--copy-video`: Sets `-c:v copy` and skips video filters/accel.
*   `--quality X`: Allows overriding the default `global_quality` of 25.

## 4. Intel Arc A380 Specific Optimizations
*   **GOP Management:** Set `-g` based on detected frame rate (FPS * 10).
*   **Look-Ahead:** Utilize `-look_ahead 1` and `-look_ahead_depth 60-80` for better rate control on A380.
*   **Low Power:** Explicitly set `-low_power 0` to use the full power of the discrete card.

## 5. Compatibility & Challenges
*   **PGS Subtitles:** Increase `-max_muxing_queue_size` to 8192 for 4K PGS bursts.
*   **H.264 High 10:** Maintain the software-decode fallback for High 10 content which QSV hardware does not support.
*   **Opus/MKV:** Ensure all Opus streams are correctly tagged with language metadata.

## 6. Implementation Roadmap
1.  **Backup:** (Completed) Existing scripts moved to timestamped backup.
2.  **Core Script:** Build `Universal_Encode.sh` with array-based command construction.
3.  **Stream Intelligence:** Implement the new `ffprobe` metadata collector.
4.  **Wrapper Update:** Modify `Encode_Dir.sh` to pass flags to the new script.
5.  **Validation:** Test with 4K HDR source and file with spaces/brackets.
