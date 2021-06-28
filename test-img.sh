#!/bin/bash

COLS=""
ROWS=""
FILE=""
OUT="/dev/stdout"
ERR="/dev/stderr"
NOESC=""

echoerr () {
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

cleanup() {
    stty $stty_orig
    rm $TMPDIR/chunk_* 2> /dev/null
    rm $TMPDIR/image* 2> /dev/null
    rmdir $TMPDIR
}

# register the cleanup function to be called on the EXIT signal
trap cleanup EXIT INT TERM

# Check if the image is a png, and if it's not, try to convert it.
if ! (file "$FILE" | grep -q "PNG image"); then
    if ! convert "$FILE" "$TMPDIR/image.png"; then
        echoerr "Cannot convert image to png"
        exit 1
    fi
    FILE="$TMPDIR/image.png"
fi

ID=1

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

# du -h "$FILE"

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

for CHUNK in $TMPDIR/chunk_*; do
    CHUNK_I=$((CHUNK_I+1))
    # echo -en "Uploading $CHUNK $CHUNK_I/$CHUNKS_COUNT\r"
    start_gr_command
    echo -en "I=$ID,m=1;"
    cat $CHUNK
    end_gr_command
done
# echo

start_gr_command
echo -en "I=$ID,m=0"
end_gr_command

consume_errors() {
    while read -r -d '\' -t 0.1 TERM_RESPONSE; do
        true
    done
}

# -r means backslash is part of the line
# -d '\' means \ is the line delimiter
# -t 0.5 is timeout
if ! read -r -d '\' -t 0.5 TERM_RESPONSE; then
    if [[ -z "$TERM_RESPONSE" ]]; then
        echoerr "No response from terminal"
    else
        echoerr "Invalid terminal response: $(sed 's/[\x01-\x1F\x7F]/?/g' <<< "$TERM_RESPONSE")"
    fi
    consume_errors
    exit 1
fi

IMAGE_ID="$(sed -n "s/^.*_G.*i=\([0-9]\+\),I=${ID}.*;OK.*$/\1/p" <<< "$TERM_RESPONSE")"

if ! [[ "$IMAGE_ID" =~ ^[0-9]+$ ]]; then
    echoerr "Invalid terminal response: $(sed 's/[\x01-\x1F\x7F]/?/g' <<< "$TERM_RESPONSE")"
    consume_errors
    exit 1
fi


IMAGE_ID="$(printf "%x" "$IMAGE_ID")"
IMAGE_SYMBOL="$(printf "\U$IMAGE_ID")"

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
