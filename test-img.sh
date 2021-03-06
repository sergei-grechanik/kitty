#!/bin/bash

# Exit the script on keyboard interrupt
trap "exit 1" INT

COLS=""
ROWS=""
FILE=""
OUT="/dev/stdout"
ERR="/dev/stderr"
NOESC=""

echostatus() {
    # clear the current line
    echo -en "\033[2K\r"
    echo -n "$1"
}

echoerr() {
    echostatus "$1"
    echo "$1" >> "$ERR"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--columns)
            COLS="$2"
            shift
            shift
            ;;
        -r|--rows)
            ROWS="$2"
            shift
            shift
            ;;
        -o|--output)
            OUT="$2"
            shift
            shift
            ;;
        -e|--err)
            ERR="$2"
            shift
            shift
            ;;
        -h|--help)
            exit 0
            ;;
        -f|--file)
            if [[ -n "$FILE" ]]; then
                echoerr "Multiple image files are not supported"
                exit 1
            fi
            FILE="$2"
            shift
            shift
            ;;
        --noesc)
            NOESC=1
            shift
            ;;
        -*)
            echoerr "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -n "$FILE" ]]; then
                echoerr "Multiple image files are not supported: $FILE and $1"
                exit 1
            fi
            FILE="$1"
            shift
            ;;
    esac
done

if [[ -z "$COLS" ]]; then
    COLS=50
fi

if [[ -z "$ROWS" ]]; then
    ROWS=15
fi


# Create a temporary directory to store the chunked image.
TMPDIR="$(mktemp -d)"

if [[ ! "$TMPDIR" || ! -d "$TMPDIR" ]]; then
    echoerr "Can't create a temp dir"
    exit 1
fi

# echo $TMPDIR


# We need to disable echo, otherwise the response from the terminal containing
# the image id will get echoed.
stty_orig=`stty -g`
stty -echo
# Disable ctrl-z
stty susp undef

consume_errors() {
    while read -r -d '\' -t 0.1 TERM_RESPONSE; do
        true
    done
}

cleanup() {
    consume_errors
    stty $stty_orig
    rm $TMPDIR/chunk_* 2> /dev/null
    rm $TMPDIR/image* 2> /dev/null
    rmdir $TMPDIR
}

# register the cleanup function to be called on the EXIT signal
trap cleanup EXIT TERM

# Check if the file exists
if ! [[ -f "$FILE" ]]; then
    echoerr "File not found: $FILE (pwd: $(pwd))"
    exit 1
fi

#####################################################################
# Helper functions
#####################################################################

# Functions to emit the start and the end of a graphics command
if [[ -n "$TMUX" ]] && [[ "$TERM" =~ "screen" ]]; then
    start_gr_command() {
        echo -en '\ePtmux;\e\e_G'
    }
    end_gr_command() {
        echo -en '\e\e\\\e\\'
    }
else
    start_gr_command() {
        echo -en '\e_G'
    }
    end_gr_command() {
        echo -en '\e\\'
    }
fi

# Get a response from the terminal and store it in TERM_RESPONSE
# aborts the script if there is no response
get_terminal_response() {
    TERM_RESPONSE=""
    # -r means backslash is part of the line
    # -d '\' means \ is the line delimiter
    # -t 0.5 is timeout
    if ! read -r -d '\' -t 2 TERM_RESPONSE; then
        if [[ -z "$TERM_RESPONSE" ]]; then
            echoerr "No response from terminal"
        else
            echoerr "Invalid terminal response: $(sed 's/[\x01-\x1F\x7F]/?/g' <<< "$TERM_RESPONSE")"
        fi
        exit 1
    fi
}


# Output characters representing the image
output_image() {
    local IMAGE_ID="$(printf "%x" "$1")"
    local IMAGE_SYMBOL="$(printf "\U$IMAGE_ID")"

    echostatus "Successfully received imaged id: $IMAGE_ID"
    echostatus

    # Clear the output file
    > "$OUT"

    # Fill the output with characters representing the image
    for Y in `seq 0 $(expr $ROWS - 1)`; do
        if [[ -z "$NOESC" ]]; then
            echo -en "\e[38;5;${Y}m" >> "$OUT"
        fi
        for X in `seq 0 $(expr $COLS - 1)`; do
            echo -en "$IMAGE_SYMBOL" >> "$OUT"
        done
        printf "\n" >> "$OUT"
    done

    return 0
}

#####################################################################
# Try to query the image client id by md5sum
#####################################################################

echostatus "Trying to find image by md5sum"

# Compute image IMGUID
IMGUID="$(md5sum "$FILE" | cut -f 1 -d " ")x${ROWS}x${COLS}"
# Pad it with '='' so it looks like a base64 encoding of something
UID_LEN="${#IMGUID}"
PAD_LEN="$((4 - ($UID_LEN % 4)))"
for i in $(seq $PAD_LEN); do
    IMGUID="${IMGUID}="
done

# a=U    the action is to query the image by IMGUID
# I=$ID  just some number, should be the same in the response
# U=...  unique identifier
start_gr_command
echo -en "a=U,q=1;${IMGUID}"
end_gr_command

get_terminal_response

IMAGE_ID="$(sed -n "s/^.*_G.*i=\([0-9]\+\).*;OK.*$/\1/p" <<< "$TERM_RESPONSE")"

if ! [[ "$IMAGE_ID" =~ ^[0-9]+$ ]]; then
    NOT_FOUND="$(sed -n "s/^.*_G.*;.*NOT.*FOUND.*$/NOTFOUND/p" <<< "$TERM_RESPONSE")"
    if [[ -z "$NOT_FOUND" ]]; then
        echoerr "Invalid terminal response: $(sed 's/[\x01-\x1F\x7F]/?/g' <<< "$TERM_RESPONSE")"
        exit 1
    fi
else
    output_image "$IMAGE_ID"
    exit 0
fi

#####################################################################
# Chunk and upload the image
#####################################################################

# Check if the image is a png, and if it's not, try to convert it.
if ! (file "$FILE" | grep -q "PNG image"); then
    echostatus "Converting $FILE to png"
    if ! convert "$FILE" "$TMPDIR/image.png"; then
        echoerr "Cannot convert image to png"
        exit 1
    fi
    FILE="$TMPDIR/image.png"
fi

ID=$RANDOM

cat "$FILE" | base64 -w0 | split -b 4096 - "$TMPDIR/chunk_"

# a=t    the action is to transmit data
# I=$ID
# f=100  PNG
# t=d    transmit data directly
# c=,r=  width and height in cells
# s=,v=  width and height in pixels (not used)
# o=z    use compression (not used)
# m=1    multi-chunked data
start_gr_command
echo -en "a=t,I=$ID,f=100,t=d,c=${COLS},r=${ROWS},m=1"
end_gr_command

CHUNKS_COUNT="$(ls -1 $TMPDIR/chunk_* | wc -l)"
CHUNK_I=0
STARTTIME="$(date +%s)"
SPEED=""

for CHUNK in $TMPDIR/chunk_*; do
    CHUNK_I=$((CHUNK_I+1))
    if [[ $((CHUNK_I % 10)) -eq 1 ]]; then
        # Do not compute the speed too often
        if [[ $((CHUNK_I % 100)) -eq 1 ]]; then
            CURTIME="$(date +%s)"
            TIMEDIFF="$((CURTIME - STARTTIME))"
            if [[ "$TIMEDIFF" -ne 0 ]]; then
                SPEED="$(((CHUNK_I*4 - 4)/TIMEDIFF)) K/s"
            fi
        fi
        echostatus "$((CHUNK_I*4))/$((CHUNKS_COUNT*4))K [$SPEED]"
    fi
    start_gr_command
    echo -en "I=$ID,m=1;"
    cat $CHUNK
    end_gr_command
done

start_gr_command
echo -en "I=$ID,m=0"
end_gr_command

echostatus "Awaiting terminal response"
get_terminal_response

IMAGE_ID="$(sed -n "s/^.*_G.*i=\([0-9]\+\),I=${ID}.*;OK.*$/\1/p" <<< "$TERM_RESPONSE")"

if ! [[ "$IMAGE_ID" =~ ^[0-9]+$ ]]; then
    echoerr "Invalid terminal response: $(sed 's/[\x01-\x1F\x7F]/?/g' <<< "$TERM_RESPONSE")"
    exit 1
else
    # Set UID for the uploaded image.
    start_gr_command
    echo -en "a=U,i=$IMAGE_ID,q=1;${IMGUID}"
    end_gr_command

    output_image "$IMAGE_ID"
    exit 0
fi
