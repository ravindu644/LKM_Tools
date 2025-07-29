#!/bin/bash

# ==============================================================================
#
#                    Stock Modules List Extractor
#
#   A simple, interactive script that extracts all module names from a
#   stock modules.dep file and outputs them to a clean text file.
#
#   Purpose: Generate a master list of all LKM (.ko) files referenced
#           in the original modules.dep for Android GKI kernel builds.
#
#                              - ravindu644
# ==============================================================================

set -e  # Exit on any error

# --- Functions ---

print_header() {
    echo "========================================================================"
    echo "$1"
    echo "========================================================================"
}

sanitize_path() {
    # Remove quotes that might come from drag-and-drop or copy-paste
    echo "$1" | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//'
}

# --- Main Script ---

print_header "Stock Modules List Extractor"

echo "This script extracts all module names from a stock modules.dep file"
echo "and creates a clean list in 'modules_list.txt'."
echo ""

# Get input file path
read -e -p "Enter the path to your stock modules.dep file: " MODULES_DEP_RAW
MODULES_DEP=$(sanitize_path "$MODULES_DEP_RAW")

# Validate input file
if [ ! -f "$MODULES_DEP" ]; then
    echo "ERROR: modules.dep file not found at: '$MODULES_DEP'"
    exit 1
fi

# Get output directory (default to current directory)
read -e -p "Enter output directory (press Enter for current directory): " OUTPUT_DIR_RAW
OUTPUT_DIR=$(sanitize_path "$OUTPUT_DIR_RAW")

# Use current directory if empty
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(pwd)"
fi

# Validate output directory
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "ERROR: Output directory not found: '$OUTPUT_DIR'"
    exit 1
fi

OUTPUT_FILE="$OUTPUT_DIR/modules_list.txt"

print_header "Processing modules.dep file"

echo "Input file: $MODULES_DEP"
echo "Output file: $OUTPUT_FILE"
echo ""

# Extract module names from modules.dep
# The modules.dep format: "module.ko: dependency1.ko dependency2.ko ..."
# We need to extract both the main modules and their dependencies
echo "Extracting module names..."

# Process the modules.dep file:
# 1. Replace colons and spaces with newlines to separate all modules
# 2. Filter lines containing '.ko' (actual module files)
# 3. Extract just the filename using basename
# 4. Sort and remove duplicates
tr ' :' '\n' < "$MODULES_DEP" | \
    grep '\.ko' | \
    xargs -n1 basename | \
    sort -u > "$OUTPUT_FILE"

# Count the results
MODULE_COUNT=$(wc -l < "$OUTPUT_FILE")

print_header "Extraction Complete"

echo "Successfully extracted $MODULE_COUNT unique module names"
echo "Output saved to: $OUTPUT_FILE"
echo ""

# Show a preview of the first 10 modules
echo "Preview (first 10 modules):"
echo "----------------------------"
head -10 "$OUTPUT_FILE"

if [ "$MODULE_COUNT" -gt 10 ]; then
    echo "..."
    echo "(and $((MODULE_COUNT - 10)) more modules)"
fi

echo ""
echo "Done! Your modules list is ready for use."

