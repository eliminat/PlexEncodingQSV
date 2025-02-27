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
encoder="av1_qsv"
global_quality=25
min_output_size_mb=10
log_file="/plexlogs/${video_name_no_ext}_${encoder}_${global_quality}_encode_log.txt"
temp_output_file="$(dirname "$input_video")/${video_name_no_ext}_temp_${encoder}_${global_quality}.mkv"

# Define lock file and timeout
LOCK_FILE="/var/tmp/plex_encoding.lock"
LOCK_TIMEOUT=$((8 * 3600))
LOCK_WAIT_INTERVAL=300

# Ensure /plexlogs directory exists
mkdir -p /plexlogs

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$log_file"
}

# Function to check subtitle codec
check_subtitle_codec() {
    local subtitle_info=$(ffprobe -v error -select_streams s -show_entries stream=codec_name,codec_tag_string -of csv=p=0 "$input_video")
    if [[ $subtitle_info == *"tx3g"* || $subtitle_info == *"text"* || $subtitle_info == *"mov_text"* ]]; then
        log_message "Incompatible subtitle codec detected: $subtitle_info. Attempting conversion."
        return 1
    fi
    return 0
}

# Check if the input file exists
if [ ! -f "$input_video" ]; then
    log_message "Error: Input file does not exist."
    exit 1
fi

# Attempt to acquire lock with timeout
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

# Start logging
log_message "Starting encoding process for $input_video"

# Check if video is interlaced using MediaInfo
if mediainfo --Inform="Video;%ScanType%" "$input_video" | grep -q "Interlaced"; then
    log_message "Interlaced content detected. Enabling advanced deinterlacing."
    deinterlace_filter="-vf hwdownload,format=nv12,yadif=1:parity=auto,hwupload=extra_hw_frames=40"
else
    log_message "Progressive content detected. Skipping deinterlacing."
    deinterlace_filter=""
fi

# Construct the ffmpeg command
ffmpeg_command="ffmpeg -thread_queue_size 512 \
       -hwaccel qsv \
       -hwaccel_output_format qsv \
       -extra_hw_frames 40 \
       -i \"$input_video\""

# Add deinterlacing if needed
if [ -n "$deinterlace_filter" ]; then
    ffmpeg_command+=" $deinterlace_filter"
fi

# Video encoding parameters (validated working)
ffmpeg_command+=" \
       -c:v $encoder \
       -global_quality $global_quality \
       -preset veryslow \
       -look_ahead_depth 40 \
       -extbrc 1 \
       -adaptive_i 1 \
       -adaptive_b 1 \
       -b_strategy 1 \
       -low_power 0"

# Audio processing
ffmpeg_command+=" \
       -filter:a 'aresample=async=1000,pan=stereo|FL=0.5*FC+0.707*FL+0.707*BL+0.5*LFE|FR=0.5*FC+0.707*FR+0.707*BR+0.5*LFE,volume=1.50' \
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

# Output options
ffmpeg_command+=" \
       -movflags +faststart \
       -max_muxing_queue_size 1024 \
       -err_detect aggressive \
       -fps_mode cfr \
       \"$temp_output_file\""

# Log and execute
log_message "Encoding command: $ffmpeg_command"
log_message "Starting FFmpeg encoding process..."
eval "$ffmpeg_command 2>&1 | tee -a \"$log_file\""
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_message "Encoding completed successfully."
else
    log_message "Error: Encoding failed."
    flock -u 100
    exit 1
fi

# Check if temporary file was created
if [ ! -f "$temp_output_file" ]; then
    log_message "Error: Temporary output file was not created."
    flock -u 100
    exit 1
fi

# Size comparison and replacement logic
input_size_mb=$(du -m "$input_video" | cut -f1)
output_size_mb=$(du -m "$temp_output_file" | cut -f1)
size_change_percent=$(echo "scale=2; (($input_size_mb - $output_size_mb) / $input_size_mb) * 100" | bc)

log_message "Input size: ${input_size_mb}MB | Output size: ${output_size_mb}MB | Change: ${size_change_percent}%"

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
