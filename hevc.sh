#!/bin/bash
set -o pipefail


# Bash script to convert videos to HEVC format using FFmpeg and FFprobe.
# The script recursively searches for videos and deletes the original
# video only when the converted output is smaller and passes
# validation.
# Usage: ./hevc.sh <directory_list_file> <skip_list_file>

# Function to format a file size in bytes as human readable string
# Arguments:
#	$1 - File size in bytes
#	$2 - Name of variable to receive formatted string
format_size() {
	local size="$1"
	local -n size_fmt_ref="$2"

	if [ "${size:-0}" -ge 1073741824 ]; then
		size_fmt_ref=$(awk -v s="$size" 'BEGIN { printf "%.2f GB", s / 1073741824 }')
	elif [ "${size:-0}" -ge 1048576 ]; then
		size_fmt_ref=$(awk -v s="$size" 'BEGIN { printf "%.2f MB", s / 1048576 }')
	elif [ "${size:-0}" -ge 1024 ]; then
		size_fmt_ref=$(awk -v s="$size" 'BEGIN { printf "%.2f KB", s / 1024 }')
	else
		size_fmt_ref="${size:-0} B"
	fi
}

# Function to display progress of FFmpeg operations
# Arguments:
#   $1 - Operation name (e.g., "Converting", "Verifying")
#   $2 - Total duration of the video in seconds
#	$3 - Original file size in bytes (optional)
show_progress() {
	local operation="$1"
	local duration="$2"
	local original_file_size="$3"

	local progress="0.00" curr_time=0 curr_h=0 curr_m=0 curr_s=0
	local dur_int=0 dur_h=0 dur_m=0 dur_s=0
	local fps="-" speed="-" size=0 size_fmt="0 B" original_size_fmt="0 B"
	local key value

	format_size "$original_file_size" original_size_fmt

	dur_int=${duration%.*}
	dur_h=$((dur_int / 3600))
	dur_m=$(((dur_int % 3600) / 60))
	dur_s=$((dur_int % 60))

	while IFS='=' read -r key value; do
			# Process the progress information from ffmpeg
			case "$key" in
				out_time_us)
					[[ "$value" =~ ^[0-9]+$ ]] || continue
					curr_time=$((value / 1000000))
				
					progress=$(awk -v curr="$curr_time" \
								-v dur="$duration" \
								'BEGIN {
									if (dur > 0) {
										printf "%.2f", (curr / dur) * 100
									} else {
										printf "0.00"
									}
								}')

					curr_h=$((curr_time / 3600))
					curr_m=$(((curr_time % 3600) / 60))
					curr_s=$((curr_time % 60))
					;;
				fps)
					fps="$value"
					;;
				speed)
					speed="$value"
					;;
				total_size)
					[[ "$value" =~ ^[0-9]+$ ]] && size="$value"
					;;
				progress)
					format_size "$size" size_fmt

					# When ffmpeg reports progress, print the current status
					printf "\r\033[K%s: %s%% | Time: %02d:%02d:%02d / %02d:%02d:%02d | FPS: %s | Speed: %s" \
					"$operation" \
					"$progress" \
					"$curr_h" "$curr_m" "$curr_s" \
					"$dur_h" "$dur_m" "$dur_s" \
					"$fps" \
					"$speed"
					if [[ "$operation" != "Verifying" ]]; then
						printf " | Size: %s / %s" "$size_fmt" "$original_size_fmt"
					fi
			esac
			
		done;
}

# Wrapper for safe file deletion
# Arguments:
# 	$1 - File to be deleted
# Returns:
#	Exits script if deletion fails
delete_file() {
	local error

	if error=$(rm -f -- "$1" 2>&1); then
		echo "Deleted file: $1"
		echo
	else
		echo "Failed to delete file: $1" >&2
		echo "Reason: $error" >&2
		echo "Script will now terminate." >&2
		exit 1
	fi

}

# Function to build a list of convertible video streams
# and determine if a video should be converted to HEVC
# Arguments:
#	$1 - Video file
#	$2 - Reference to ffmpeg_args
#	$3 - Reference to needs_conversion
# Returns:
#	0 - Success
#	1 - Failure
build_ffmpeg_args() {
	local file="$1"
	local -n ffmpeg_args_ref="$2"
	local -n needs_conversion_ref="$3"

	local stream_data
	local stream_lines
	local stream_index codec name attached_pic

	ffmpeg_args_ref=(-map 0 -c copy)
	needs_conversion_ref=0

	# Retrieve information about every stream in one FFprobe call
	if ! stream_data=$(ffprobe -v error \
		-show_entries stream=index,codec_type,codec_name:stream_disposition=attached_pic \
		-of json "$file"); then
		echo "Failed to inspect streams: $file"
		return 1
	fi

	# Keep only video streams, recording their index, codec, and
	# whether they are attached pictures
	if ! stream_lines=$(jq -r '
		.streams[]
		| select(.codec_type == "video")
		| [
			.index,
			.codec_name,
			(.disposition.attached_pic // 0)
			]
		| @tsv
	' <<< "$stream_data"); then
		echo "Failed to parse stream information: $file"
		return 1
	fi

	# Add eligible video streams to list of FFmpeg args 
	while IFS=$'\t' read -r stream_index codec_name attached_pic; do
		[[ -n "$stream_index" ]] || continue

		# Only encode ordinary video streams using codecs targeted
		if [[ "$attached_pic" != "1" ]]; then
			case "$codec_name" in
				h264|mpeg4|mpeg2video|vc1|vp8|theora)
					ffmpeg_args_ref+=(
						-c:"$stream_index" libx265
					)
					needs_conversion_ref=1
					;;
			esac
		fi
	done <<< "$stream_lines"

	return 0
}

# Function to convert a video to HEVC format
# Arguments:
#   $1 - Input video file path
#   $2 - Output video file path
#   $3 - Skip list file path
# Side Effects:
#	- Creates a .log file for FFmpeg error message handling
# Returns:
#   0 - Success
#   1 - Failure
conv_to_hevc() {
	local source="$1"
	local output="$2"
	local skip_list="$3"
	shift 3

	local -a ffmpeg_args=( "$@" )

	echo
	echo "Converting: $source"
	echo "        To: $output"
	
	# Create a temporary output file name
	# with a .part extension to avoid overwriting the original file in case of failure
	local temp="${output%.*}.part.${output##*.}"
	local error_log="${temp}.log"

	[[ -e "$temp" ]] && delete_file "$temp"
	[[ -e "$error_log" ]] && delete_file "$error_log"

	local max_size
	if ! max_size=$(stat -c%s -- "$source") || [[ ! "$max_size" =~ ^[0-9]+$ ]]; then
		echo "Failed to get source file size: $source"
		return 1
	fi
	
	local duration
	duration=$(ffprobe -v error \
		-show_entries format=duration \
		-of csv=p=0 "$source")

	if [[ -z "$duration" || ! "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		echo "Invalid video duration: $duration"
		return 1
	fi

	if ! ffmpeg -nostdin -n -i "$source" \
	    "${ffmpeg_args[@]}" \
	    -crf 20 \
	    -preset medium \
	    -fs "$max_size" \
		-progress pipe:1 \
		-nostats \
	    "$temp" 2>"$error_log" |
		show_progress "Converting" "$duration" "$max_size"; then

			echo
			echo "Conversion failed: $source"
			echo "FFmpeg error output:"
			cat -- "$error_log"

			delete_file "$temp"
			return 1
	fi
	
		local output_size
		if ! output_size=$(stat -c%s -- "$temp") || (( output_size >= max_size )); then
			echo
			echo "Converted file exceeded the size of the original and will be deleted."
			delete_file "$temp"
			delete_file "$error_log"
			# Add the original file to the skip list to avoid future conversions
			echo "$source" >> "$skip_list"
			return 1
		fi

	echo
	echo "HEVC created."
	
	if ! mv "$temp" "$output"; then
		echo "Failed to rename temporary file to final output: $temp -> $output"
		delete_file "$temp"
		delete_file "$error_log"
		return 1
	fi

	delete_file "$error_log"
	return 0
		
}

# Function to verify that a video's video audio and
# subtitle streams can be decoded by FFmpeg without error
# Arguments:
#   $1 - Video file path
# Returns:
#   0 - Valid
#   1 - Invalid
video_validate() {
	local duration
	duration=$(ffprobe -v error \
		-select_streams v:0 \
		-show_entries format=duration \
		-of csv=p=0 "$1")

	if [[ -z "$duration" || ! "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		echo "Invalid video duration: $duration"
		return 1
	fi

	if ! ffmpeg -nostdin -v error -xerror \
		-i "$1" \
		-map 0:v -map 0:a? -map 0:s? \
		-progress pipe:1 \
		-nostats \
		-f null - 2>/dev/null |
		show_progress "Verifying" "$duration"; then
		echo
		echo "Video failed validation: $1"
		return 1
	fi
	
	echo
	echo "Video passed validation: $1"
	return 0
}

# Function to compare the sizes of the original and converted files,
# deleting the converted file if it is not smaller or fails validation;
# otherwise deleting the original.
# Arguments:
#   $1 - Original video file path
#   $2 - HEVC converted video file path
#   $3 - Skip list file path
# Side Effects:
#	- May delete either input file
#	- May append the original video file path to the skip list
# Returns:
#   0 - Success
#   1 - Failure
size_comp() {
	local source="$1"
	local output="$2"
	local skip_list="$3"
	shift 3

	local h264size hevcsize

	if ! h264size=$(stat -c%s "$source") ||
	   ! hevcsize=$(stat -c%s "$output"); then
		echo "Error: Failed to get file sizes for comparison. Default to keeping original."
		delete_file "$output"
		return 1
	fi

	if [ "$h264size" -gt "$hevcsize" ]; then
		# Verify that the HEVC file is valid before deleting the original
		if ! video_validate "$output"; then
			echo "HEVC version of $source is smaller, but is corrupted, keeping original..."
			delete_file "$output"
		else
			echo "HEVC version of $source is smaller, deleting original..."
			delete_file "$source"
		fi
	else
		echo "Original file ($source) is smaller, deleting hevc version..."
		delete_file "$output"
		# Add the original file to the skip list to avoid future conversions
		echo "$source" >> "$skip_list"
	fi

	return 0
}

# Function to scan directories for video files and convert them to HEVC format
# Arguments:
#   $1 - Directory list file path
#   $2 - Skip list file path
dir_scan() {
	local dir_list="$1"
	local skip_list="$2"

	local -a ffmpeg_args
	local needs_conversion

	while IFS= read -r dir; do
		echo "Scanning directory $dir for videos to convert to HEVC..."
		find "$(realpath "$dir")" -type f \( \
			-iname '*.mp4' -o \
			-iname '*.mkv' -o \
			-iname '*.avi' -o \
			-iname '*.mov' -o \
			-iname '*.m4v' -o \
			-iname '*.ts' -o \
			-iname '*.mts' -o \
			-iname '*.m2ts' -o \
			-iname '*.webm'  -o \
			-iname '*.mpeg' -o \
			-iname '*.qt' -o \
			-iname '*.mpg' -o \
			-iname '*.vob' -o \
			-iname '*.3gp' -o \
			-iname '*.wmv' -o \
			-iname '*.ogv' \
		\) -print0 |
		while IFS= read -r -d '' file; do
			if grep -Fxq "$file" "$skip_list"; then
				echo "File $file has been marked to be skipped."
				echo "It has most likely been found to be smaller than its HEVC equivalent."
			else
				if ! build_ffmpeg_args \
					"$file" ffmpeg_args needs_conversion; then
					echo "Skipping file because stream analysis failed: $file"
					continue
				fi

				if (( needs_conversion == 0 )); then
					echo "No video streams require conversion: $file"
					continue
				fi

				local ext="${file##*.}"
				ext="${ext,,}" # Convert to lowercase
				if [[ "$ext" = "avi" || "$ext" = "webm" ||"$ext" = "m4v" || "$ext" = "qt" ]]; then
					output="${file%.*}_hevc.mkv"
				else
					output="${file%.*}_hevc.${file##*.}"
				fi
				
				if [ -f "$output" ]; then
					if ! video_validate "$output"; then
						echo "HEVC version of video found but is corrupted."
						delete_file "$output"
					else
						size_comp "$file" "$output" "$skip_list"
						continue
					fi
				fi

				if ! conv_to_hevc "$file" "$output" "$skip_list" "${ffmpeg_args[@]}"; then
					echo
					continue
				fi

				size_comp "$file" "$output" "$skip_list"
			fi
		done
	done < "$dir_list"
}

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 <directory_list_file> <skip_list_file>"
	exit 1
fi

touch "$1"
touch "$2"

dir_scan "$1" "$2"

echo
echo "Finished conversions."
