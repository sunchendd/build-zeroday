#!/bin/bash
set -euo pipefail

FILE_PATH="$1"
SPLIT_SIZE="${2:-9G}"

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File not found: $FILE_PATH"
    exit 1
fi

FILE_DIR=$(dirname "$FILE_PATH")
FILE_NAME=$(basename "$FILE_PATH")
FILE_BASENAME="${FILE_NAME%.*}"
FILE_EXT="${FILE_NAME##*.}"

echo "Computing MD5 checksum..."
MD5=$(md5sum "$FILE_PATH" | awk '{print $1}')
echo "MD5: $MD5"

PREFIX="${FILE_BASENAME}_part_"

echo "Splitting $FILE_NAME into ${SPLIT_SIZE} parts..."

split -b "$SPLIT_SIZE" -d -a 2 --additional-suffix=".${FILE_EXT}" "$FILE_PATH" "${FILE_DIR}/${PREFIX}"

PART_FILES=$(ls "${FILE_DIR}/${PREFIX}"* 2>/dev/null | sort)
PART_COUNT=$(echo "$PART_FILES" | wc -l)
PART_NAMES=$(echo "$PART_FILES" | while read f; do basename "$f"; done | tr '\n' ' ')

RECONSTRUCT_FILE="${FILE_DIR}/${FILE_BASENAME}.reconstruct.txt"

cat > "$RECONSTRUCT_FILE" << EOF
original_file: ${FILE_NAME}
original_md5:  ${MD5}
split_size:    ${SPLIT_SIZE}
part_count:    ${PART_COUNT}
reconstruct_cmd: cat ${PART_NAMES}> ${FILE_NAME}
EOF

echo "Done. Split into ${PART_COUNT} parts."
echo "Reconstruct info saved to: ${RECONSTRUCT_FILE}"
