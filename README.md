# PlexEncodingQSV: Universal Intel Arc A380 Encoding Pipeline

This repository contains a unified, high-performance encoding system designed specifically for **Intel Arc A380 (DG2)** discrete GPUs. It automates video transcoding for Plex Media Server using Intel Quick Sync Video (QSV), focusing on AV1/HEVC efficiency, HDR preservation, and professional-grade audio normalization.

## 🚀 Key Features of the Universal Pipeline

### 1. **Universal_Encode.sh** (The Swiss Army Knife)
A single, modular script that replaces the legacy `Encode.sh`, `Encode_HEVC.sh`, and `Audio_Only.sh`.

*   **Unified Codec Support:** Switch between AV1, HEVC, or Remux (Copy-Video) modes with simple flags.
*   **Intel Arc A380 (DG2) Tuning:**
    *   **Discrete GPU Mode:** Explicitly uses `-low_power 0` to engage the full performance of discrete card encoders.
    *   **AV1 Parallelization:** Uses `-tile_cols 2 -tile_rows 2` to maximize the A380's dual-encoder hardware.
    *   **Advanced Rate Control:** Optimized `look_ahead_depth` and `extbrc` for professional compression results.
*   **Smart Audio Engine:**
    *   **Prioritization:** Automatically maps languages in order: English (`eng`) > Japanese (`jpn`) > Undefined (`und`) > Any.
    *   **Metadata Preservation:** Correctly labels resulting Opus tracks with their source language tags.
    *   **Audio Pipeline:** High-quality SOXR resampling, FFT denoising, EBU R128 normalization (`-23 LUFS`), and peak limiting.
*   **HDR10 Preservation:** Active probing and mapping of Color Primaries, Transfer Characteristics, and Colorspace to ensure HDR flags are preserved for 4K content.
*   **Safety & Security:** Built using **Bash Arrays** and JSON parsing (`jq`). Immune to filename escaping issues (spaces, brackets, colons) and field-shifting bugs.

### 2. **Library_Scanner.sh** (The Intelligence Sentinel)
A high-performance library analyzer that replaces the legacy `ident_avc.sh` and `List-non1080p.sh`.

*   **HDD Optimized:** Uses parallel probing (`PARALLEL_JOBS`) to handle the latency of spinning disks.
*   **Resolution Tiering:** Categorizes files into **4K, 2K, 1080p, 720p, SD**, and **NON_STD** (incompatible extensions).
*   **Quality Protection:** Calculates Bitrate-per-Pixel (BPP). If a file is already below the `0.02` threshold, it is tagged as `LOW_QUALITY` to prevent generational loss during re-encoding.
*   **Granular Filtering:** Use `--only-res` to find specifically SD files, or only 4K files, etc.
*   **Extension Detection:** Identifies legacy formats (`.avi`, `.wmv`, `.mov`, `.flv`) and recommends re-encoding to modern `.mkv` containers.

### 3. **Encode_Dir.sh** (The Batch Wrapper)
A recursive batch processor that handles entire library structures.
*   **Dynamic Flags:** Pass any flag (like `--hevc` or `--copy-video`) directly through to the underlying encoder.
*   **Safe Traversal:** Uses `-print0` to safely handle complex filenames during directory scanning.

---

## 🛠 Usage

### **Scanning and Analysis**
Generate reports or recommendation lists for your library:

*   **Full Report:**
    `./Library_Scanner.sh /path/to/library --report`
*   **Filter by Resolution (e.g., find only SD files):**
    `./Library_Scanner.sh /path/to/library --report --only-res SD`
*   **Find Incompatible Formats (.avi, .wmv, etc.):**
    `./Library_Scanner.sh /path/to/library --report --only-res NON_STD`
*   **Generate Re-encode Hit-list:**
    `./Library_Scanner.sh /path/to/library --recommend --output tasks.txt`

### **Encoding**
Process single files or batches:

*   **Process Hit-list (Automated):**
    `./Library_Scanner.sh . --auto --input tasks.txt`
*   **Single File AV1 (Default):**
    `./Universal_Encode.sh /path/to/video.mkv`
*   **Batch HEVC Encode:**
    `./Encode_Dir.sh --hevc mkv`

---

## 📊 Technical Optimizations

### **Intel Arc A380 Specific Flags**
| Flag | Purpose |
| :--- | :--- |
| `-hwaccel qsv` | Hardware decoding via Intel Quick Sync. |
| `-extbrc 1` | Extended Bitrate Control for more consistent quality. |
| `-look_ahead 1` | Enables look-ahead rate control. |
| `-tile_cols 2` | Specifically for Arc AV1 encoders to use dual-tile hardware. |
| `-g (FPS*10)` | Dynamic GOP size for optimal seek performance. |

---

## 📝 Requirements
*   **Hardware:** Intel CPU/GPU with QSV support (Discrete Arc A-Series recommended).
*   **Software:** `ffmpeg` (with QSV), `jq`, `mediainfo`, `mkvpropedit`, `bc`.

---
**Note:** For technical details on the transition from the old multi-script system, see [encoding_migration_plan.md](./encoding_migration_plan.md).
