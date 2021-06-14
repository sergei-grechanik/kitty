#!/bin/bash

echoerr () {
    echo $1 > /dev/stderr
}

FILE="$1"

W="$2"
H="$3"

if [[ -z "$W" ]]; then
    W=20
fi

if [[ -z "$H" ]]; then
    H=20
fi


# Create a temporary directory to store the chunked image.
TMPDIR="$(mktemp -d)"

if [[ ! "$TMPDIR" || ! -d "$TMPDIR" ]]; then
    echoerr "Can't create a temp dir"
    exit 1
fi

echo $TMPDIR


# We need to disable echo, otherwise the response from the terminal containing
# the image id will get echoed.
stty_orig=`stty -g`
stty -echo

cleanup() {
    stty $stty_orig
    rm $TMPDIR/chunk_*
    rmdir $TMPDIR
}

# register the cleanup function to be called on the EXIT signal
trap cleanup EXIT INT TERM

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

cat "$FILE" | base64 -w0 | split -b 4096 - "$TMPDIR/chunk_"

ls $TMPDIR

# a=t    the action is to transmit data
# I=$ID
# f=100  PNG
# t=d    transmit data directly
# c=,r=  width and height in cells
# s=,v=  width and height in pixels (not used)
# o=z    use compression (not used)
# m=1    multi-chunked data
start_gr_command
echo -en "a=t,I=$ID,f=100,t=d,c=${W},r=${H},m=1"
end_gr_command

for CHUNK in $TMPDIR/chunk_*; do
    echo Uploading $CHUNK
    start_gr_command
    echo -en "I=$ID,m=1;"
    cat $CHUNK
    end_gr_command
done

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
echo "id: $IMAGE_ID"

if ! [[ "$IMAGE_ID" =~ ^[0-9]+$ ]]; then
    echoerr "Invalid terminal response: $(sed 's/[\x01-\x1F\x7F]/?/g' <<< "$TERM_RESPONSE")"
    consume_errors
    exit 1
fi


IMAGE_ID="$(printf "%x" "$IMAGE_ID")"
echo "Hex id: $IMAGE_ID"
IMAGE_SYMBOL="$(printf "\U$IMAGE_ID")"

for Y in `seq 0 $(expr $H - 1)`; do
    for X in `seq 0 $(expr $W - 1)`; do
        echo -en "\e[48;2;${X};150;${Y}m\e[38;5;${Y}m$IMAGE_SYMBOL"
    done
    echo -en $Y
    printf "\n"
done

# for Y in `seq 0 $H`; do
#     for X in `seq 0 $W`; do
#         echo -en "\e[48;2;${X}0;150;${Y}0m\e[38;2;${ID};${X};${Y}m@"
#     done
#     printf "\n"
# done
