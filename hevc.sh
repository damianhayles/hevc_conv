#!/bin/bash
set -o pipefail


# Bash script to convert videos to HEVC format using ffmpeg and ffprobe.
# Usage: ./hevc.sh <directory_list_file> <skip_list_file>


show_progress() {
	local operation="$1"
	local duration="$2"

	local progress="0.00" curr_time=0 curr_h=0 curr_m=0 curr_s=0
	local dur_int=0 dur_h=0 dur_m=0 dur_s=0
	local fps="-" speed="-" size=0 size_fmt="0 B"
	local key value

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
					curr_m=$(((curr_time % 3600) / 60 ))
					curr_s=$((curr_time % 60))

					dur_int=${duration%.*}
					dur_h=$((dur_int / 3600))
					dur_m=$(((dur_int % 3600) / 60 ))
					dur_s=$((dur_int % 60))

					# Format the size in a human-readable format
					if [ "${size:-0}" -ge 1073741824 ]; then
						size_fmt=$(awk -v s="$size" 'BEGIN { printf "%.2f GB", s / 1073741824 }')
					elif [ "${size:-0}" -ge 1048576 ]; then
						size_fmt=$(awk -v s="$size" 'BEGIN { printf "%.2f MB", s / 1048576 }')
					elif [ "${size:-0}" -ge 1024 ]; then
						size_fmt=$(awk -v s="$size" 'BEGIN { printf "%.2f KB", s / 1024 }')
					else
						size_fmt="${size:-0} B"
					fi
					;;
				fps)
					fps="$value"
					;;
				speed)
					speed="$value"
					;;
				total_size)
					size="$value"
					;;
				progress)
					# When ffmpeg reports progress, print the current status
					printf "\r\033[K%s: %s%% | Time: %02d:%02d:%02d / %02d:%02d:%02d | FPS: %s | Speed: %s | Size: %s" \
					"$operation" \
					"$progress" \
					"$curr_h" "$curr_m" "$curr_s" \
					"$dur_h" "$dur_m" "$dur_s" \
					"$fps" \
					"$speed" \
					"$size_fmt"
			esac
			
		done;
}

# Function to convert a video to HEVC format
# Arguments:
#   $1 - Input video file path
#   $2 - Output video file path
# Returns:
#   0 - Success
#   1 - Failure
conv_to_hevc() {
	echo
	echo "Converting: $1"
	echo "        To: $2"
	
	# Create a temporary output file name
	# with a .part extension to avoid overwriting the original file in case of failure
	local temp="${2%.*}.part.${2##*.}"
	rm -f "$temp"
	
	local duration=$(ffprobe -v error \
		-select_streams v:0 \
		-show_entries format=duration \
		-of csv=p=0 "$1")

	if [[ -z "$duration" || ! "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		echo "Invalid video duration: $duration"
		return 1
	fi

	# Convert the video to HEVC format using ffmpeg
	if ! ffmpeg -nostdin -n -i "$1" \
	    -map 0 \
	    -c:v libx265 \
	    -crf 20 \
	    -preset medium \
	    -c:a copy \
	    -c:s copy \
		-progress pipe:1 \
		-nostats \
	    "$temp" 2>/dev/null |
		show_progress "Converting" "$duration"; then

			echo
			echo "Conversion failed: $1"
			rm -f "$temp"
			return 1

	fi

	echo
	echo "HEVC created."
	
	if ! mv "$temp" "$2"; then
		echo "Failed to rename temporary file to final output: $temp -> $2"
		rm -f "$temp"
		return 1
	fi
	return 0
		
}

# Function to validate a video file using ffmpeg
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
		-map 0:v -map 0:a? \
		-f null - \
		-progress pipe:1 \
		-nostats 2>/dev/null |
		show_progress "Verifying" "$duration"; then

		echo
		echo "Video failed validation: $1"
		return 1
	fi
	
	echo
	echo "Video passed validation: $1"
	return 0
}


# Function to compare the sizes of the original and HEVC converted files
# Arguments:
#   $1 - Original video file path
#   $2 - HEVC converted video file path
#   $3 - Skip list file path
size_comp() {
	local h264size=$(stat -c%s "$1")
	local hevcsize=$(stat -c%s "$2")

	if [ "$h264size" -gt "$hevcsize" ]; then
		# verify that the HEVC file is valid before deleting the original
		if ! video_validate "$2"; then
			echo
			echo "HEVC version of $1 is smaller, but is corrupted, keeping original..."
			rm -f -- "$2"
		else
			echo
			echo "HEVC version of $1 is smaller, deleting original..."
			rm -f -- "$1"
			echo "Deleted."
		fi
	else
		echo
		echo "Original file ($1) is smaller, deleting hevc version..."
		rm -f -- "$2"
		echo "$1" >> "$3"
		echo "Deleted."
	fi
}

# Function to scan directories for video files and convert them to HEVC format
# Arguments:
#   $1 - Directory list file path
#   $2 - Skip list file path
dir_scan() {
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
			-iname '*.qt' \
		\) -print0 |
		while IFS= read -r -d '' file; do
			if grep -Fxq "$file" "$2"; then
				echo
				echo "File $file has been marked to be skipped."
				echo "It has most likely been found to be smaller than its HEVC equivalent."
			else
				codec=$(ffprobe -v error \
				-select_streams v:0 \
				-show_entries stream=codec_name \
				-of csv=p=0 "$file")

				if [ "$codec" = "h264" ] || \
				[ "$codec" = "mpeg4" ] || \
				[ "$codec" = "mpeg2video" ] || \
				[ "$codec" = "vc1" ] || \
				[ "$codec" = "vp8" ] || \
				[ "$codec" = "theora" ]; then
					
					output="${file%.*}_hevc.mp4"
					
					if [ -f "$output" ]; then
						if ! video_validate "$output"; then
							echo
							echo "HEVC version of video found but is corrupted."
							rm -f "$output"
						else
							size_comp "$file" "$output" "$2"
							continue
						fi
					fi

						if ! conv_to_hevc "$file" "$output"; then
							continue
						fi

					size_comp "$file" "$output" "$2"
				else
					echo
					echo "File $file is either HEVC already, or is encoded in a codec that is just as or more efficient than HEVC."
		    	fi
			fi
		done
	done < "$1"
}

touch "$1"
touch "$2"

dir_scan "$1" "$2"

echo
echo "Finished conversions."
