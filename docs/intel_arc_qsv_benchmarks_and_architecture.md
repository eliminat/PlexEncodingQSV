# Intel Arc A380 Quick Sync Video (QSV) Hardware Architecture & Empirical Benchmarks

## 1. Executive Summary & Hardware Context
This document records the empirical benchmarking, memory architecture, and driver queueing behavior of the **Intel Arc A380 (DG2 / Alchemist 6GB GDDR6)** Quick Sync Video (QSV) encoding pipeline in `Encode.sh`.

### Target Systems
* **Local Workstation**: AMD Ryzen 5 5500 CPU, Sparkle Elf Intel Arc A380 6GB (Resizable BAR enabled, `i915` kernel driver), 64GB DDR4 RAM, Linux 7.0.9 CachyOS, FFmpeg 9.0.1.
* **ArchServer2** (`eliminat@ArchServer2`): AMD Ryzen CPU, Intel Arc A380 6GB (Resizable BAR enabled, `i915` kernel driver), 32GB DDR4 RAM, Linux ArchServer, FFmpeg 8.1.2 / 9.0.1.

---

## 2. Empirical Benchmarking Methodology

### Scientific Controls
To eliminate test contamination, all benchmarks were executed under the following strict conditions:
1. **Dedicated Hardware Gate**: Verified 0 active background FFmpeg/transcoding processes (`pgrep ffmpeg == 0`) and released concurrency flock (`/plexdb/plexlogs/plex_encoding.lock` 100% free).
2. **Real-World Media Payloads**:
   * **1080p SDR Payload**: `Parks and Recreation S01E01` (1080p Blu-ray REMUX, H.264 High @ 25.1 Mbps, DTS-HD MA 5.1).
   * **4K HDR Payload**: `Star Trek: Strange New Worlds S04E04` (2160p Main 10 HDR HEVC @ 25.2 Mbps, BT.2020/PQ, E-AC3 5.1).
3. **Steady-State Duration**: 60.0 Seconds (1,439–1,440 frames @ 23.976 fps). Over 95% of total test duration was spent in steady-state encoding after the 80-frame lookahead queue reached initial equilibrium.
4. **Native Hardware Pipeline**: `-init_hw_device qsv=hw -filter_hw_device hw -hwaccel qsv -hwaccel_output_format qsv`.

---

## 3. Benchmark Data & Empirical Findings

### A. 1080p SDR Blu-ray REMUX (1,440 Frames)
* **Encoding Profile**: `av1_qsv`, `global_quality=25`, `veryslow`, `-look_ahead_depth:v 80 -extbrc:v 1 -g:v 240 -bf:v 7 -refs:v 5 -tile_cols:v 1 -tile_rows:v 0 -adaptive_i:v 1 -adaptive_b:v 1`.

| Test Matrix | Parameter Tested | Encoding Speed | Steady-State FPS | Total Runtime | Bitstream Output |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **Matrix A (`async_depth`)** | `async_depth = 4` *(Default)* | **12.1x** | **291 fps** | 5.016s | 19,833 KiB |
| | `async_depth = 8` | **12.1x** | **291 fps** | 5.017s | 19,833 KiB |
| | `async_depth = 16` | **12.1x** | **291 fps** | 5.018s | 19,833 KiB |
| **Matrix B (`extra_hw_frames`)**| `extra_hw_frames = 64` | **12.2x** | **292 fps** | 5.012s | 19,833 KiB |
| | `extra_hw_frames = 128` *(Standard)* | **12.1x** | **291 fps** | 5.018s | 19,833 KiB |
| | `extra_hw_frames = 256` | **12.1x** | **291 fps** | 5.022s | 19,833 KiB |
| **Matrix C (Combination Max)** | `extra_hw_frames = 256` + `async_depth = 16` | **12.1x** | **291 fps** | **5.024s** | 19,833 KiB |
| | Baseline (`128 frames` + `async 4`) | **12.1x** | **291 fps** | **5.024s** | 19,833 KiB |

---

### B. 4K 10-Bit HDR HEVC (1,440 Frames)
* **Encoding Profile**: `av1_qsv`, `global_quality=25`, `veryslow`, `-look_ahead_depth:v 80 -extbrc:v 1 -g:v 240 -bf:v 7 -refs:v 5 -tile_cols:v 2 -tile_rows:v 2 -adaptive_i:v 1 -adaptive_b:v 1 -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc`.

| Test Matrix | Parameter Tested | Encoding Speed | Steady-State FPS | Total Runtime | Bitstream Output |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **Matrix A (`async_depth`)** | `async_depth = 4` *(Default)* | **4.32x** | **104 fps** | 13.958s | 19,317 KiB |
| | `async_depth = 8` | **4.32x** | **104 fps** | 13.954s | 19,317 KiB |
| | `async_depth = 16` | **4.32x** | **104 fps** | 13.953s | 19,317 KiB |
| **Matrix B (`extra_hw_frames`)**| `extra_hw_frames = 64` | **4.32x** | **104 fps** | 13.962s | 19,317 KiB |
| | `extra_hw_frames = 128` *(Standard)* | **4.32x** | **104 fps** | 13.960s | 19,317 KiB |
| | `extra_hw_frames = 256` | **4.32x** | **104 fps** | 13.959s | 19,317 KiB |
| **Matrix C (Combination Max)** | `extra_hw_frames = 256` + `async_depth = 16` | **4.32x** | **104 fps** | **13.955s** | 19,317 KiB |
| | Baseline (`128 frames` + `async 4`) | **4.32x** | **104 fps** | **13.959s** | 19,317 KiB |

---

## 4. Visual Quality & Bitstream Determinism Verification

### Bit-for-Bit Cryptographic Hash Proof
To verify whether plumbing parameters (`async_depth`, `extra_hw_frames`) alter macroblock compression, motion estimation, or quantization, elementary video bitstreams were hashed using cryptographic MD5:

```text
Config A (extra_hw_frames=128, async_depth=4):   MD5=e047598db6d87f330508d62a1b4aa142
Config B (extra_hw_frames=256, async_depth=16):  MD5=e047598db6d87f330508d62a1b4aa142
```

**Result**: 100.000% Bitstream Identity. Plumbing parameters alter only task handles and VRAM buffer descriptor counts; they do not alter pixel transformations or rate-control decisions.

### Parameter Taxonomy
* **Plumbing (0% Quality Impact, Memory/Queue Sizing)**: `-extra_hw_frames`, `-async_depth`, `-thread_queue_size`.
* **Rate-Control (Direct Quality & Bitrate Control)**: `-global_quality`, `-look_ahead_depth`, `-extbrc`, `-preset`, `-bf`, `-refs`, `-adaptive_i`, `-adaptive_b`.

---

## 5. Memory Architecture & 4K VRAM Safety Boundaries

### Surface Math on Intel Arc DG2 (4:2:0 Subsampling)
* **1080p 8-bit (`nv12`)**: $1920 \times 1080 \times 1.5\text{ Bytes} \approx 3.11\text{ MB}$ per surface.
  * 128 surfaces pool: $\approx 398\text{ MB}$ VRAM.
  * 256 surfaces pool: $\approx 796\text{ MB}$ VRAM.
* **4K 10-bit (`p010le` stored in 16-bit container)**: $3840 \times 2160 \times 3.0\text{ Bytes} \approx 24.88\text{ MB}$ per surface.
  * **128 surfaces pool**: $\mathbf{\approx 3.18\text{ GB}}$ VRAM.
  * **256 surfaces pool**: $\mathbf{\approx 6.37\text{ GB}}$ VRAM.

### The 4K VRAM Safety Ceiling
The Intel Arc A380 has **6.0 GB (6,144 MB) of physical GDDR6 VRAM**.
1. Setting `-extra_hw_frames 256` on uncropped 4K 10-bit media allocates **6.37 GB**, exceeding the physical VRAM limit.
2. When VRAM is exceeded, the Intel driver will either:
   * Fail with `MFX_ERR_MEMORY_ALLOC` (crashing the encode).
   * Spill surfaces into system RAM over the PCIe bus via GTT paging, bottlenecking decode throughput.
3. Setting `-extra_hw_frames 128` allocates **3.18 GB**, providing an ample safety margin for an 80-frame lookahead while leaving **~2.8 GB headroom** for Plex Media Server, desktop compositors, and OS buffers.

---

## 6. Pipeline Design Standards

1. **VRAM Surface Pool**: Maintain `-extra_hw_frames 128` globally across 1080p and 4K profiles.
2. **Driver Queue Depth**: Maintain oneVPL default (`-async_depth 4`).
3. **RAM Optimization**: Direct temporary files and intermediate multiplexing to RAM-disk staging (`/dev/shm`) to eliminate storage I/O latency and flash wear.
