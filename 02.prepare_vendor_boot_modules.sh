#!/bin/bash

# ==============================================================================
#
#                    Vendor Boot Modules Preparation Script
#
#   This script prepares vendor_boot modules with intelligent dependency
#   resolution and load order optimization for Android GKI kernels.
#   It supports both interactive and non-interactive modes.
#
#   Workflow:
#   1. Copy modules from master list (modules_list.txt)
#   2. Iteratively resolve all dependencies from staging directory
#   3. Strip modules using LLVM strip to reduce size
#   4. Generate updated modules.dep with depmod
#   5. Use OEM modules.load file without injecting new modules
#   6. Create complete vendor_boot module set
#
#                              - ravindu644
# ==============================================================================

# Disable exit on error temporarily for better control
set +e

# --- Functions ---

print_header() {
    echo "========================================================================"
    echo "$1"
    echo "========================================================================"
}

sanitize_path() {
    echo "$1" | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//'
}

log_info() {
    echo "[INFO] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1"
}

show_help() {
    echo "Usage: $0 [OPTIONS] [ARGUMENTS...]"
    echo ""
    echo "This script prepares a vendor_boot module set with dependency resolution and stripping."
    echo ""
    echo "Modes of Operation:"
    echo "  1. Interactive Mode: Run without any arguments to be prompted for each path."
    echo "     $0"
    echo ""
    echo "  2. Non-Interactive (Argument) Mode: Provide all 6 paths as arguments."
    echo "     $0 <modules_list> <staging_dir> <oem_load_file> <system_map> <strip_tool> <output_dir>"
    echo ""
    echo "Arguments:"
    echo "  <modules_list>      Path to modules_list.txt (from previous script)"
    echo "  <staging_dir>       Path to kernel build staging directory"
    echo "  <oem_load_file>     Path to OEM vendor_boot.modules.load file"
    echo "  <system_map>        Path to System.map file"
    echo "  <strip_tool>        Path to LLVM strip tool (e.g., .../bin/llvm-strip)"
    echo "  <output_dir>        Output directory for the final modules"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message and exit."
    echo ""
}


find_module_in_staging() {
    local module_name="$1"
    local staging_dir="$2"
    find "$staging_dir" -name "$module_name" -type f -print -quit 2>/dev/null
}

strip_modules() {
    local module_dir="$1"
    local strip_tool="$2"

    if [ ! -x "$strip_tool" ]; then
        log_warning "LLVM strip tool not found or not executable: $strip_tool"
        log_warning "Skipping module stripping..."
        return 1
    fi

    log_info "Stripping modules to reduce size..."

    local stripped_count=0
    local total_size_before=0
    local total_size_after=0

    for module in "$module_dir"/*.ko; do
        [ -f "$module" ] || continue
        size_before=$(stat -f%z "$module" 2>/dev/null || stat -c%s "$module" 2>/dev/null || echo "0")
        total_size_before=$((total_size_before + size_before))
    done

    for module in "$module_dir"/*.ko; do
        [ -f "$module" ] || continue

        module_name=$(basename "$module")
        size_before=$(stat -f%z "$module" 2>/dev/null || stat -c%s "$module" 2>/dev/null || echo "0")

        "$strip_tool" --strip-debug --strip-unneeded "$module" 2>/dev/null

        if [ $? -eq 0 ]; then
            size_after=$(stat -f%z "$module" 2>/dev/null || stat -c%s "$module" 2>/dev/null || echo "0")
            total_size_after=$((total_size_after + size_after))

            if [ "$size_before" -gt "$size_after" ]; then
                reduction=$((size_before - size_after))
                log_info "  ✓ Stripped $module_name: ${size_before} → ${size_after} bytes (-${reduction} bytes)"
            else
                log_info "  ✓ Processed $module_name: ${size_after} bytes (no reduction)"
            fi
            ((stripped_count++))
        else
            log_warning "  ✗ Failed to strip $module_name"
            size_after=$(stat -f%z "$module" 2>/dev/null || stat -c%s "$module" 2>/dev/null || echo "0")
            total_size_after=$((total_size_after + size_after))
        fi
    done

    if [ $stripped_count -gt 0 ]; then
        total_reduction=$((total_size_before - total_size_after))
        log_info "Strip complete: $stripped_count modules processed"
        log_info "Total size reduction: $total_reduction bytes ($(echo "scale=1; $total_reduction / 1024" | bc 2>/dev/null || echo "$total_reduction/1024")KB)"
    fi

    return 0
}

# --- Main Script ---

# --- Argument Parsing ---
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

print_header "Vendor Boot Modules Preparation Script"

# --- Input Collection ---

# Non-Interactive (Argument) Mode
if [ "$#" -eq 6 ]; then
    log_info "Running in Non-Interactive Mode."
    MODULES_LIST_RAW="$1"
    STAGING_DIR_RAW="$2"
    OEM_LOAD_FILE_RAW="$3"
    SYSTEM_MAP_RAW="$4"
    STRIP_TOOL_RAW="$5"
    OUTPUT_DIR_RAW="$6"

# Interactive Mode
elif [ "$#" -eq 0 ]; then
    log_info "Running in Interactive Mode."
    echo "This script prepares a complete vendor_boot module set."
    echo ""
    read -e -p "Enter path to modules_list.txt (from previous script): " MODULES_LIST_RAW
    read -e -p "Enter path to kernel build staging directory: " STAGING_DIR_RAW
    read -e -p "Enter path to OEM vendor_boot.modules.load file: " OEM_LOAD_FILE_RAW
    read -e -p "Enter path to System.map file: " SYSTEM_MAP_RAW
    read -e -p "Enter path to LLVM strip tool (e.g., clang-rXXXXXX/bin/llvm-strip): " STRIP_TOOL_RAW
    read -e -p "Enter output directory for vendor_boot modules: " OUTPUT_DIR_RAW

# Invalid arguments
else
    log_error "Invalid number of arguments. Use 0 for interactive mode or 6 for non-interactive."
    show_help
    exit 1
fi

print_header "Setup and Validation"

# --- Input Sanitize and Validation ---
MODULES_LIST=$(sanitize_path "$MODULES_LIST_RAW")
STAGING_DIR=$(sanitize_path "$STAGING_DIR_RAW")
OEM_LOAD_FILE=$(sanitize_path "$OEM_LOAD_FILE_RAW")
SYSTEM_MAP=$(sanitize_path "$SYSTEM_MAP_RAW")
STRIP_TOOL=$(sanitize_path "$STRIP_TOOL_RAW")
OUTPUT_DIR=$(sanitize_path "$OUTPUT_DIR_RAW")

if [ ! -f "$MODULES_LIST" ]; then
    log_error "modules_list.txt not found at: '$MODULES_LIST'"
    exit 1
fi
if [ ! -d "$STAGING_DIR" ]; then
    log_error "Staging directory not found: '$STAGING_DIR'"
    exit 1
fi
if [ ! -f "$OEM_LOAD_FILE" ]; then
    log_error "OEM modules.load file not found: '$OEM_LOAD_FILE'"
    exit 1
fi
if [ ! -f "$SYSTEM_MAP" ]; then
    log_error "System.map file not found: '$SYSTEM_MAP'"
    exit 1
fi
if [ -n "$STRIP_TOOL" ] && [ ! -x "$STRIP_TOOL" ]; then
    log_warning "LLVM strip tool not found or not executable: '$STRIP_TOOL'. Module stripping will be skipped."
    STRIP_TOOL=""
fi
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(pwd)/vendor_boot_modules"
fi

log_info "Creating clean output directory: $OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

WORK_DIR=$(mktemp -d)
trap 'log_info "Cleaning up temporary directory..."; rm -rf "$WORK_DIR"' EXIT

FIRST_KO=$(find "$STAGING_DIR" -name "*.ko" -print -quit)
if [ -z "$FIRST_KO" ]; then
    log_error "No .ko files found in staging directory"
    exit 1
fi

KERNEL_VERSION=$(modinfo "$FIRST_KO" | grep -m 1 "vermagic:" | awk '{print $2}')
if [ -z "$KERNEL_VERSION" ]; then
    log_error "Could not determine kernel version from modules"
    exit 1
fi
log_info "Detected kernel version: $KERNEL_VERSION"

MODULE_WORK_DIR="$WORK_DIR/lib/modules/$KERNEL_VERSION"
mkdir -p "$MODULE_WORK_DIR"

print_header "Copying Initial Module Set"

INITIAL_COUNT=0
MISSING_MODULES=()
log_info "Processing modules from list..."

while IFS= read -r module_name || [ -n "$module_name" ]; do
    [ -z "$module_name" ] && continue
    module_name=$(echo "$module_name" | tr -d '\r\n' | xargs)
    [ -z "$module_name" ] && continue

    log_info "Looking for: $module_name"
    module_path=$(find_module_in_staging "$module_name" "$STAGING_DIR")

    if [ -n "$module_path" ] && [ -f "$module_path" ]; then
        cp "$module_path" "$MODULE_WORK_DIR/"
        if [ $? -eq 0 ]; then
            ((INITIAL_COUNT++))
            log_info "✓ Copied: $module_name"
        else
            log_warning "✗ Failed to copy: $module_name"
        fi
    else
        MISSING_MODULES+=("$module_name")
        log_warning "✗ Module not found in staging: $module_name"
    fi
done < "$MODULES_LIST"

log_info "Copied $INITIAL_COUNT modules from initial list"
if [ ${#MISSING_MODULES[@]} -gt 0 ]; then
    log_warning "Missing ${#MISSING_MODULES[@]} modules from staging directory"
    echo "Missing modules: ${MISSING_MODULES[*]}"
fi

print_header "Resolving Dependencies"

log_info "Starting iterative dependency resolution..."
PROCESSED_MODULES_FILE="$WORK_DIR/processed_modules.list"
touch "$PROCESSED_MODULES_FILE"
PROCESSING_QUEUE_FILE="$WORK_DIR/processing_queue.list"
find "$MODULE_WORK_DIR" -name "*.ko" -printf "%f\n" > "$PROCESSING_QUEUE_FILE"

ITERATION=0
while [ -s "$PROCESSING_QUEUE_FILE" ]; do
    ((ITERATION++))
    log_info "Dependency resolution iteration $ITERATION"
    NEW_QUEUE_FILE="$WORK_DIR/new_queue_$ITERATION.list"
    touch "$NEW_QUEUE_FILE"
    NEW_DEPS_FOUND=0

    while IFS= read -r module_name || [ -n "$module_name" ]; do
        [ -z "$module_name" ] && continue
        if grep -Fxq "$module_name" "$PROCESSED_MODULES_FILE" 2>/dev/null; then
            continue
        fi
        module_path="$MODULE_WORK_DIR/$module_name"
        if [ ! -f "$module_path" ]; then
            log_warning "Module file not found during processing: $module_name"
            continue
        fi
        log_info "Processing dependencies for: $module_name"
        deps=$(modinfo -F depends "$module_path" 2>/dev/null | tr ',' '\n' | grep -v '^$' || true)
        if [ -n "$deps" ]; then
            log_info "  Dependencies found: $(echo "$deps" | tr '\n' ' ')"
            while IFS= read -r dep_name || [ -n "$dep_name" ]; do
                [ -z "$dep_name" ] && continue
                dep_ko_name="${dep_name}.ko"
                if [ -f "$MODULE_WORK_DIR/$dep_ko_name" ]; then
                    continue
                fi
                dep_path=$(find_module_in_staging "$dep_ko_name" "$STAGING_DIR")
                if [ -n "$dep_path" ] && [ -f "$dep_path" ]; then
                    log_info "  ✓ Adding missing dependency: $dep_ko_name"
                    cp "$dep_path" "$MODULE_WORK_DIR/"
                    if [ $? -eq 0 ]; then
                        echo "$dep_ko_name" >> "$NEW_QUEUE_FILE"
                        ((NEW_DEPS_FOUND++))
                    fi
                else
                    log_warning "  ✗ Dependency not found in staging: $dep_ko_name"
                fi
            done <<< "$deps"
        else
            log_info "  No dependencies found"
        fi
        echo "$module_name" >> "$PROCESSED_MODULES_FILE"
    done < "$PROCESSING_QUEUE_FILE"

    log_info "Iteration $ITERATION complete - Added $NEW_DEPS_FOUND new dependencies"
    mv "$NEW_QUEUE_FILE" "$PROCESSING_QUEUE_FILE"
    if [ $ITERATION -gt 10 ]; then
        log_warning "Maximum iterations reached, stopping dependency resolution"
        break
    fi
    if [ $NEW_DEPS_FOUND -eq 0 ]; then
        log_info "No new dependencies found, resolution complete"
        break
    fi
done

FINAL_MODULE_COUNT=$(find "$MODULE_WORK_DIR" -name "*.ko" | wc -l)
log_info "Dependency resolution complete - Final module count: $FINAL_MODULE_COUNT"

print_header "Stripping Modules"
if [ -n "$STRIP_TOOL" ]; then
    strip_modules "$MODULE_WORK_DIR" "$STRIP_TOOL"
else
    log_warning "Skipping module stripping - LLVM strip tool not available"
fi

print_header "Preparing Build Environment"
STAGING_MODULES_DIR=$(dirname "$(find "$STAGING_DIR" -type f -name "modules.builtin" -path "*/lib/modules/*" | head -1)")
if [ -d "$STAGING_MODULES_DIR" ]; then
    log_info "Copying build files from $STAGING_MODULES_DIR"
    cp "$STAGING_MODULES_DIR"/modules.* "$MODULE_WORK_DIR/" 2>/dev/null
fi

print_header "Generating Module Dependencies"
log_info "Running depmod to generate new modules.dep..."
cd "$WORK_DIR"
depmod -b . -F "$SYSTEM_MAP" "$KERNEL_VERSION"
if [ $? -ne 0 ]; then
    log_error "depmod failed"
    exit 1
fi
log_info "Module dependencies generated successfully"

print_header "Using OEM modules.load (No Modifications)"
log_info "Copying OEM modules.load without adding or removing entries"
cp "$OEM_LOAD_FILE" "$MODULE_WORK_DIR/modules.load"
log_info "modules.load copied directly"

print_header "Finalizing Output"
log_info "Copying final module set to: $OUTPUT_DIR"
cp "$MODULE_WORK_DIR"/*.ko "$OUTPUT_DIR/" 2>/dev/null || true
cp "$MODULE_WORK_DIR"/modules.* "$OUTPUT_DIR/" 2>/dev/null || true

FINAL_COUNT=$(ls -1 "$OUTPUT_DIR"/*.ko 2>/dev/null | wc -l)
LOAD_COUNT=$(wc -l < "$OUTPUT_DIR/modules.load" 2>/dev/null || echo "0")

print_header "Process Complete!"
echo "Vendor boot module preparation successful!"
echo ""
echo "Results:"
echo "  - Total final modules: $FINAL_COUNT"
echo "  - Load order entries:  $LOAD_COUNT"
echo "  - Output directory:      $OUTPUT_DIR"
echo ""
echo "Files created in $OUTPUT_DIR:"
ls -lA "$OUTPUT_DIR" 2>/dev/null || echo "No files found in output directory"
echo ""
echo "Your vendor_boot module set is ready for packaging!"
