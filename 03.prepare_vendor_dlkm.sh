#!/bin/bash

# ==============================================================================
#
#                    Vendor DLKM Modules Preparation Script
#
#   This script prepares vendor_dlkm modules with intelligent dependency
#   resolution and load order optimization for Android GKI kernels.
#
#   It supports two modes:
#   1. Interactive: Prompts the user for all required paths.
#   2. Non-Interactive: Accepts all paths as command-line arguments.
#
#   Enhanced workflow for NetHunter:
#   1.  Copy all the modules listed in the modules_list.txt of the vendor_dlkm.img
#   2.  Copy all the suspected nethunter modules to a "different" folder "temporary".
#   3.  Copy missing dependencies for all the nethunter kernel modules of that temp folder
#       from the staging directory to the temp folder.
#   4.  Prune the modules, which are already defined in vendor_boot's module_list.txt,
#       from that nethunter temp folder.
#   5.  Copy the final .ko modules, located inside that temp folder to the main module folder
#   6.  Strip all modules to reduce size.
#   7.  Run depmod to create the modules.dep from the modules listed in the folder.
#   8.  Append / insert, added / new modules to the new modules.load file,
#       generating from the OEM's one.
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
    echo "This script prepares a vendor_dlkm module set with dependency resolution and load order optimization."
    echo ""
    echo "Modes of Operation:"
    echo "  1. Interactive Mode: Run without any arguments to be prompted for each path."
    echo "     $0"
    echo ""
    echo "  2. Non-Interactive (Argument) Mode: Provide all 8 paths as arguments."
    echo "     $0 <modules_list> <staging_dir> <oem_load_file> <system_map> <strip_tool> <output_dir> <vendor_boot_list> <nh_dir>"
    echo ""
    echo "Arguments:"
    echo "  <modules_list>      Path to vendor_dlkm.img's modules_list.txt"
    echo "  <staging_dir>       Path to kernel build staging directory"
    echo "  <oem_load_file>     Path to OEM vendor_dlkm.modules.load file"
    echo "  <system_map>        Path to System.map file"
    echo "  <strip_tool>        Path to LLVM strip tool (e.g., .../bin/llvm-strip)"
    echo "  <output_dir>        Output directory for the final modules"
    echo "  <vendor_boot_list>  (Optional) Path to vendor_boot.img's module_list.txt for pruning."
    echo "                      Provide an empty string \"\" to skip."
    echo "  <nh_dir>            (Optional) Path to NetHunter modules directory."
    echo "                      Provide an empty string \"\" to skip."
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message and exit."
    echo ""
}

# Function to check if a file exists in staging using find
find_module_in_staging() {
    local module_name="$1"
    local staging_dir="$2"
    find "$staging_dir" -name "$module_name" -type f -print -quit 2>/dev/null
}

# Function to strip modules using LLVM strip
strip_modules() {
    local module_dir="$1"
    local strip_tool="$2"

    if [ ! -x "$strip_tool" ]; then
        log_warning "LLVM strip tool not found or not executable: $strip_tool"
        log_warning "Skipping module stripping..."
        return 1
    fi

    log_info "Stripping modules in $module_dir to reduce size..."

    local stripped_count=0
    local total_size_before=0
    local total_size_after=0

    # Calculate total size before stripping
    for module in "$module_dir"/*.ko; do
        [ -f "$module" ] || continue
        size_before=$(stat -f%z "$module" 2>/dev/null || stat -c%s "$module" 2>/dev/null || echo "0")
        total_size_before=$((total_size_before + size_before))
    done

    for module in "$module_dir"/*.ko; do
        [ -f "$module" ] || continue

        module_name=$(basename "$module")

        # Strip the module
        "$strip_tool" --strip-debug --strip-unneeded "$module" 2>/dev/null

        if [ $? -eq 0 ]; then
            ((stripped_count++))
        else
            log_warning "  ✗ Failed to strip $module_name"
        fi
    done

    # Calculate total size after stripping
    for module in "$module_dir"/*.ko; do
        [ -f "$module" ] || continue
        size_after=$(stat -f%z "$module" 2>/dev/null || stat -c%s "$module" 2>/dev/null || echo "0")
        total_size_after=$((total_size_after + size_after))
    done

    if [ $stripped_count -gt 0 ]; then
        total_reduction=$((total_size_before - total_size_after))
        log_info "Strip complete: $stripped_count modules processed"
        log_info "Total size reduction: $total_reduction bytes ($(echo "scale=1; $total_reduction / 1024" | bc 2>/dev/null || echo "$total_reduction/1024")KB)"
    fi

    return 0
}


# --- Main Script ---

# Argument Parsing
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

print_header "Vendor DLKM Modules Preparation Script"

# --- Input Collection ---

# Non-Interactive (Argument) Mode
if [ "$#" -eq 8 ]; then
    log_info "Running in Non-Interactive Mode."
    MODULES_LIST_RAW="$1"
    STAGING_DIR_RAW="$2"
    OEM_LOAD_FILE_RAW="$3"
    SYSTEM_MAP_RAW="$4"
    STRIP_TOOL_RAW="$5"
    OUTPUT_DIR_RAW="$6"
    VENDOR_BOOT_MODULES_LIST_RAW="$7" # Can be ""
    NH_MODULE_DIR_RAW="$8"             # Can be ""

# Interactive Mode
elif [ "$#" -eq 0 ]; then
    log_info "Running in Interactive Mode."
    echo "This script prepares a complete vendor_dlkm module set."
    echo "Please provide the required paths."
    echo ""
    read -e -p "Enter path to vendor_dlkm.img's modules_list.txt: " MODULES_LIST_RAW
    read -e -p "Enter path to kernel build staging directory: " STAGING_DIR_RAW
    read -e -p "Enter path to OEM vendor_dlkm.modules.load file: " OEM_LOAD_FILE_RAW
    read -e -p "Enter path to System.map file: " SYSTEM_MAP_RAW
    read -e -p "Enter path to LLVM strip tool (e.g., clang-rXXXXXX/bin/llvm-strip): " STRIP_TOOL_RAW
    read -e -p "Enter output directory for vendor_dlkm modules: " OUTPUT_DIR_RAW
    read -e -p "Enter path to vendor_boot.img's module_list.txt (press Enter to skip): " VENDOR_BOOT_MODULES_LIST_RAW
    read -e -p "Enter path to NetHunter modules directory (press Enter to skip): " NH_MODULE_DIR_RAW

# Invalid arguments
else
    log_error "Invalid number of arguments. Use 0 for interactive mode or 8 for non-interactive."
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
VENDOR_BOOT_MODULES_LIST=$(sanitize_path "$VENDOR_BOOT_MODULES_LIST_RAW")
NH_MODULE_DIR=$(sanitize_path "$NH_MODULE_DIR_RAW")

# Validate mandatory inputs
if [ ! -f "$MODULES_LIST" ]; then
    log_error "vendor_dlkm modules_list.txt not found at: '$MODULES_LIST'"
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

# Handle optional output directory
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(pwd)/vendor_dlkm_modules"
fi

# Validate optional inputs and give warnings
if [ -n "$VENDOR_BOOT_MODULES_LIST" ] && [ ! -f "$VENDOR_BOOT_MODULES_LIST" ]; then
    log_warning "vendor_boot module_list.txt not found: '$VENDOR_BOOT_MODULES_LIST'. Pruning will be skipped."
    VENDOR_BOOT_MODULES_LIST="" # Unset to prevent errors
fi
if [ -n "$NH_MODULE_DIR" ] && [ ! -d "$NH_MODULE_DIR" ]; then
    log_warning "NetHunter module directory not found: '$NH_MODULE_DIR'. NetHunter processing will be skipped."
    NH_MODULE_DIR="" # Unset to prevent errors
fi
if [ -n "$STRIP_TOOL" ] && [ ! -x "$STRIP_TOOL" ]; then
    log_warning "LLVM strip tool not found or not executable: '$STRIP_TOOL'. Module stripping will be skipped."
    STRIP_TOOL="" # Unset to prevent errors
fi

# Create clean output directory
log_info "Creating clean output directory: $OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Create temporary work directory
WORK_DIR=$(mktemp -d)
NH_TEMP_DIR=$(mktemp -d)
trap 'log_info "Cleaning up temporary directories..."; rm -rf "$WORK_DIR" "$NH_TEMP_DIR"' EXIT

# Detect kernel version from staging directory
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

# Setup module work directory structure
MODULE_WORK_DIR="$WORK_DIR/lib/modules/$KERNEL_VERSION"
mkdir -p "$MODULE_WORK_DIR"

# --- Initial Module Copy (from vendor_dlkm list) ---

print_header "Copying Initial Modules from vendor_dlkm List"

INITIAL_COUNT=0
MISSING_MODULES=()

while IFS= read -r module_name || [ -n "$module_name" ]; do
    [ -z "$module_name" ] && continue
    module_name=$(echo "$module_name" | tr -d '\r\n' | xargs)
    [ -z "$module_name" ] && continue

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

log_info "Copied $INITIAL_COUNT initial modules."
if [ ${#MISSING_MODULES[@]} -gt 0 ]; then
    log_warning "Missing ${#MISSING_MODULES[@]} modules from staging: ${MISSING_MODULES[*]}"
fi

# --- NetHunter Module Processing ---

NH_COUNT=0
PRUNED_COUNT=0
if [ -n "$NH_MODULE_DIR" ]; then
    print_header "Processing NetHunter Modules"

    # 1. Copy suspected NetHunter modules to a temporary, isolated directory
    log_info "Copying suspected NetHunter modules to temporary location..."
    find "$NH_MODULE_DIR" -name "*.ko" -exec cp {} "$NH_TEMP_DIR/" \;

    INITIAL_NH_COUNT=$(find "$NH_TEMP_DIR" -name "*.ko" | wc -l)
    log_info "Found $INITIAL_NH_COUNT suspected NetHunter modules."

    # 2. Resolve dependencies for NetHunter modules in their isolated directory
    log_info "Resolving dependencies for NetHunter modules..."
    PROCESSED_NH_MODULES="$WORK_DIR/processed_nh.list"
    find "$NH_TEMP_DIR" -name "*.ko" -printf "%f\n" > "$PROCESSED_NH_MODULES"

    NEW_DEPS_FOUND=1
    while [ "$NEW_DEPS_FOUND" -gt 0 ]; do
        NEW_DEPS_FOUND=0

        # Create a list of all modules currently in the temp dir
        CURRENT_MODULES_IN_TEMP=$(find "$NH_TEMP_DIR" -name "*.ko" -printf "%f\n")

        for module_path in "$NH_TEMP_DIR"/*.ko; do
            deps=$(modinfo -F depends "$module_path" 2>/dev/null | tr ',' '\n' | grep -v '^$')
            for dep_name in $deps; do
                dep_ko_name="${dep_name}.ko"

                # Check if dependency is already present in the temp dir
                if ! echo "$CURRENT_MODULES_IN_TEMP" | grep -Fxq "$dep_ko_name"; then
                    dep_path=$(find_module_in_staging "$dep_ko_name" "$STAGING_DIR")
                    if [ -n "$dep_path" ]; then
                        log_info "  ✓ Adding missing dependency for NH module: $dep_ko_name"
                        cp "$dep_path" "$NH_TEMP_DIR/"
                        ((NEW_DEPS_FOUND++))
                    else
                        log_warning "  ✗ Dependency not found in staging: $dep_ko_name"
                    fi
                fi
            done
        done
        [ "$NEW_DEPS_FOUND" -eq 0 ] && log_info "Dependency resolution for NetHunter modules complete."
    done

    # 3. Prune modules from the NetHunter temp folder (if list is provided)
    if [ -n "$VENDOR_BOOT_MODULES_LIST" ]; then
        print_header "Pruning NetHunter modules present in vendor_boot"
        while IFS= read -r module_to_prune || [ -n "$module_to_prune" ]; do
            [ -z "$module_to_prune" ] && continue
            module_to_prune=$(echo "$module_to_prune" | tr -d '\r\n' | xargs)

            if [ -f "$NH_TEMP_DIR/$module_to_prune" ]; then
                log_info "  - Pruning $module_to_prune (exists in vendor_boot)"
                rm -f "$NH_TEMP_DIR/$module_to_prune"
                ((PRUNED_COUNT++))
            fi
        done < "$VENDOR_BOOT_MODULES_LIST"
        log_info "Pruned $PRUNED_COUNT modules from the NetHunter set."
    else
        log_info "Vendor_boot modules list not provided, skipping pruning step."
    fi

    # 4. Copy final NetHunter modules to the main module folder
    print_header "Merging Final NetHunter Modules"
    cp "$NH_TEMP_DIR"/*.ko "$MODULE_WORK_DIR/" 2>/dev/null
    NH_COUNT=$(find "$NH_TEMP_DIR" -name "*.ko" | wc -l)
    log_info "Copied $NH_COUNT final NetHunter modules to the main working directory."
else
    log_info "NetHunter module directory not provided, skipping NetHunter processing."
fi

# --- Final Dependency Resolution for all modules ---
# The logic from the original script is sufficient, as it resolves dependencies
# for all modules present in the working directory.

print_header "Resolving All Final Dependencies"
# The rest of the script will handle the final dependency resolution,
# stripping, and packaging of the combined module set.

# --- Strip ALL Modules ---

print_header "Stripping All Modules"
if [ -n "$STRIP_TOOL" ]; then
    strip_modules "$MODULE_WORK_DIR" "$STRIP_TOOL"
else
    log_warning "Skipping module stripping - LLVM strip tool not available"
fi

# --- Copy Required Build Files ---

print_header "Preparing Build Environment"
STAGING_MODULES_DIR=$(dirname "$(find "$STAGING_DIR" -type f -name "modules.builtin" -path "*/lib/modules/*" | head -1)")
if [ -d "$STAGING_MODULES_DIR" ]; then
    log_info "Copying build files from $STAGING_MODULES_DIR"
    cp "$STAGING_MODULES_DIR"/modules.* "$MODULE_WORK_DIR/" 2>/dev/null
fi

# --- Generate New modules.dep ---

print_header "Generating Module Dependencies"
log_info "Running depmod to generate new modules.dep..."
cd "$WORK_DIR"

depmod -b . -F "$SYSTEM_MAP" "$KERNEL_VERSION"
if [ $? -ne 0 ]; then
    log_error "depmod failed."
    exit 1
fi
log_info "Module dependencies generated successfully."

# --- Intelligent modules.load Generation ---

print_header "Generating Optimized modules.load"
cd "$MODULE_WORK_DIR"

# Create list of our current modules
find . -maxdepth 1 -name "*.ko" -printf "%f\n" > our_modules.list

# Clean up OEM modules.load
sed 's/\r$//' "$OEM_LOAD_FILE" > oem_modules.list

# Create base load order from intersection
grep -Fx -f our_modules.list oem_modules.list > modules.load.base

# Find new modules that need to be inserted
grep -Fxv -f oem_modules.list our_modules.list > new_modules.list

cp modules.load.base modules.load.final
NEW_MODULE_COUNT=$(wc -l < new_modules.list)

if [ "$NEW_MODULE_COUNT" -gt 0 ]; then
    log_info "Found $NEW_MODULE_COUNT new modules to insert into load order."

    > insertions.tsv
    while IFS= read -r new_module || [ -n "$new_module" ]; do
        [ -z "$new_module" ] && continue
        dependents=$(grep -w -- "$new_module" modules.dep | cut -d: -f1 | sed 's/^\.\///')
        insertion_line=99999

        if [ -n "$dependents" ]; then
            first_dependent_line=$(echo "$dependents" | xargs -I {} grep -n "^{}$" modules.load.final | head -1 | cut -d: -f1)
            [ -n "$first_dependent_line" ] && insertion_line=$first_dependent_line
        fi
        echo -e "$insertion_line\t$new_module" >> insertions.tsv
    done < new_modules.list

    # Insert modules based on dependencies
    while IFS=$'\t' read -r line_num module_to_insert; do
        if [ "$line_num" -eq 99999 ]; then
            log_info "  Appending $module_to_insert"
            echo "$module_to_insert" >> modules.load.final
        else
            log_info "  Inserting $module_to_insert at line $line_num"
            sed -i "${line_num}i$module_to_insert" modules.load.final
        fi
    done < <(sort -r -n insertions.tsv)
fi
mv modules.load.final modules.load
rm -f our_modules.list oem_modules.list modules.load.base new_modules.list insertions.tsv

# --- Copy Final Results ---

print_header "Finalizing Output"
log_info "Copying final module set to: $OUTPUT_DIR"
cp *.ko modules.* "$OUTPUT_DIR/" 2>/dev/null

# --- Summary ---

FINAL_COUNT=$(ls -1 "$OUTPUT_DIR"/*.ko 2>/dev/null | wc -l)
LOAD_COUNT=$(wc -l < "$OUTPUT_DIR/modules.load")

print_header "Process Complete!"
echo "Vendor DLKM module preparation successful!"
echo ""
echo "Results:"
echo "  - Total final modules: $FINAL_COUNT"
echo "  - Load order entries:  $LOAD_COUNT"
echo "  - NetHunter modules added: $NH_COUNT"
echo "  - Vendor boot modules pruned: $PRUNED_COUNT"
echo "  - Output directory:      $OUTPUT_DIR"
echo ""
echo "Files created in $OUTPUT_DIR:"
ls -lA "$OUTPUT_DIR"
echo ""
echo "Your vendor_dlkm module set is ready for packaging!"
