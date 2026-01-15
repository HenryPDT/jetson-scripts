#!/bin/bash
#
# Description:
#   Accurately and efficiently splits a video file into fixed-duration segments
#   without re-encoding (lossless). It generates timestamped filenames based
#   on metadata parsed from the input filename.
#
#   Output is saved to a directory structure:
#   ./segmented/<SiteName>/unprocessed/
#   ./segmented/<SiteName>/processed/
#
# Usage:
#   ./split_video.sh <input_video_file>
#

# --- Script Configuration ---
# Stop script on any command failure
set -e
# Ensure that a pipeline command is treated as failed if any of its components fail
set -o pipefail

# --- Main Logic ---

main() {
    # --- User-configurable Settings ---
    local segment_duration=300  # Duration of each segment in seconds (e.g., 300 for 5 minutes)
    local seek_buffer=30        # Pre-seek buffer for the hybrid method. 30s is a safe default.

    # --- Input Validation ---
    local input_file="$1"
    if [[ ! -f "$input_file" ]]; then
        echo "Error: Input file not found at '$input_file'" >&2
        return 1
    fi

    # 1. Extract metadata from the filename. This is needed for the directory and file names.
    local base_filename
    base_filename=$(basename -- "$input_file")
    if [[ "$base_filename" =~ ^(.+)_([0-9]{4}_[0-9]{2}_[0-9]{2})_([0-9]+)(AM|PM)_([0-9]{2})_([0-9]{2})\..+$ ]]; then
        local site_name=${BASH_REMATCH[1]}
        local date_raw=${BASH_REMATCH[2]}
        local hour_12=${BASH_REMATCH[3]}
        local period=${BASH_REMATCH[4]}
        local minute=${BASH_REMATCH[5]}
        local second=${BASH_REMATCH[6]}
        local extension="${base_filename##*.}"
    else
        echo "Error: Could not parse filename: '$base_filename'" >&2
        echo "Expected format: SiteName_YYYY_MM_DD_H(H)AM/PM_MM_SS.ext" >&2
        return 1
    fi

    # 2. Prepare output directories using the parsed site_name
    local output_directory="./segmented/${site_name}/unprocessed"
    local processed_directory="./segmented/${site_name}/processed"
    mkdir -p "$output_directory" "$processed_directory"
    echo "Input file: $input_file"
    echo "Output will be saved to: $output_directory"

    # 3. Prepare timestamps and calculate number of segments
    local date_formatted=${date_raw//_/-}
    local start_datetime_str="$date_formatted $hour_12:$minute:$second $period"

    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_file")
    if [[ -z "$duration" ]]; then
        echo "Error: Could not determine video duration. Is ffprobe working?" >&2
        return 1
    fi
    local duration_int=${duration%.*}
    local num_segments=$((duration_int / segment_duration))

    echo "Video duration: ${duration_int}s. Creating $num_segments segments of ${segment_duration}s each."

    # 4. Loop through and create each segment
    for ((i=0; i<num_segments; i++)); do
        local start_time=$((i * segment_duration))

        # --- Portability Fix for `date` command (macOS vs. Linux) ---
        local output_timestamp
        if [[ "$(uname)" == "Darwin" ]]; then # macOS
            output_timestamp=$(date -v+"${start_time}"S -jf "%Y-%m-%d %I:%M:%S %p" "$start_datetime_str" +"%Y-%m-%dT%H-%M-%S")
        else # GNU/Linux
            output_timestamp=$(date -d "$start_datetime_str + $start_time seconds" +"%Y-%m-%dT%H-%M-%S")
        fi
        
        local output_file="${output_directory}/${site_name}_${output_timestamp}.${extension}"
        
        echo "Processing segment $((i + 1))/$num_segments -> $(basename -- "$output_file")"

        # --- Hybrid Seek Logic ---
        local coarse_seek_time=0
        local fine_seek_offset=$start_time
        if (( start_time > seek_buffer )); then
            coarse_seek_time=$((start_time - seek_buffer))
            fine_seek_offset=$seek_buffer
        fi

        # --- The Optimized & Accurate FFmpeg Command ---
        ffmpeg -ss "$coarse_seek_time" \
               -i "$input_file" \
               -ss "$fine_seek_offset" \
               -t "$segment_duration" \
               -c copy \
               -loglevel error \
               -y \
               "$output_file"
    done

    echo "✅ All segments created successfully."
}


# --- Script Entrypoint ---

usage() {
    echo "Usage: $0 <input_video_file>"
    echo "Splits a video into accurate, lossless segments with timestamped filenames."
}

# Check for required commands
for cmd in ffmpeg ffprobe; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' is not installed or not in your PATH." >&2
        exit 1
    fi
done

# Check for input file argument
if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

# Run the main function with all provided arguments
main "$@"
