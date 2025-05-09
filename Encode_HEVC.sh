#!/bin/bash

# Check if input file is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <input_video>"
    exit 1
fi

# Input file and default settings
input_video="$1"
video_name=$(basename "$input_video")
video_name_no_ext="${video_name%.*}"
encoder="hevc_qsv"
global_quality=25
min_output_size_mb=10
log_file="/plexdb/plexlogs/${video_name_no_ext}_${encoder}_${global_quality}_encode_log.txt"
temp_output_file="/plexdb/plexlogs/temp/${video_name_no_ext}_temp_${encoder}_${global_quality}.mkv"

# Define lock file and timeout
LOCK_FILE="/plexdb/plexlogs/plex_encoding.lock"
LOCK_TIMEOUT=$((8 * 3600))
LOCK_WAIT_INTERVAL=300

# Ensure directories exist
mkdir -p /plexdb/plexlogs
mkdir -p /plexdb/plexlogs/temp

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$log_file"
}

# Validate input file
if [ ! -f "$input_video" ]; then
    log_message "Error: Input file does not exist."
    exit 1
fi

# Subtitle check function
check_subtitle_codec() {
    local subtitle_info=$(ffprobe -v error -select_streams s -show_entries stream=codec_name,codec_tag_string -of csv=p=0 "$input_video")
    if [[ $subtitle_info == *"tx3g"* || $subtitle_info == *"text"* || $subtitle_info == *"mov_text"* ]]; then
        log_message "Incompatible subtitle codec detected: $subtitle_info. Attempting conversion."
        return 1
    fi
    return 0
}



# Find all English audio stream indices (type-specific)
readarray -t eng_audio_idxs < <(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language -of csv=p=0 "$input_video" | awk -F',' '$2=="eng"{print NR-1}')
# Find first Japanese audio stream index (type-specific)
jpn_audio_idx=$(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language -of csv=p=0 "$input_video" | awk -F',' '$2=="jpn"{print NR-1; exit}')
# Find all English subtitle stream indices (type-specific)
readarray -t eng_sub_idxs < <(ffprobe -v error -select_streams s -show_entries stream=index:stream_tags=language -of csv=p=0 "$input_video" | awk -F',' '$2=="eng"{print NR-1}')

# Build map options
map_opts="-map 0:v:0"
# Check if English audio streams array is empty
if [ ${#eng_audio_idxs[@]} -eq 0 ]; then
    # No English audio streams found, include primary audio stream
    map_opts+=" -map 0:a:0"
    log_message "No English audio streams found. Including primary audio stream (0:a:0)"
else
    # Add all detected English audio streams
    for idx in "${eng_audio_idxs[@]}"; do
        map_opts+=" -map 0:a:$idx"
    done
fi

[ -n "$jpn_audio_idx" ] && map_opts+=" -map 0:a:$jpn_audio_idx"
for idx in "${eng_sub_idxs[@]}"; do
    map_opts+=" -map 0:s:$idx"
done

# Lock handling
exec 100>$LOCK_FILE || exit 1
lock_start_time=$(date +%s)
while true; do
    if flock -n 100; then
        log_message "Lock acquired. Starting encoding process for $input_video"
        break
    fi
    current_time=$(date +%s)
    elapsed_time=$((current_time - lock_start_time))
    if [ $elapsed_time -ge $LOCK_TIMEOUT ]; then
        log_message "Failed to acquire lock after 8 hours. Exiting."
        exit 1
    fi
    log_message "Waiting for lock. Another encoding process is running. Will check again in 5 minutes."
    sleep $LOCK_WAIT_INTERVAL
done

# Start encoding process
log_message "Starting encoding process for $input_video"

# Deinterlace detection
if mediainfo --Inform="Video;%ScanType%" "$input_video" | grep -q "Interlaced"; then
    log_message "Interlaced content detected. Enabling advanced deinterlacing."
    deinterlace_filter="-vf deinterlace_qsv"
else
    log_message "Progressive content detected. Skipping deinterlacing."
fi

# Build FFmpeg command
ffmpeg_command="ffmpeg -thread_queue_size 1024 \
-analyzeduration 300000000 -probesize 300000000 \
-hwaccel qsv \
-hwaccel_output_format qsv \
-extra_hw_frames 88 \
-async_depth 16 \
-i \"file:$input_video\""

# Add deinterlacing filter if needed
if [ -n "$deinterlace_filter" ]; then
    ffmpeg_command+=" $deinterlace_filter"
fi

# HEVC QSV encoding parameters
ffmpeg_command+=" \
-c:v $encoder \
-global_quality $global_quality \
-preset veryslow \
-look_ahead_depth 99 \
-extbrc 1 \
-rdo 1 \
-adaptive_i 1 \
-adaptive_b 1 \
-b_strategy 1 \
-bf 7 \
-low_power 0 \
-profile:v main \
-mbbrc 1 \
-idr_interval 48 \
-g 180 -refs 6 \
-temporal_aq 1 -spatial_aq 1 \
$map_opts \
-map_chapters 0 -map_metadata 0 \
-movflags use_metadata_tags"

# Audio processing
ffmpeg_command+=" \
-filter:a 'aresample=async=1000,pan=stereo|FL=0.5*FC+0.707*FL+0.707*BL+0.5*LFE|FR=0.5*FC+0.707*FR+0.707*BR+0.5*LFE,afftdn=nr=20:nf=-50:track_noise=1,loudnorm=I=-16:LRA=11:TP=-2,volume=1.5' \
-c:a aac \
-b:a 256k \
-ac 2 \
-ar 48000"

# Subtitle handling
if ! check_subtitle_codec; then
    ffmpeg_command+=" -c:s srt"
    log_message "Converting subtitles to SRT format."
else
    ffmpeg_command+=" -c:s copy"
fi

# Output configuration
ffmpeg_command+=" \
-movflags +faststart \
-max_muxing_queue_size 4096 \
-err_detect aggressive \
-fps_mode cfr \
\"file:$temp_output_file\""

# Execute command
log_message "Encoding command: $ffmpeg_command"
log_message "Starting FFmpeg encoding process..."
eval "$ffmpeg_command 2>&1 | tee -a \"$log_file\""

# Handle encoding result
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_message "Encoding completed successfully."
else
    log_message "Error: Encoding failed."
    flock -u 100
    exit 1
fi


# New duration check added here
input_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_video")
output_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$temp_output_file")
duration_margin=5  # Allow 5-second difference for rounding

if (( $(echo "$output_duration < $input_duration - $duration_margin" | bc -l) )); then
    log_message "Encoding interrupted - output duration too short (Input: ${input_duration}s vs Output: ${output_duration}s)"
    rm "$temp_output_file"
    flock -u 100
    exit 1
fi

# Validate output file
if [ ! -f "$temp_output_file" ]; then
    log_message "Error: Temporary output file was not created."
    flock -u 100
    exit 1
fi

# File size comparison
input_size_mb=$(du -m "$input_video" | cut -f1)
output_size_mb=$(du -m "$temp_output_file" | cut -f1)
size_change_percent=$(echo "scale=2; (($input_size_mb - $output_size_mb) / $input_size_mb) * 100" | bc)
log_message "Input size: ${input_size_mb}MB | Output size: ${output_size_mb}MB | Change: ${size_change_percent}%"

# File replacement logic
if [ "$output_size_mb" -lt "$min_output_size_mb" ]; then
    log_message "Error: Output file too small (${output_size_mb}MB < ${min_output_size_mb}MB)"
    rm "$temp_output_file"
    flock -u 100
    exit 1
fi

if (( $(echo "$size_change_percent > 0" | bc -l) )); then
    original_extension="${input_video##*.}"
    output_file="${input_video%.*}.mkv"
    
    if [ "$original_extension" != "mkv" ]; then
        rm "$input_video"
        log_message "Removed original .${original_extension} file"
    fi
    
    mv "$temp_output_file" "$output_file"
    log_message "Replaced with encoded .mkv version"
else
    log_message "Encoded file not smaller - keeping original"
    rm "$temp_output_file"
fi

# Final cleanup
log_message "Encoding process completed for $input_video"
flock -u 100
exit 0
