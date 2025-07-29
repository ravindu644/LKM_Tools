#!/bin/bash

# ==============================================================================
#
#                    Vendor DLKM Modules Preparation Script
#
#   This script prepares vendor_dlkm modules with intelligent dependency
#   resolution and load order optimization for Android GKI kernels.
#
#   Enhanced workflow for NetHunter:
#   1. Copy modules from master list (modules_list.txt)
#   2. Optionally add suspected NetHunter modules
#   3. Iteratively resolve all dependencies from staging directory
#   4. Prune vendor_boot modules from final set
#   5. Generate updated modules.dep with depmod
#   6. Intelligently update modules.load with proper ordering
#   7. Create complete vendor_dlkm module set
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

# Function to check if a file exists in staging using find
find_module_in_staging() {
    local module_name="$1"
    local staging_dir="$2"
    find "$staging_dir" -name "$module_name" -type f -print -quit 2>/dev/null
}

# --- Main Script ---

print_header "Vendor DLKM Modules Preparation Script"

echo "This script prepares a complete vendor_dlkm module set with intelligent"
echo "dependency resolution and load order optimization for NetHunter builds."
echo ""

# --- Input Collection ---

# Get modules list file
read -e -p "Enter path to modules_list.txt (from previous script): " MODULES_LIST_RAW
MODULES_LIST=$(sanitize_path "$MODULES_LIST_RAW")
if [ ! -f "$MODULES_LIST" ]; then
    log_error "modules_list.txt not found at: '$MODULES_LIST'"
    exit 1
fi

# Get staging directory
read -e -p "Enter path to kernel build staging directory: " STAGING_DIR_RAW
STAGING_DIR=$(sanitize_path "$STAGING_DIR_RAW")
if [ ! -d "$STAGING_DIR" ]; then
    log_error "Staging directory not found: '$STAGING_DIR'"
    exit 1
fi

# Get NetHunter modules directory (optional)
read -e -p "Enter path to NetHunter modules directory (press Enter to skip): " NH_MODULE_DIR_RAW
NH_MODULE_DIR=""
if [ -n "$NH_MODULE_DIR_RAW" ]; then
    NH_MODULE_DIR=$(sanitize_path "$NH_MODULE_DIR_RAW")
    if [ ! -d "$NH_MODULE_DIR" ]; then
        log_warning "NetHunter module directory not found: '$NH_MODULE_DIR', skipping..."
        NH_MODULE_DIR=""
    else
        log_info "NetHunter modules directory: $NH_MODULE_DIR"
    fi
fi

# Get OEM modules.load file
read -e -p "Enter path to OEM vendor_dlkm.modules.load file: " OEM_LOAD_FILE_RAW
OEM_LOAD_FILE=$(sanitize_path "$OEM_LOAD_FILE_RAW")
if [ ! -f "$OEM_LOAD_FILE" ]; then
    log_error "OEM modules.load file not found: '$OEM_LOAD_FILE'"
    exit 1
fi

# Get vendor_boot modules list for pruning
read -e -p "Enter path to vendor_boot modules_list.txt (for pruning): " VENDOR_BOOT_LIST_RAW
VENDOR_BOOT_LIST=$(sanitize_path "$VENDOR_BOOT_LIST_RAW")
if [ ! -f "$VENDOR_BOOT_LIST" ]; then
    log_error "Vendor boot modules list not found: '$VENDOR_BOOT_LIST'"
    exit 1
fi

# Get System.map file
read -e -p "Enter path to System.map file: " SYSTEM_MAP_RAW
SYSTEM_MAP=$(sanitize_path "$SYSTEM_MAP_RAW")
if [ ! -f "$SYSTEM_MAP" ]; then
    log_error "System.map file not found: '$SYSTEM_MAP'"
    exit 1
fi

# Get output directory
read -e -p "Enter output directory for vendor_dlkm modules: " OUTPUT_DIR_RAW
OUTPUT_DIR=$(sanitize_path "$OUTPUT_DIR_RAW")
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(pwd)/vendor_dlkm_modules"
fi

print_header "Setup and Validation"

# Create clean output directory
log_info "Creating clean output directory: $OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Create temporary work directory
WORK_DIR=$(mktemp -d)
trap 'log_info "Cleaning up temporary directory..."; rm -rf "$WORK_DIR"' EXIT

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

# --- Initial Module Copy ---

print_header "Copying Initial Module Set"

INITIAL_COUNT=0
MISSING_MODULES=()

log_info "Processing modules from OEM list..."

while IFS= read -r module_name || [ -n "$module_name" ]; do
    # Skip empty lines
    [ -z "$module_name" ] && continue
    
    # Remove any trailing whitespace/newlines
    module_name=$(echo "$module_name" | tr -d '\r\n' | xargs)
    [ -z "$module_name" ] && continue
    
    log_info "Looking for: $module_name"
    
    # Find the module in staging directory
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

log_info "Copied $INITIAL_COUNT modules from OEM list"

# --- Add NetHunter Modules (if specified) ---

if [ -n "$NH_MODULE_DIR" ]; then
    print_header "Adding NetHunter Modules"
    
    NH_COUNT=0
    NH_MODULES=($(find "$NH_MODULE_DIR" -name "*.ko" -printf "%f\n" 2>/dev/null || true))
    
    if [ ${#NH_MODULES[@]} -gt 0 ]; then
        log_info "Found ${#NH_MODULES[@]} suspected NetHunter modules"
        
        for nh_module in "${NH_MODULES[@]}"; do
            log_info "Looking for NetHunter module: $nh_module"
            
            # Check if module already exists in our set
            if [ -f "$MODULE_WORK_DIR/$nh_module" ]; then
                log_info "  ↳ Already present, skipping"
                continue
            fi
            
            # Find the module in staging directory
            nh_path=$(find_module_in_staging "$nh_module" "$STAGING_DIR")
            
            if [ -n "$nh_path" ] && [ -f "$nh_path" ]; then
                cp "$nh_path" "$MODULE_WORK_DIR/"
                if [ $? -eq 0 ]; then
                    ((NH_COUNT++))
                    log_info "  ✓ Added NetHunter module: $nh_module"
                else
                    log_warning "  ✗ Failed to copy NetHunter module: $nh_module"
                fi
            else
                log_warning "  ✗ NetHunter module not found in staging: $nh_module"
            fi
        done
        
        log_info "Added $NH_COUNT NetHunter modules"
    else
        log_warning "No NetHunter modules found in specified directory"
    fi
fi

if [ ${#MISSING_MODULES[@]} -gt 0 ]; then
    log_warning "Missing ${#MISSING_MODULES[@]} modules from staging directory"
    echo "Missing modules: ${MISSING_MODULES[*]}"
fi

# --- Iterative Dependency Resolution ---

print_header "Resolving Dependencies"

log_info "Starting iterative dependency resolution..."

# Track processed modules to avoid infinite loops
PROCESSED_MODULES_FILE="$WORK_DIR/processed_modules.list"
touch "$PROCESSED_MODULES_FILE"

# Create processing queue with current modules
PROCESSING_QUEUE_FILE="$WORK_DIR/processing_queue.list"
find "$MODULE_WORK_DIR" -name "*.ko" -printf "%f\n" > "$PROCESSING_QUEUE_FILE"

ITERATION=0
while [ -s "$PROCESSING_QUEUE_FILE" ]; do
    ((ITERATION++))
    log_info "Dependency resolution iteration $ITERATION"
    
    # Create new queue for next iteration
    NEW_QUEUE_FILE="$WORK_DIR/new_queue_$ITERATION.list"
    touch "$NEW_QUEUE_FILE"
    
    NEW_DEPS_FOUND=0
    
    while IFS= read -r module_name || [ -n "$module_name" ]; do
        [ -z "$module_name" ] && continue
        
        # Skip if already processed
        if grep -Fxq "$module_name" "$PROCESSED_MODULES_FILE" 2>/dev/null; then
            continue
        fi
        
        module_path="$MODULE_WORK_DIR/$module_name"
        if [ ! -f "$module_path" ]; then
            log_warning "Module file not found during processing: $module_name"
            continue
        fi
        
        log_info "Processing dependencies for: $module_name"
        
        # Get dependencies for this module
        deps=$(modinfo -F depends "$module_path" 2>/dev/null | tr ',' '\n' | grep -v '^$' || true)
        
        if [ -n "$deps" ]; then
            log_info "  Dependencies found: $(echo "$deps" | tr '\n' ' ')"
            
            while IFS= read -r dep_name || [ -n "$dep_name" ]; do
                [ -z "$dep_name" ] && continue
                
                dep_ko_name="${dep_name}.ko"
                
                # Check if dependency is already present
                if [ -f "$MODULE_WORK_DIR/$dep_ko_name" ]; then
                    continue
                fi
                
                # Find dependency in staging
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
        
        # Mark as processed
        echo "$module_name" >> "$PROCESSED_MODULES_FILE"
        
    done < "$PROCESSING_QUEUE_FILE"
    
    log_info "Iteration $ITERATION complete - Added $NEW_DEPS_FOUND new dependencies"
    
    # Setup for next iteration
    mv "$NEW_QUEUE_FILE" "$PROCESSING_QUEUE_FILE"
    
    # Safety check to prevent infinite loops
    if [ $ITERATION -gt 10 ]; then
        log_warning "Maximum iterations reached, stopping dependency resolution"
        break
    fi
    
    # If no new dependencies found, we're done
    if [ $NEW_DEPS_FOUND -eq 0 ]; then
        log_info "No new dependencies found, resolution complete"
        break
    fi
done

BEFORE_PRUNE_COUNT=$(find "$MODULE_WORK_DIR" -name "*.ko" | wc -l)
log_info "Before pruning - Module count: $BEFORE_PRUNE_COUNT"

# --- Prune Vendor Boot Modules ---

print_header "Pruning Vendor Boot Modules"

log_info "Removing modules that should be in vendor_boot instead of vendor_dlkm..."

PRUNED_COUNT=0
while IFS= read -r vb_module || [ -n "$vb_module" ]; do
    # Skip empty lines
    [ -z "$vb_module" ] && continue
    
    # Remove any trailing whitespace/newlines
    vb_module=$(echo "$vb_module" | tr -d '\r\n' | xargs)
    [ -z "$vb_module" ] && continue
    
    if [ -f "$MODULE_WORK_DIR/$vb_module" ]; then
        log_info "Pruning vendor_boot module: $vb_module"
        rm -f "$MODULE_WORK_DIR/$vb_module"
        ((PRUNED_COUNT++))
    fi
done < "$VENDOR_BOOT_LIST"

AFTER_PRUNE_COUNT=$(find "$MODULE_WORK_DIR" -name "*.ko" | wc -l)
log_info "Pruned $PRUNED_COUNT vendor_boot modules"
log_info "After pruning - Final module count: $AFTER_PRUNE_COUNT"

# --- Copy Required Build Files ---

print_header "Preparing Build Environment"

# Find and copy necessary files for depmod from staging
STAGING_MODULES_DIR=$(find "$STAGING_DIR" -type d -name "modules" -path "*/lib/modules/*" | head -1)
if [ -n "$STAGING_MODULES_DIR" ]; then
    STAGING_KERNEL_DIR=$(dirname "$STAGING_MODULES_DIR")
    
    for file in modules.builtin modules.builtin.modinfo; do
        if [ -f "$STAGING_KERNEL_DIR/$file" ]; then
            log_info "Copying $file from staging"
            cp "$STAGING_KERNEL_DIR/$file" "$MODULE_WORK_DIR/"
        fi
    done
fi

# --- Generate New modules.dep ---

print_header "Generating Module Dependencies"

log_info "Running depmod to generate new modules.dep..."
cd "$WORK_DIR"

# Run depmod
depmod -b . -F "$SYSTEM_MAP" "$KERNEL_VERSION"
DEPMOD_EXIT_CODE=$?

if [ $DEPMOD_EXIT_CODE -ne 0 ]; then
    log_error "depmod failed with exit code $DEPMOD_EXIT_CODE"
    exit 1
fi

log_info "Module dependencies generated successfully"

# --- Intelligent modules.load Generation ---

print_header "Generating Optimized modules.load"

cd "$MODULE_WORK_DIR"

# Create list of our current modules
find . -maxdepth 1 -name "*.ko" -printf "%f\n" > our_modules.list

# Clean up OEM modules.load (remove carriage returns)
sed 's/\r$//' "$OEM_LOAD_FILE" > oem_modules.list

# Create base load order from intersection of OEM and our modules
grep -Fx -f our_modules.list oem_modules.list > modules.load.base 2>/dev/null || touch modules.load.base

# Find new modules that need to be inserted
grep -Fxv -f oem_modules.list our_modules.list > new_modules.list 2>/dev/null || touch new_modules.list

# Start with base load order
cp modules.load.base modules.load.final

NEW_MODULE_COUNT=$(wc -l < new_modules.list)
if [ "$NEW_MODULE_COUNT" -gt 0 ]; then
    log_info "Found $NEW_MODULE_COUNT new modules to insert intelligently"
    
    # Create insertion points file
    > insertions.tsv
    
    while IFS= read -r new_module || [ -n "$new_module" ]; do
        [ -z "$new_module" ] && continue
        
        # Find modules that depend on this new module
        dependents=$(grep -w -- "$new_module" modules.dep 2>/dev/null | cut -d: -f1 | sed 's/^\.\///' || true)
        
        insertion_line=99999  # Default to append at end
        
        if [ -n "$dependents" ]; then
            # Find the earliest dependent in our current load order
            first_dependent_line=$(echo "$dependents" | xargs -I {} grep -n "^{}$" modules.load.final 2>/dev/null | head -1 | cut -d: -f1 || true)
            if [ -n "$first_dependent_line" ]; then
                insertion_line=$first_dependent_line
                log_info "  $new_module will be inserted at line $insertion_line (before dependents)"
            fi
        fi
        
        echo -e "$insertion_line\t$new_module" >> insertions.tsv
    done < new_modules.list
    
    # Insert modules in reverse order to maintain line numbers
    while IFS=$'\t' read -r line_num module_to_insert || [ -n "$line_num" ]; do
        [ -z "$line_num" ] && continue
        
        if [ "$line_num" -eq 99999 ]; then
            log_info "  Appending $module_to_insert (no dependents found)"
            echo "$module_to_insert" >> modules.load.final
        else
            log_info "  Inserting $module_to_insert at line $line_num"
            sed -i "${line_num}i$module_to_insert" modules.load.final
        fi
    done < <(sort -r -n insertions.tsv)
else
    log_info "No new modules to insert - using OEM subset"
fi

# Use the final optimized load order
mv modules.load.final modules.load

# Clean up temporary files
rm -f our_modules.list oem_modules.list modules.load.base new_modules.list insertions.tsv

# --- Copy Final Results ---

print_header "Finalizing Output"

log_info "Copying final module set to: $OUTPUT_DIR"

# Copy all modules and metadata files
cp *.ko "$OUTPUT_DIR/" 2>/dev/null || true
cp modules.* "$OUTPUT_DIR/" 2>/dev/null || true

# Create summary
FINAL_COUNT=$(ls -1 "$OUTPUT_DIR"/*.ko 2>/dev/null | wc -l)
LOAD_COUNT=$(wc -l < "$OUTPUT_DIR/modules.load" 2>/dev/null || echo "0")

print_header "Process Complete!"

echo "Vendor DLKM module preparation successful!"
echo ""
echo "Results:"
echo "  - Total modules: $FINAL_COUNT"
echo "  - Load order entries: $LOAD_COUNT"
echo "  - NetHunter modules added: ${NH_COUNT:-0}"
echo "  - Vendor boot modules pruned: $PRUNED_COUNT"
echo "  - Output directory: $OUTPUT_DIR"
echo ""
echo "Files created:"
ls -la "$OUTPUT_DIR" 2>/dev/null || echo "No files found in output directory"
echo ""
echo "Your vendor_dlkm module set is ready for packaging!"

