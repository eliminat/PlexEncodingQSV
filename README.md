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

### 2. **Encode_Dir.sh** (The Batch Wrapper)
A recursive batch processor that handles entire library structures.
*   **Dynamic Flags:** Pass any flag (like `--hevc` or `--copy-video`) directly through to the underlying encoder.
*   **Safe Traversal:** Uses `-print0` to safely handle complex filenames during directory scanning.

---

## 🛠 Usage

### **Universal_Encode.sh**
Process a single file with specific requirements:

*   **Default (AV1 Encoding):**
    `./Universal_Encode.sh /path/to/video.mkv`
*   **HEVC Encoding:**
    `./Universal_Encode.sh --hevc /path/to/video.mkv`
*   **Remux & Process Audio Only:**
    `./Universal_Encode.sh --copy-video /path/to/video.mkv`
*   **Custom Quality (CRF/Global Quality):**
    `./Universal_Encode.sh --quality 28 /path/to/video.mkv`

### **Encode_Dir.sh**
Process a whole directory tree:

*   **Batch AV1 (Default):**
    `./Encode_Dir.sh mkv`
*   **Batch HEVC:**
    `./Encode_Dir.sh --hevc mkv`
*   **Batch Remux (Video Copy):**
    `./Encode_Dir.sh --copy-video mp4`

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

### **Audio Pipeline (Opus)**
*   **Target:** Transparent 128kbps stereo Opus.
*   **Downmix:** Natural stereo downmix preserving LFE and Center channel balance.
*   **Normalization:** EBU R128 standard (-23 Integrated, -1.5 True Peak).

---

## 📂 Repository Structure
*   `Universal_Encode.sh`: The core unified encoding script.
*   `Encode_Dir.sh`: The recursive batch wrapper.
*   `encoding_migration_plan.md`: Technical documentation of the transition from legacy scripts.
*   `ident_avc.sh`: Utility to find H.264 files needing upgrade.
*   `List-non1080p.sh`: Utility to find sub-1080p content.

## 📝 Requirements
*   **Hardware:** Intel CPU/GPU with QSV support (Discrete Arc A-Series recommended).
*   **Software:** `ffmpeg` (with QSV), `jq`, `mediainfo`, `mkvpropedit`, `bc`.

---
**Note:** For technical details on the transition from the old multi-script system, see [encoding_migration_plan.md](./encoding_migration_plan.md).
