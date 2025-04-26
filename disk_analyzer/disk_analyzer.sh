#!/usr/bin/env bash

# disk_analyzer.sh - Comprehensive disk usage analyzer with advanced filtering and reporting
# Version: 1.0.0
# License: MIT

set -o errexit
set -o nounset
set -o pipefail

# Initialize global variables
declare -a WHITELIST_PATTERNS=()
declare -a BLACKLIST_PATTERNS=()
declare -a WHITELIST_PATHS=()
declare -a TRAVERSAL_ERRORS=()
declare -A SIZE_CACHE=()
declare -A VISITED_INODES=()

# Default configuration
LEVEL=1
MIN_SIZE_BYTES=$((1024 * 1024)) # 1M
ALL=false
SORT_KEY="size"
REVERSE=false
CUT_SIZE_BYTES=0
TREE=false
ONE_FILE_SYSTEM=false
DEREFERENCE=false
TARGET_DIR="."

# Exit codes
EXIT_SUCCESS=0
EXIT_ARG_ERROR=1
EXIT_TARGET_ERROR=2
EXIT_IO_ERROR=3

# Helper functions

log_error() {
    echo "Error: $*" >&2
}

log_warning() {
    echo "Warning: $*" >&2
}

debug_log() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo "DEBUG: $*" >&2
    fi
}

# Convert human-readable sizes to bytes (e.g., 1K -> 1024)
parse_size() {
    local size_str="$1"
    local size_num
    local unit
    local multiplier=1

    # Extract numeric part and unit
    if [[ "$size_str" =~ ^([0-9]+)([KkMmGgTtPp]?)$ ]]; then
        size_num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2],,}" # lowercase
    else
        log_error "Invalid size format: '$size_str'. Expected format like '10M', '1G', etc."
        exit $EXIT_ARG_ERROR
    fi

    case "$unit" in
        k) multiplier=$((1024)) ;;
        m) multiplier=$((1024 * 1024)) ;;
        g) multiplier=$((1024 * 1024 * 1024)) ;;
        t) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
        p) multiplier=$((1024 * 1024 * 1024 * 1024 * 1024)) ;;
        *) multiplier=1 ;; # no unit or unknown unit (treated as bytes)
    esac

    echo $((size_num * multiplier))
}

# Check if a path matches any pattern in the given array
matches_patterns() {
    local path="$1"
    shift
    local patterns=("$@")
    local pattern

    for pattern in "${patterns[@]}"; do
        if [[ -z "$pattern" ]]; then
            continue
        fi

        # Handle regex patterns (prefixed with 'regex:')
        if [[ "$pattern" =~ ^regex: ]]; then
            local regex_pattern="${pattern#regex:}"
            if echo "$path" | grep -qE "$regex_pattern"; then
                debug_log "Path '$path' matches regex pattern '$regex_pattern'"
                return 0
            fi
        else
            # Handle glob patterns
            # Convert pattern to absolute path if it starts with / and target_dir is set
            if [[ "$pattern" == /* ]]; then
                # Absolute path pattern
                if [[ "$path" == "$pattern" || "$path" == "$pattern"/* ]]; then
                    debug_log "Path '$path' matches absolute pattern '$pattern'"
                    return 0
                fi
            else
                # Relative or simple pattern
                local base_pattern="*/$pattern"
                if [[ "$path" == *"/$pattern" || "$path" == *"/$pattern"/* ]]; then
                    debug_log "Path '$path' matches relative pattern '$pattern'"
                    return 0
                fi
            fi
        fi
    done

    return 1
}

# Check if path should be included based on whitelist/blacklist rules
should_include_path() {
    local path="$1"
    
    # Whitelist takes precedence
    if (( ${#WHITELIST_PATTERNS[@]} > 0 || ${#WHITELIST_PATHS[@]} > 0 )); then
        # Check against whitelist paths first (exact matches)
        for wpath in "${WHITELIST_PATHS[@]}"; do
            if [[ "$path" == "$wpath" || "$path" == "$wpath"/* ]]; then
                debug_log "Path '$path' is whitelisted by exact path '$wpath'"
                return 0
            fi
        done
        
        # Check against whitelist patterns
        if matches_patterns "$path" "${WHITELIST_PATTERNS[@]}"; then
            debug_log "Path '$path' matches whitelist pattern"
            return 0
        fi
        
        # Not in whitelist
        return 1
    fi
    
    # If no whitelist, check blacklist
    if (( ${#BLACKLIST_PATTERNS[@]} > 0 )); then
        if matches_patterns "$path" "${BLACKLIST_PATTERNS[@]}"; then
            debug_log "Path '$path' matches blacklist pattern - excluding"
            return 1
        fi
    fi
    
    # Not excluded by blacklist
    return 0
}

# Load patterns from file
load_pattern_file() {
    local file_path="$1"
    local pattern_array_name="$2"
    
    if [[ ! -f "$file_path" ]]; then
        debug_log "Pattern file not found: $file_path"
        return
    fi
    
    debug_log "Loading patterns from $file_path"
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        line="${line%%#*}" # Remove comments
        line="${line%"${line##*[![:space:]]}"}" # Trim trailing whitespace
        if [[ -z "$line" ]]; then
            continue
        fi
        
        # Add to the appropriate array
        eval "$pattern_array_name+=(\"$line\")"
    done < "$file_path"
}

# Find all files/directories up to specified level, respecting whitelist paths
find_paths() {
    local target_dir="$1"
    local find_args=()
    local find_cmd
    local path
    
    # Build find command arguments
    if (( LEVEL == 0 )); then
        # Only the target directory itself
        echo "$target_dir"
        return
    fi
    
    find_args+=("$target_dir")
    
    # Handle depth
    find_args+=(-maxdepth "$LEVEL")
    
    # Handle symlinks
    if [[ "$DEREFERENCE" == true ]]; then
        find_args+=(-L)
    fi
    
    # Handle one-file-system
    if [[ "$ONE_FILE_SYSTEM" == true ]]; then
        find_args+=(-xdev)
    fi
    
    # Basic find command to get all paths up to level
    find_args+=(-print0)
    
    debug_log "Running find with args: ${find_args[*]}"
    
    # Process found paths
    while IFS= read -r -d $'\0' path; do
        echo "$path"
    done < <(find "${find_args[@]}" 2>/dev/null || true)
    
    # Add whitelist paths that might be deeper than LEVEL
    for path in "${WHITELIST_PATHS[@]}"; do
        if [[ "$path" == "$target_dir" || "$path" == "$target_dir"/* ]]; then
            echo "$path"
            
            # Also include parent directories up to LEVEL
            local parent="$path"
            while [[ "$parent" != "$target_dir" && "$parent" != "/" ]]; do
                parent=$(dirname "$parent")
                if [[ "$parent" == "$target_dir" ]]; then
                    break
                fi
                echo "$parent"
            done
        fi
    done | sort -u # Remove duplicates
}

# Get size of a file/directory using du
get_size() {
    local path="$1"
    local size
    local du_args=(-s -b)  # Add -s for summary
    
    # Check cache first
    if [[ -n "${SIZE_CACHE[$path]:-}" ]]; then
        echo "${SIZE_CACHE[$path]}"
        return
    fi
    
    # Handle symlinks
    if [[ "$DEREFERENCE" == true ]]; then
        du_args+=(-L)
    fi
    
    # Handle one-file-system
    if [[ "$ONE_FILE_SYSTEM" == true ]]; then
        du_args+=(-x)
    fi
    
    # Skip if path doesn't exist (might have been deleted since traversal)
    if [[ ! -e "$path" ]]; then
        TRAVERSAL_ERRORS+=("Path does not exist: $path")
        echo "0"
        return
    fi
    
    # Get size with du
    size=$(du "${du_args[@]}" "$path" 2>/dev/null | awk '{print $1}' || echo "0")
    
    # Cache the result
    SIZE_CACHE["$path"]=$size
    
    echo "$size"
}

# Format size in human-readable format
format_size() {
    local bytes="$1"
    echo "$bytes" | awk '
    function format(bytes) {
        units[0]="B"; units[1]="K"; units[2]="M"; units[3]="G"; units[4]="T"; units[5]="P"
        n = 0
        while (bytes >= 1024 && n < 5) {
            bytes = bytes / 1024
            n++
        }
        if (bytes < 10 && n > 0)
            return sprintf("%.1f%s", bytes, units[n])
        return sprintf("%d%s", bytes, units[n])
    }
    { print format($1) }'
}

# Process and print results
process_results() {
    local target_dir="$1"
    shift
    local paths=("$@")
    local path
    local size
    declare -A path_sizes=()
    declare -A path_depths=()
    declare -a results=()
    
    # First pass: collect sizes and filter
    for path in "${paths[@]}"; do
        # Skip if path shouldn't be included
        if ! should_include_path "$path"; then
            debug_log "Skipping path (doesn't match inclusion rules): $path"
            continue
        fi
        
        # Get size
        size=$(get_size "$path")
        
        # Ensure size is a valid integer
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            debug_log "Invalid size for path $path: $size (setting to 0)"
            size=0
        fi
        
        # Apply min-size filter (unless --all is set or path is whitelisted)
        if [[ "$ALL" == false ]] && ! matches_patterns "$path" "${WHITELIST_PATTERNS[@]}" && \
           ! [[ " ${WHITELIST_PATHS[@]} " =~ " $path " ]] && (( size < MIN_SIZE_BYTES )); then
            debug_log "Skipping path (size $size < min-size $MIN_SIZE_BYTES): $path"
            continue
        fi
        
        # Store path info
        path_sizes["$path"]=$size
        path_depths["$path"]=$(echo "$path" | tr -cd '/' | wc -c)
    done
    
    # Calculate proper relative depth for tree view
    local base_depth=0
    if [[ "$TREE" == true ]]; then
        base_depth=$(echo "$target_dir" | tr -cd '/' | wc -c)
    fi
    
    # Second pass: build results array
    for path in "${!path_sizes[@]}"; do
        size=${path_sizes["$path"]}
        
        # Store both numeric and formatted sizes
        local formatted_size
        formatted_size=$(format_size "$size")
        
        # For tree view, we'll need the depth later
        local depth=${path_depths["$path"]}
        local rel_depth=$((depth - base_depth))
        
        # Store parent path for tree grouping
        local parent_path=""
        if [[ "$TREE" == true ]]; then
            if [[ "$path" == "$target_dir" ]]; then
                parent_path="__ROOT__"
            else
                parent_path=$(dirname "$path")
            fi
        fi
        
        if [[ "$TREE" == true ]]; then
            # For tree view, store with depth info and parent path
            # Use a delimiter that's unlikely to appear in paths
            results+=("$rel_depth|$size|$formatted_size|$path|$parent_path")
        else
            # For flat view, just store the line
            results+=("$size|$formatted_size|$path")
        fi
    done
    
    # Sort results based on tree hierarchy if tree view is enabled
    if [[ "$TREE" == true ]]; then
        tree_sort_results results
    else
        # Regular sorting for flat view
        sort_results results
    fi
    
    # Apply cut filter (except for whitelisted paths)
    local final_results=()
    for line in "${results[@]}"; do
        # Split the line carefully to avoid issues with paths containing colons
        local path
        if [[ "$TREE" == true ]]; then
            # Tree format: depth|size|formatted_size|path|parent_path
            path=$(echo "$line" | cut -d'|' -f4)
        else
            # Flat format: size|formatted_size|path
            path=$(echo "$line" | cut -d'|' -f3)
        fi
        
        # Check if path is whitelisted (exempt from cut filter)
        local is_whitelisted=false
        if matches_patterns "$path" "${WHITELIST_PATTERNS[@]}" || \
           [[ " ${WHITELIST_PATHS[@]} " =~ " $path " ]]; then
            is_whitelisted=true
        fi
        
        # Skip if below cut size and not whitelisted
        if (( CUT_SIZE_BYTES > 0 )) && [[ "$is_whitelisted" == false ]]; then
            if [[ -n "${path_sizes[$path]}" ]]; then
                local path_size="${path_sizes[$path]}"
                if (( path_size < CUT_SIZE_BYTES )); then
                    continue
                fi
            fi
        fi
        
        final_results+=("$line")
    done
    
    # Print results
    print_results final_results "$target_dir"
}

# Tree-aware sorting for hierarchical directory structure
tree_sort_results() {
    local -n arr=$1
    
    # If we have no results, return early
    if (( ${#arr[@]} == 0 )); then
        return
    fi
    
    # Group by parent directory
    declare -A dir_children
    for line in "${arr[@]}"; do
        # Format: depth|size|formatted_size|path|parent_path
        local parent=$(echo "$line" | cut -d'|' -f5)
        dir_children["$parent"]+="$line"$'\n'
    done
    
    # Sort within each directory
    for parent in "${!dir_children[@]}"; do
        local children
        children="${dir_children[$parent]}"
        
        # Create temp file for sorting
        local temp_file
        temp_file=$(mktemp)
        
        # Extract size for sorting and write to temp file
        echo -n "$children" | while IFS= read -r line; do
            if [[ -z "$line" ]]; then
                continue
            fi
            
            # Extract size field (second field)
            local size=$(echo "$line" | cut -d'|' -f2)
            
            # Write to file with size as sortable field
            printf '%d %s\n' "$size" "$line" >> "$temp_file"
        done
        
        # Sort children by size
        local sorted_children
        if [[ "$REVERSE" == true ]]; then
            sorted_children=$(sort -n -k1,1 "$temp_file" | cut -d' ' -f2-)
        else
            sorted_children=$(sort -n -k1,1r "$temp_file" | cut -d' ' -f2-)
        fi
        
        # Update the children for this parent
        dir_children["$parent"]="$sorted_children"
        
        # Clean up
        rm -f "$temp_file"
    done
    
    # Now build the results in hierarchical order
    arr=()
    
    # Start with root
    local root_children="${dir_children["__ROOT__"]:-}"
    if [[ -n "$root_children" ]]; then
        while IFS= read -r line; do
            if [[ -z "$line" ]]; then
                continue
            fi
            arr+=("$line")
            
            # Get this item's path to find its children
            local path=$(echo "$line" | cut -d'|' -f4)
            
            # Recursively add children - use names instead of references
            add_children_recursive "$path" "arr" "dir_children"
        done <<< "$root_children"
    fi
}

# Recursively add children to the results array
add_children_recursive() {
    local parent="$1"
    local result_arr_name="$2"
    local dir_map_name="$3"
    debug_log "add_children_recursive: parent='$parent' map='$dir_map_name'"

    # bind map_ref to the associative array named in $dir_map_name
    local -n map_ref="$dir_map_name"
    # now do a real lookup
    local children="${map_ref[$parent]:-}"

    if [[ -z "$children" ]]; then
        return
    fi
    
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi
        
        # Add to result array using nameref-safe approach
        eval "$result_arr_name+=(\"${line//\"/\\\"}\")"
        
        # Get this item's path to find its children
        local path
        path=$(echo "$line" | cut -d'|' -f4)
        
        # Recursively add its children
        add_children_recursive "$path" "$result_arr_name" "$dir_map_name"
    done <<< "$children"
}

# Sort results based on current sort key and direction
sort_results() {
    local -n arr=$1
    local temp_file
    temp_file=$(mktemp)

    # Store the numeric size values in a temporary array
    declare -a size_values=()
    for line in "${arr[@]}"; do
        if [[ "$TREE" == true ]]; then
            local size="${line#*:}"
            size="${size%%:*}"
        else
            local size="${line%%:*}"
        fi
        size_values+=("$size")
    done
    
    # Write numeric values and original lines to temp file
    for ((i=0; i<${#arr[@]}; i++)); do
        printf '%d %s\n' "${size_values[i]}" "${arr[i]}" >> "$temp_file"
    done
    
    # Clear original array
    arr=()
    
    if [[ "$SORT_KEY" == "size" ]]; then
        # Sort by first field (numeric size)
        if [[ "$REVERSE" == true ]]; then
            mapfile -t arr < <(sort -n -k1,1 "$temp_file" | cut -d' ' -f2-)
        else
            mapfile -t arr < <(sort -n -k1,1r "$temp_file" | cut -d' ' -f2-)
        fi
    else
        # Sort by path
        if [[ "$REVERSE" == true ]]; then
            mapfile -t arr < <(sort -k$([[ "$TREE" == true ]] && echo 4 || echo 3),\$r "$temp_file" | cut -d' ' -f2-)
        else
            mapfile -t arr < <(sort -k$([[ "$TREE" == true ]] && echo 4 || echo 3),\$ "$temp_file" | cut -d' ' -f2-)
        fi
    fi
    
    rm -f "$temp_file"
}

# Print results in the appropriate format
print_results() {
    local -n arr=$1
    local target_dir="$2"
    local prev_depth=0
    local curr_depth=0
    declare -A dir_marker=()
    
    for line in "${arr[@]}"; do
        if [[ "$TREE" == true ]]; then
            # Tree format: depth|size|formatted_size|path|parent_path
            local depth=$(echo "$line" | cut -d'|' -f1)
            local size=$(echo "$line" | cut -d'|' -f2)
            local formatted_size=$(echo "$line" | cut -d'|' -f3)
            local path=$(echo "$line" | cut -d'|' -f4)
            
            # Get just the basename for display in tree
            local basename=$(basename "$path")
            curr_depth=$depth
            
            # Calculate indentation (2 spaces per level)
            local indent=""
            local prefix=""
            
            # Build tree visualization
            for ((i=0; i<depth; i++)); do
                # Last level uses the branch character, others use vertical line if needed
                if [[ $i -eq $((depth-1)) ]]; then
                    indent+="└─"
                else
                    # Check if we need a vertical line at this level
                    if [[ -n "${dir_marker[$i]}" ]]; then
                        indent+="│ "
                    else
                        indent+="  "
                    fi
                fi
            done
            
            # Update directory markers for future tree lines
            dir_marker[$depth]=1
            
            # Clear markers for deeper levels to prevent extra vertical lines
            for ((i=depth+1; i<=prev_depth; i++)); do
                unset dir_marker[$i]
            done
            
            # Print with indentation using formatted size
            printf "%s%7s\t%s\n" "$indent" "$formatted_size" "$basename"
            
            prev_depth=$depth
            
        else
            # Flat format: size|formatted_size|path
            local size=$(echo "$line" | cut -d'|' -f1)
            local formatted_size=$(echo "$line" | cut -d'|' -f2)
            local path=$(echo "$line" | cut -d'|' -f3)
            printf "%7s\t%s\n" "$formatted_size" "$path"
        fi
    done
}

# Validate whitelist paths against target directory
validate_whitelist_paths() {
    local target_dir="$1"
    shift
    local paths=("$@")
    local path
    local validated_paths=()
    
    for path in "${paths[@]}"; do
        # Make sure path is absolute
        if [[ "$path" != /* ]]; then
            path="${target_dir%/}/${path}"
        fi
        
        # Check if path is within target directory
        if [[ "$path" == "$target_dir" || "$path" == "$target_dir"/* ]]; then
            # Add to validated paths (remove trailing slashes)
            validated_paths+=("${path%/}")
        else
            log_warning "Whitelist path '$path' is outside the target directory '$target_dir'; ignoring whitelist entry."
        fi
    done
    
    WHITELIST_PATHS=("${validated_paths[@]}")
}

# Main argument parsing
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--level)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    log_error "Option $1 requires an argument"
                    exit $EXIT_ARG_ERROR
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "Level must be a non-negative integer"
                    exit $EXIT_ARG_ERROR
                fi
                LEVEL="$2"
                shift 2
                ;;
            -m|--min-size)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    log_error "Option $1 requires an argument"
                    exit $EXIT_ARG_ERROR
                fi
                MIN_SIZE_BYTES=$(parse_size "$2")
                shift 2
                ;;
            -a|--all)
                ALL=true
                shift
                ;;
            -s|--sort)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    log_error "Option $1 requires an argument"
                    exit $EXIT_ARG_ERROR
                fi
                if [[ "$2" != "size" && "$2" != "name" ]]; then
                    log_error "Sort key must be either 'size' or 'name'"
                    exit $EXIT_ARG_ERROR
                fi
                SORT_KEY="$2"
                shift 2
                ;;
            -r|--reverse)
                REVERSE=true
                shift
                ;;
            -c|--cut)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    log_error "Option $1 requires an argument"
                    exit $EXIT_ARG_ERROR
                fi
                CUT_SIZE_BYTES=$(parse_size "$2")
                shift 2
                ;;
            -w|--whitelist)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    log_error "Option $1 requires an argument"
                    exit $EXIT_ARG_ERROR
                fi
                IFS=',' read -ra patterns <<< "$2"
                WHITELIST_PATTERNS+=("${patterns[@]}")
                shift 2
                ;;
            --whitelist-file)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    log_error "Option $1 requires an argument"
                    exit $EXIT_ARG_ERROR
                fi
                load_pattern_file "$2" WHITELIST_PATTERNS
                shift 2
                ;;
            -b|--blacklist)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    log_error "Option $1 requires an argument"
                    exit $EXIT_ARG_ERROR
                fi
                IFS=',' read -ra patterns <<< "$2"
                BLACKLIST_PATTERNS+=("${patterns[@]}")
                shift 2
                ;;
            --blacklist-file)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    log_error "Option $1 requires an argument"
                    exit $EXIT_ARG_ERROR
                fi
                load_pattern_file "$2" BLACKLIST_PATTERNS
                shift 2
                ;;
            -t|--tree)
                TREE=true
                shift
                ;;
            -x|--one-file-system)
                ONE_FILE_SYSTEM=true
                shift
                ;;
            -L|--dereference)
                DEREFERENCE=true
                shift
                ;;
            -h|--help)
                print_help
                exit $EXIT_SUCCESS
                ;;
            --)
                shift
                break
                ;;
            -*)
                log_error "Unknown option: $1"
                print_help
                exit $EXIT_ARG_ERROR
                ;;
            *)
                # Assume this is the target directory
                if [[ -n "$TARGET_DIR" && "$TARGET_DIR" != "." ]]; then
                    log_error "Multiple target directories specified"
                    exit $EXIT_ARG_ERROR
                fi
                TARGET_DIR="$1"
                shift
                ;;
        esac
    done
    
    # Handle remaining arguments (should only be target directory)
    if [[ $# -gt 0 ]]; then
        if [[ -n "$TARGET_DIR" && "$TARGET_DIR" != "." ]]; then
            log_error "Multiple target directories specified"
            exit $EXIT_ARG_ERROR
        fi
        TARGET_DIR="$1"
        shift
    fi
    
    # Validate target directory
    TARGET_DIR=$(realpath -m "$TARGET_DIR")
    if [[ ! -e "$TARGET_DIR" ]]; then
        log_error "Target directory does not exist: $TARGET_DIR"
        exit $EXIT_TARGET_ERROR
    fi
    if [[ ! -d "$TARGET_DIR" ]]; then
        log_error "Target is not a directory: $TARGET_DIR"
        exit $EXIT_TARGET_ERROR
    fi
    if [[ ! -r "$TARGET_DIR" ]]; then
        log_error "No read permission for target directory: $TARGET_DIR"
        exit $EXIT_TARGET_ERROR
    fi
    
    # Load default pattern files if they exist
    local local_whitelist="${TARGET_DIR}/.disk_analyzer_include"
    local local_blacklist="${TARGET_DIR}/.disk_analyzer_ignore"
    local global_whitelist="${HOME}/.disk_analyzer_include"
    local global_blacklist="${HOME}/.disk_analyzer_ignore"
    
    # Load local patterns first, then global (local takes precedence)
    [[ -f "$local_whitelist" ]] && load_pattern_file "$local_whitelist" WHITELIST_PATTERNS
    [[ -f "$global_whitelist" ]] && load_pattern_file "$global_whitelist" WHITELIST_PATTERNS
    [[ -f "$local_blacklist" ]] && load_pattern_file "$local_blacklist" BLACKLIST_PATTERNS
    [[ -f "$local_whitelist" ]] && load_pattern_file "$local_whitelist" WHITELIST_PATTERNS
    [[ -f "$global_whitelist" ]] && load_pattern_file "$global_whitelist" WHITELIST_PATTERNS
    [[ -f "$local_blacklist" ]] && load_pattern_file "$local_blacklist" BLACKLIST_PATTERNS
    [[ -f "$global_blacklist" ]] && load_pattern_file "$global_blacklist" BLACKLIST_PATTERNS
    
    # Extract absolute paths from whitelist patterns to WHITELIST_PATHS (once)
    local -A seen_paths=()
    for pattern in "${WHITELIST_PATTERNS[@]}"; do
        if [[ "$pattern" == /* && "$pattern" != regex:* ]] && [[ -z "${seen_paths[$pattern]:-}" ]]; then
            WHITELIST_PATHS+=("$pattern")
            seen_paths[$pattern]=1
        fi
    done
    
    # Validate whitelist paths just once
    [[ ${#WHITELIST_PATHS[@]} -gt 0 ]] && validate_whitelist_paths "$TARGET_DIR" "${WHITELIST_PATHS[@]}"
}

# Print help message
print_help() {
    cat <<EOF
Usage: disk_analyzer.sh [OPTIONS] [TARGET_DIRECTORY]

Analyze disk usage with advanced filtering and reporting options.

Options:
  -l, --level <DEPTH>       Maximum recursion depth (0 = target directory only)
  -m, --min-size <SIZE>     Minimum size threshold (e.g., 1M, 500K)
  -a, --all                 Show all entries regardless of size
  -s, --sort <size|name>    Sort by size or name (default: size)
  -r, --reverse             Reverse sort order
  -c, --cut <SIZE>          Cutoff size for final output
  -w, --whitelist <PATTERNS> Comma-separated inclusion patterns
  --whitelist-file <FILE>   File containing whitelist patterns
  -b, --blacklist <PATTERNS> Comma-separated exclusion patterns
  --blacklist-file <FILE>   File containing blacklist patterns
  -t, --tree                Display results as a tree
  -x, --one-file-system     Don't cross filesystem boundaries
  -L, --dereference         Follow symbolic links
  -h, --help                Show this help message

Size units: K (KiB), M (MiB), G (GiB), T (TiB), P (PiB)

Default target directory is current directory (.)

EOF
}

# Main function
main() {
    parse_arguments "$@"
    
    debug_log "Starting analysis with configuration:"
    debug_log "  Target directory: $TARGET_DIR"
    debug_log "  Level: $LEVEL"
    debug_log "  Min size: $MIN_SIZE_BYTES bytes"
    debug_log "  All: $ALL"
    debug_log "  Sort key: $SORT_KEY"
    debug_log "  Reverse: $REVERSE"
    debug_log "  Cut size: $CUT_SIZE_BYTES bytes"
    debug_log "  Tree: $TREE"
    debug_log "  One filesystem: $ONE_FILE_SYSTEM"
    debug_log "  Dereference: $DEREFERENCE"
    debug_log "  Whitelist patterns: ${WHITELIST_PATTERNS[*]}"
    debug_log "  Whitelist paths: ${WHITELIST_PATHS[*]}"
    debug_log "  Blacklist patterns: ${BLACKLIST_PATTERNS[*]}"
    
    # Find all candidate paths
    local paths
    mapfile -t paths < <(find_paths "$TARGET_DIR")
    
    if (( ${#paths[@]} == 0 )); then
        log_error "No paths found for analysis"
        exit $EXIT_IO_ERROR
    fi
    
    debug_log "Found ${#paths[@]} candidate paths for analysis"
    
    # Process and display results
    process_results "$TARGET_DIR" "${paths[@]}"
    
    # Report any traversal errors
    if (( ${#TRAVERSAL_ERRORS[@]} > 0 )); then
        for err in "${TRAVERSAL_ERRORS[@]}"; do
            log_warning "$err"
        done
    fi
    
    exit $EXIT_SUCCESS
}

# Entry point
main "$@"