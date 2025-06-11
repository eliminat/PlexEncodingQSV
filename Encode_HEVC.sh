#!/bin/bash

# Check if input file is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <input_video>"
    exit 1
fi

# Universal filename handling with protocol prefix and escaping
input_video="$1"
escaped_input="${input_video//:/\\:}"  # Escape colon characters
safe_input="file:$input_video"       # Add protocol prefix

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

# Cleanup function for early termination or script exit
cleanup() {
    echo "Trap triggered: cleaning up before exit"
    [ -f "$temp_output_file" ] && rm -f "$temp_output_file"
    flock -u 100 2>/dev/null
}
trap cleanup EXIT INT TERM

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

# Function to check subtitle codec
check_subtitle_codec() {
    local subtitle_info=$(ffprobe -v error -select_streams s -show_entries stream=codec_name,codec_tag_string -of csv=p=0 "$safe_input")
    if [[ $subtitle_info == *"tx3g"* || $subtitle_info == *"text"* || $subtitle_info == *"mov_text"* ]]; then
        log_message "Incompatible subtitle codec detected: $subtitle_info. Attempting conversion."
        return 1
    fi
    return 0
}

# Build filter complex for audio streams
filter_complex_str=""
map_audio_str=""
stream_count=0

process_audio_stream() {
    local idx="$1"
    filter_complex_str+="[0:a:$idx]"
    # High-quality resampling
    filter_complex_str+="aresample=resampler=soxr:precision=28:async=1000,"
    # Natural stereo downmix
    filter_complex_str+="pan=stereo|FL=0.5*FC+0.707*FL+0.5*BL+0.5*LFE|FR=0.5*FC+0.707*FR+0.5*BR+0.5*LFE,"
    # Gentle noise reduction
    filter_complex_str+="afftdn=nr=12:nf=-45:track_noise=1,"
    # EBU R128 normalization for wide dynamics
    filter_complex_str+="loudnorm=I=-23:LRA=20:TP=-1.5:linear=true:dual_mono=true,"
    # Smooth dynamic normalization
    # filter_complex_str+="dynaudnorm=g=125:p=0.9:m=100:s=2.0,"
    # Transparent limiting (no unsupported options)
    filter_complex_str+="alimiter=level=disabled:limit=-0.3dB:attack=25:release=200"
    filter_complex_str+="[a$stream_count];"
    map_audio_str+="-map [a$stream_count] "
    ((stream_count++))
}

# Detect audio streams by language preference
# Find all English audio stream indices using actual stream indexes
readarray -t eng_audio_idxs < <(
    ffprobe -v error -select_streams a \
    -show_entries stream=index:stream_tags=language \
    -of csv=p=0 "$input_video" | awk -F',' '$2=="eng"{print NR-1}'
)

# Find first Japanese audio stream index using actual stream index
jpn_audio_idx=$(
    ffprobe -v error -select_streams a \
    -show_entries stream=index:stream_tags=language \
    -of csv=p=0 "$input_video" | awk -F',' '$2=="jpn"{print NR-1; exit}'
)

# Process all English streams first
for idx in "${eng_audio_idxs[@]}"; do
    process_audio_stream "$idx"
done

# Process Japanese streams
for idx in "${jpn_audio_idxs[@]}"; do
    process_audio_stream "$idx"
done

# Process undefined language streams
for idx in "${und_audio_idxs[@]}"; do
    process_audio_stream "$idx"
done

# Fallback to default audio stream 0 if none found
if [ ${#eng_audio_idxs[@]} -eq 0 ] && [ -z "$jpn_audio_idx" ]; then
    log_message "No English/Japanese audio. Using default stream 0"
    process_audio_stream "0"
fi

# Remove trailing semicolon from filter_complex
filter_complex_str="${filter_complex_str%;}"

# Stream mapping configuration
map_opts="-map 0:v:0 $map_audio_str"

# Detect subtitle streams (English or undefined language)
subtitle_streams_found=false

# Check for English subtitles first
if ffprobe -v error -select_streams s -show_entries stream=index:stream_tags=language \
-of csv=p=0 "$safe_input" | grep -q ',eng'; then
    map_opts+=" -map 0:s:m:language:eng"
    log_message "English subtitles detected and will be mapped."
    subtitle_streams_found=true
fi

# If no English subtitles, check for undefined language subtitles
if [ "$subtitle_streams_found" = false ]; then
    if ffprobe -v error -select_streams s -show_entries stream=index:stream_tags=language \
    -of csv=p=0 "$safe_input" | grep -q ',und\|,$'; then
        map_opts+=" -map 0:s:m:language:und"
        log_message "Undefined language subtitles detected and will be mapped."
        subtitle_streams_found=true
    fi
fi

# If still no subtitles found, map all subtitle streams as fallback
if [ "$subtitle_streams_found" = false ]; then
    if ffprobe -v error -select_streams s -show_entries stream=index \
    -of csv=p=0 "$safe_input" | grep -q '^[0-9]'; then
        map_opts+=" -map 0:s"
        log_message "Subtitle streams detected (unknown language) and will be mapped."
    else
        log_message "No subtitle streams detected; skipping subtitle mapping."
    fi
fi


# Lock handling
exec 100>$LOCK_FILE || exit 1
lock_start_time=$(date +%s)

while true; do
    if flock -n 100; then
        log_message "Lock acquired. Starting encoding process for $safe_input"
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

# Video analysis
log_message "Starting video analysis for $safe_input"
if mediainfo --Inform="Video;%ScanType%" "$input_video" | grep -q "Interlaced"; then
    log_message "Interlaced content detected. Enabling advanced deinterlacing."
    deinterlace_filter="-vf deinterlace_qsv"
else
    log_message "Progressive content detected. Skipping deinterlacing."
fi

# Build FFmpeg command
ffmpeg_command="ffmpeg -thread_queue_size 1024 \
    -analyzeduration 300M -probesize 300M\
    -fflags +genpts \
    -hwaccel qsv -hwaccel_output_format qsv \
    -extra_hw_frames 88 -async_depth 16 \
    -i \"$safe_input\""

# Add deinterlacing filter if needed
if [ -n "$deinterlace_filter" ]; then
    ffmpeg_command+=" $deinterlace_filter"
fi

# HEVC QSV encoding parameters
ffmpeg_command+=" \
-c:v $encoder \
-global_quality:v $global_quality \
-preset veryslow \
-look_ahead_depth 99 \
-extbrc 1 \
-rdo 1 \
-adaptive_i 1 -adaptive_b 1 \
-b_strategy 1 -bf 7 \
-low_power 0 \
-profile:v main \
-mbbrc 1 -idr_interval 48 \
-g 180 -refs 6 \
$map_opts \
-map_chapters 0 -map_metadata 0 \
-movflags use_metadata_tags"

# Audio processing
if [ -n "$filter_complex_str" ]; then
    ffmpeg_command+=" -filter_complex \"$filter_complex_str\""
fi
ffmpeg_command+=" -c:a libopus -b:a 128k -vbr on -application audio"

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
log_message "Executing: $ffmpeg_command"
eval "$ffmpeg_command 2>&1 | tee -a \"$log_file\""

# Duration validation with protocol handling
input_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$safe_input")
escaped_output="file:${temp_output_file//:/\\:}"  # Protocol-safe temp file
output_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$temp_output_file")
duration_margin=5  # Allow 5-second difference for rounding

if (( $(echo "$output_duration < $input_duration - $duration_margin" | bc -l) )); then
    log_message "Encoding interrupted - output duration too short (Input: ${input_duration}s vs Output: ${output_duration}s)"
    rm "$temp_output_file"  # Use original filename for filesystem operations
    flock -u 100
    exit 1
fi

# Size comparison and replacement logic
input_size_mb=$(du -m "$input_video" | cut -f1)
output_size_mb=$(du -m "$temp_output_file" | cut -f1)
size_change_percent=$(echo "scale=2; (($input_size_mb - $output_size_mb) / $input_size_mb) * 100" | bc)
log_message "!!!!! Input size: ${input_size_mb}MB | Output size: ${output_size_mb}MB | Change: ${size_change_percent}% !!!!!"

if [ "$output_size_mb" -lt "$min_output_size_mb" ]; then
    log_message "Error: Output file too small (${output_size_mb}MB < ${min_output_size_mb}MB)"
    rm "$temp_output_file"
    flock -u 100
    exit 1
fi

# Final file handling
# Post-processing metadata correction
log_message "Adding track statistics tags"
original_extension="${input_video##*.}"
output_file="${input_video%.*}.mkv"

if (( $(echo "$size_change_percent > 0" | bc -l) )); then
    if [ "$original_extension" != "mkv" ]; then
        rm "$input_video"
        log_message "Removed original .${original_extension} file"
    fi
    mkvpropedit "$temp_output_file" --add-track-statistics-tags
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
