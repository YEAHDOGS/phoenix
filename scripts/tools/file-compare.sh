#!/bin/bash

# Function to sanitize the input path
sanitize_path() {
    local path="$1"
    # Remove literal double and single quotes
    path="${path//\"/}"
    path="${path//\'/}"
    # Convert Windows backslashes to forward slashes
    path="${path//\\//}"
    # Expand tilde if present
    path="${path/#\~/$HOME}"
    echo "$path"
}

# Prompt for the first file path
read -r -p "Enter path to File 1: " INPUT_1
FILE_1=$(sanitize_path "$INPUT_1")

if [ ! -f "$FILE_1" ]; then
    echo "Error: File 1 not found at '$FILE_1'"
    exit 1
fi

# Prompt for the second file path
read -r -p "Enter path to File 2: " INPUT_2
FILE_2=$(sanitize_path "$INPUT_2")

if [ ! -f "$FILE_2" ]; then
    echo "Error: File 2 not found at '$FILE_2'"
    exit 1
fi

# Temporary files for sorted strings
STRINGS_1=$(mktemp)
STRINGS_2=$(mktemp)

echo -e "\n[+] Extracting and sorting strings..."
strings "$FILE_1" | sort -u > "$STRINGS_1"
strings "$FILE_2" | sort -u > "$STRINGS_2"

echo "[+] Comparing differences..."

# Strings unique to File 1
UNIQUE_1=$(comm -23 "$STRINGS_1" "$STRINGS_2")

# Strings unique to File 2
UNIQUE_2=$(comm -13 "$STRINGS_1" "$STRINGS_2")

# Clean up temp files immediately
rm "$STRINGS_1" "$STRINGS_2"

echo "=================================================="
echo "Strings UNIQUE to File 1:"
echo "=================================================="
if [ -n "$UNIQUE_1" ]; then
    echo "$UNIQUE_1"
    echo "--------------------------------------------------"
    echo "Total unique strings in File 1: $(echo "$UNIQUE_1" | wc -l)"
else
    echo "No unique strings found in File 1."
fi

echo -e "\n=================================================="
echo "Strings UNIQUE to File 2:"
echo "=================================================="
if [ -n "$UNIQUE_2" ]; then
    echo "$UNIQUE_2"
    echo "--------------------------------------------------"
    echo "Total unique strings in File 2: $(echo "$UNIQUE_2" | wc -l)"
else
    echo "No unique strings found in File 2."
fi