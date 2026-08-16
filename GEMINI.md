# GEMINI.md - PlexEncodingQSV (ffmpeg-encoding-scripting)

## Workspace Overview & Hardware Architecture
- **Purpose**: Unified Intel Arc A380 (DG2) Quick Sync Video (QSV) Encoding Pipeline for Plex Media Server & Archiving.
- **Hardware Targets**:
  - **Local Workstation**: Linux 7.0.9 CachyOS, AMD Ryzen 5 5500 CPU (lacks iGPU), Discrete Intel Arc A380 (Sparkle Elf 6GB, Resizable BAR, `i915` kernel driver).
  - **ArchServer2** (`eliminat@ArchServer2`): Primary storage & media server host.
- **Deployed Paths**: `/home/eliminat/scripts/Encode.sh` and `Encode_Dir.sh` locally and on `ArchServer2`.

## Key Scripts
- **[`Encode.sh`](file:///home/eliminat/Documents/antigravity/ffmpeg-encoding-scripting/Encode.sh)**: Core single-file video encoder supporting `--av1` (default `av1_qsv`), `--hevc` (`hevc_qsv`), `--copy-video` / `--copy-only`, and `--quality <ICQ>`.
- **[`Encode_Dir.sh`](file:///home/eliminat/Documents/antigravity/ffmpeg-encoding-scripting/Encode_Dir.sh)**: Recursive batch processor with path validation, extension filtering (`mkv,avi`), and SIGINT/SIGTERM traps.
- **[`Library_Scanner.sh`](file:///home/eliminat/Documents/antigravity/ffmpeg-encoding-scripting/Library_Scanner.sh)**: Library analysis sentinel for resolution tiering (4K, 2K, 1080p, 720p, SD), BPP low-quality safeguards (<0.02 threshold), and re-encode recommendation lists.

## Technical & Encoding Rules
1. **Concurrency Control**: Enforced single-concurrency via global flock descriptor at `/plexdb/plexlogs/plex_encoding.lock` (8-hour timeout, 5-minute polling).
2. **Arc A380 Quality Profile**:
   - Constant Quality: `global_quality=25` (auto-adjusts to 28 for 4K B&W).
   - Lookahead & Power: `-look_ahead_depth:v 80 -extbrc:v 1 -low_power:v 0`.
   - GOP & Tiling: Dynamic GOP (`FPS * 10`), adaptive tiling (`2x2` for 4K, `1x0` for 1080p, `0x0` for $\le$720p).
3. **Hardware Decode Whitelist**:
   - Hardware decoding (`-hwaccel qsv -hwaccel_output_format qsv`) is strictly limited to codecs supported by Arc DG2 (`h264`, `hevc`, `av1`, `vp9`, `vp8`, `mpeg2video`, `mjpeg`).
   - Software decode fallback triggered for H.264 High 10 / 10-bit (`yuv420p10le`) and unsupported codecs (`hwupload=extra_hw_frames=128,format=qsv`).
4. **Smart Audio & Subtitle Engine**:
   - Audio: `soxr` resampling (28-bit precision), `afftdn` (12dB noise reduction), `loudnorm` (EBU R128 -23 LUFS), `alimiter` (-0.3dBFS cap), Opus stereo downmix capped at 128k.
   - Priority: English (`eng`) $\to$ Japanese (`jpn`) $\to$ Undefined (`und`).
   - Subtitles: Preserves English subtitles, auto-transcoding MP4 `mov_text` to Matroska `srt`.
5. **FFmpeg 9.0 ("Lei") Compliance**:
   - Verified for standard oneVPL QSV syntax (`-init_hw_device qsv=hw -filter_hw_device hw`).
   - Software fallbacks accelerated by rewritten `libswscale` SIMD/Vulkan backend.
6. **Safety & Remote Operation Mandates**:
   - Always use `eliminat@ArchServer2` for SSH connections.
   - Script edits require `bash-validator` compliance and testing.
