#!/usr/bin/env bash
#
# disk_analyzer.sh - A meticulously engineered filesystem analysis utility
#
# Provides systematic quantification and interrogation of file system utilization
# through depth-limited traversal, parametrized size thresholds, bi-directional
# sorting, and pattern-driven inclusion/exclusion schemas.
#

set -o nounset  # Exit on uninitialized variable
set -o errexit  # Exit on error
set -o pipefail # Exit on pipe failure

# ============================================================================
# Global Constants and Default Configuration
# ============================================================================

readonly VERSION="1.0.0"
readonly DEFAULT_LEVEL=1
readonly DEFAULT_MIN_SIZE="1M"
readonly DEFAULT_SORT="size"
readonly DEFAULT_CUT=""
readonly DEFAULT_REVERSE=false
readonly DEFAULT_ALL=false
readonly DEFAULT_TREE=false
readonly DEFAULT_ONE_FILE_SYSTEM=false
readonly DEFAULT_DEREFERENCE=false
readonly DEFAULT_EXCLUDE_HIDDEN=false

# ============================================================================
# Helper Functions
# ============================================================================

# Display usage information
show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] [TARGET_DIRECTORY]

A meticulously engineered Bash-based analytic framework for the systematic 
quantification and interrogation of file system utilization.

Options:
  -l, --level <DEPTH>          Maximum recursion depth (default: $DEFAULT_LEVEL)
  -m, --min-size <SIZE>        Lower bound for directory size (default: $DEFAULT_MIN_SIZE)
  -a, --all                    Show all directories regardless of size
  -s, --sort <size|name>       Sort criteria: 'size' or 'name' (default: $DEFAULT_SORT)
  -r, --reverse                Reverse sort order
  -c, --cut <SIZE>             Omit entries below this size in final output
  -w, --whitelist <PATTERNS>   Include only paths matching these patterns
      --whitelist-file <FILE>  File containing whitelist patterns
  -b, --blacklist <PATTERNS>   Exclude paths matching these patterns
      --blacklist-file <FILE>  File containing blacklist patterns
  -t, --tree                   Show results in a tree-like structure
  -x, --one-file-system        Stay on one file system (don't cross mount points)
  -L, --dereference            Follow symbolic links
  -D, --debug                  Enable debug logging
      --exclude-hidden         Exclude hidden directories
  -h, --help                   Display this help and exit

SIZE format: a number followed by K, M, G, T, or P (case-insensitive).
  Examples: 10K, 5M, 2G, 1T

PATTERNS: comma-separated glob patterns or regex patterns (prefix with 'regex:')
  Examples: "*.log,*/cache/*" or "regex:.*\\.tmp$,regex:/var/.*"

Default pattern files (if they exist):
  - .disk_analyzer_include (whitelist)
  - .disk_analyzer_ignore (blacklist)
  
Exit status:
  0  Normal termination
  1  Argument parsing failure
  2  Target directory inaccessible or nonexistent
  3  I/O error during traversal
EOF
}

# Debug logging function
debug_log() {
  if [[ "${DEBUG:-false}" == "true" ]]; then
    echo "DEBUG: $*" >&2
  fi
}

# Error and warning functions
error() {
  echo "ERROR: $*" >&2
  exit "${2:-1}"
}

warn() {
  echo "WARNING: $*" >&2
}

# Convert a size string (like "5M") to bytes
convert_to_bytes() {
  local size_str="$1"
  local number_part suffix multiplier
  
  # Extract number and suffix parts
  if [[ "$size_str" =~ ^([0-9]+)([KMGTP]?)$ ]]; then
    number_part="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    
    # Convert to bytes based on suffix
    case "${suffix^^}" in
      K) multiplier=1024 ;;
      M) multiplier=$((1024*1024)) ;;
      G) multiplier=$((1024*1024*1024)) ;;
      T) multiplier=$((1024*1024*1024*1024)) ;;
      P) multiplier=$((1024*1024*1024*1024*1024)) ;;
      *) multiplier=1 ;;
    esac
    
    echo "$((number_part * multiplier))"
  else
    error "Invalid size format: '$size_str'. Use a number followed by K, M, G, T, or P" 1
  fi
}

# Format size in human-readable form
format_size() {
  local size_bytes="$1"
  local size unit
  
  if ((size_bytes >= 1024*1024*1024*1024*1024)); then
    size=$((size_bytes / (1024*1024*1024*1024*1024)))
    unit="P"
  elif ((size_bytes >= 1024*1024*1024*1024)); then
    size=$((size_bytes / (1024*1024*1024*1024)))
    unit="T"
  elif ((size_bytes >= 1024*1024*1024)); then
    size=$((size_bytes / (1024*1024*1024)))
    unit="G"
  elif ((size_bytes >= 1024*1024)); then
    size=$((size_bytes / (1024*1024)))
    unit="M"
  elif ((size_bytes >= 1024)); then
    size=$((size_bytes / 1024))
    unit="K"
  else
    size=$size_bytes
    unit="B"
  fi
  
  echo "$size$unit"
}

# Check if a path is a subdirectory of another path
is_subpath() {
  local potential_subpath="$1"
  local parent_path="$2"
  
  # Normalize paths by ensuring they end with /
  potential_subpath="${potential_subpath%/}/"
  parent_path="${parent_path%/}/"
  
  # Check if the potential subpath starts with the parent path
  [[ "$potential_subpath" == "$parent_path"* ]]
}

# Check if a path matches any pattern in a list
matches_pattern() {
  local path="$1"
  local patterns="$2"  # Comma-separated list of patterns
  local pattern
  
  # Split patterns by comma and check each one
  IFS=',' read -ra pattern_array <<< "$patterns"
  for pattern in "${pattern_array[@]}"; do
    # Skip empty patterns
    [[ -z "$pattern" ]] && continue
    
    # Check if it's a regex pattern
    if [[ "$pattern" == regex:* ]]; then
      # Extract the regex part and match using grep
      local regex="${pattern#regex:}"
      if echo "$path" | grep -q -E "$regex"; then
        debug_log "Path '$path' matches regex pattern '$regex'"
        return 0
      fi
    else
      # Handle glob patterns based on type
      if [[ "$pattern" == /* ]]; then
        # Absolute path pattern
        if [[ "$path" == $pattern ]]; then
          debug_log "Path '$path' matches absolute pattern '$pattern'"
          return 0
        fi
      elif [[ "$pattern" == */* ]]; then
        # Relative path pattern
        local rel_path="${path#$TARGET_DIR/}"
        if [[ "$rel_path" == $pattern ]]; then
          debug_log "Path '$path' matches relative pattern '$pattern'"
          return 0
        fi
      else
        # Simple component pattern (match anywhere)
        if [[ "$path" == *"$pattern"* ]]; then
          debug_log "Path '$path' matches component pattern '$pattern'"
          return 0
        fi
      fi
    fi
  done
  
  return 1  # No match found
}

# Load patterns from a file into a variable
load_patterns_from_file() {
  local file="$1"
  local var_name="$2"
  local patterns=""
  
  debug_log "Loading patterns from file: $file"
  
  if [[ -f "$file" ]]; then
    # Read the file line by line
    while IFS= read -r line || [ -n "$line" ]; do
      # Skip comments and empty lines
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$line" ]] && continue
      
      # Add pattern to the list
      if [[ -z "$patterns" ]]; then
        patterns="$line"
      else
        patterns="$patterns,$line"
      fi
    done < "$file"
    
    # Set the variable using indirect reference
    eval "$var_name=\"\$patterns\""
    debug_log "Loaded patterns: ${!var_name}"
  fi
}

# Parse command line arguments
parse_arguments() {
  # Set defaults
  LEVEL="$DEFAULT_LEVEL"
  MIN_SIZE="$DEFAULT_MIN_SIZE"
  MIN_SIZE_BYTES=$(convert_to_bytes "$MIN_SIZE")
  SORT="$DEFAULT_SORT"
  CUT="$DEFAULT_CUT"
  CUT_BYTES=0
  [[ -n "$CUT" ]] && CUT_BYTES=$(convert_to_bytes "$CUT")
  REVERSE="$DEFAULT_REVERSE"
  ALL="$DEFAULT_ALL"
  TREE="$DEFAULT_TREE"
  ONE_FILE_SYSTEM="$DEFAULT_ONE_FILE_SYSTEM"
  DEREFERENCE="$DEFAULT_DEREFERENCE"
  WHITELIST=""
  BLACKLIST=""
  WHITELIST_FILE=""
  BLACKLIST_FILE=""
  EXCLUDE_HIDDEN="$DEFAULT_EXCLUDE_HIDDEN"
  
  # No arguments? Show help
  if [[ $# -eq 0 ]]; then
    show_help
    exit 0
  fi
  
  # Parse options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -D|--debug)
        DEBUG=true
        shift
        ;;
      -l|--level)
        if [[ -z "${2:-}" ]]; then
          error "Option $1 requires an argument" 1
        fi
        if ! [[ "$2" =~ ^[0-9]+$ ]]; then
          error "Level must be a non-negative integer" 1
        fi
        LEVEL="$2"
        shift 2
        ;;
      -m|--min-size)
        if [[ -z "${2:-}" ]]; then
          error "Option $1 requires an argument" 1
        fi
        MIN_SIZE="$2"
        MIN_SIZE_BYTES=$(convert_to_bytes "$MIN_SIZE")
        shift 2
        ;;
      -a|--all)
        ALL=true
        shift
        ;;
      -s|--sort)
        if [[ -z "${2:-}" ]]; then
          error "Option $1 requires an argument" 1
        fi
        if [[ "$2" != "size" && "$2" != "name" ]]; then
          error "Sort must be either 'size' or 'name'" 1
        fi
        SORT="$2"
        shift 2
        ;;
      -r|--reverse)
        REVERSE=true
        shift
        ;;
      -c|--cut)
        if [[ -z "${2:-}" ]]; then
          error "Option $1 requires an argument" 1
        fi
        CUT="$2"
        CUT_BYTES=$(convert_to_bytes "$CUT")
        shift 2
        ;;
      -w|--whitelist)
        if [[ -z "${2:-}" ]]; then
          error "Option $1 requires an argument" 1
        fi
        WHITELIST="$2"
        shift 2
        ;;
      --whitelist-file)
        if [[ -z "${2:-}" ]]; then
          error "Option $1 requires an argument" 1
        fi
        WHITELIST_FILE="$2"
        if [[ ! -f "$WHITELIST_FILE" ]]; then
          error "Whitelist file not found: $WHITELIST_FILE" 1
        fi
        shift 2
        ;;
      -b|--blacklist)
        if [[ -z "${2:-}" ]]; then
          error "Option $1 requires an argument" 1
        fi
        BLACKLIST="$2"
        shift 2
        ;;
      --blacklist-file)
        if [[ -z "${2:-}" ]]; then
          error "Option $1 requires an argument" 1
        fi
        BLACKLIST_FILE="$2"
        if [[ ! -f "$BLACKLIST_FILE" ]]; then
          error "Blacklist file not found: $BLACKLIST_FILE" 1
        fi
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
      --exclude-hidden)
        EXCLUDE_HIDDEN=true
        shift
        ;;
      -*)
        error "Unknown option: $1" 1
        ;;
      *)
        # Must be the target directory
        TARGET_DIR="$1"
        shift
        ;;
    esac
  done
  
  # Set default target directory if not specified
  TARGET_DIR="${TARGET_DIR:-$(pwd)}"
  
  # Validate target directory
  if [[ ! -d "$TARGET_DIR" ]]; then
    error "Target directory does not exist: $TARGET_DIR" 2
  fi
  
  # Normalize target directory path (remove trailing slash)
  TARGET_DIR="${TARGET_DIR%/}"
  
  debug_log "Configuration:"
  debug_log "  TARGET_DIR: $TARGET_DIR"
  debug_log "  LEVEL: $LEVEL"
  debug_log "  MIN_SIZE: $MIN_SIZE ($MIN_SIZE_BYTES bytes)"
  debug_log "  ALL: $ALL"
  debug_log "  SORT: $SORT"
  debug_log "  REVERSE: $REVERSE"
  debug_log "  CUT: $CUT"
  debug_log "  WHITELIST: $WHITELIST"
  debug_log "  WHITELIST_FILE: $WHITELIST_FILE"
  debug_log "  BLACKLIST: $BLACKLIST"
  debug_log "  BLACKLIST_FILE: $BLACKLIST_FILE"
  debug_log "  TREE: $TREE"
  debug_log "  ONE_FILE_SYSTEM: $ONE_FILE_SYSTEM"
  debug_log "  DEREFERENCE: $DEREFERENCE"
  debug_log "  EXCLUDE_HIDDEN: $EXCLUDE_HIDDEN"
}

# Load pattern files and merge with command-line patterns
load_patterns() {
  local local_whitelist_file="$TARGET_DIR/.disk_analyzer_include"
  local local_blacklist_file="$TARGET_DIR/.disk_analyzer_ignore"
  local home_whitelist_file="$HOME/.disk_analyzer_include"
  local home_blacklist_file="$HOME/.disk_analyzer_ignore"
  
  # Load whitelist patterns
  if [[ -n "$WHITELIST_FILE" ]]; then
    load_patterns_from_file "$WHITELIST_FILE" "WHITELIST_PATTERNS"
  else
    WHITELIST_PATTERNS=""
    # Try local whitelist file
    if [[ -f "$local_whitelist_file" ]]; then
      load_patterns_from_file "$local_whitelist_file" "WHITELIST_PATTERNS"
    fi
    # Try home whitelist file and append
    if [[ -f "$home_whitelist_file" ]]; then
      if [[ -n "$WHITELIST_PATTERNS" ]]; then
        load_patterns_from_file "$home_whitelist_file" "HOME_WHITELIST"
        WHITELIST_PATTERNS="$WHITELIST_PATTERNS,$HOME_WHITELIST"
      else
        load_patterns_from_file "$home_whitelist_file" "WHITELIST_PATTERNS"
      fi
    fi
  fi
  
  # Add command-line whitelist patterns
  if [[ -n "$WHITELIST" ]]; then
    if [[ -n "$WHITELIST_PATTERNS" ]]; then
      WHITELIST_PATTERNS="$WHITELIST_PATTERNS,$WHITELIST"
    else
      WHITELIST_PATTERNS="$WHITELIST"
    fi
  fi
  
  # Load blacklist patterns
  if [[ -n "$BLACKLIST_FILE" ]]; then
    load_patterns_from_file "$BLACKLIST_FILE" "BLACKLIST_PATTERNS"
  else
    BLACKLIST_PATTERNS=""
    # Try local blacklist file
    if [[ -f "$local_blacklist_file" ]]; then
      load_patterns_from_file "$local_blacklist_file" "BLACKLIST_PATTERNS"
    fi
    # Try home blacklist file and append
    if [[ -f "$home_blacklist_file" ]]; then
      if [[ -n "$BLACKLIST_PATTERNS" ]]; then
        load_patterns_from_file "$home_blacklist_file" "HOME_BLACKLIST"
        BLACKLIST_PATTERNS="$BLACKLIST_PATTERNS,$HOME_BLACKLIST"
      else
        load_patterns_from_file "$home_blacklist_file" "BLACKLIST_PATTERNS"
      fi
    fi
  fi
  
  # Add command-line blacklist patterns
  if [[ -n "$BLACKLIST" ]]; then
    if [[ -n "$BLACKLIST_PATTERNS" ]]; then
      BLACKLIST_PATTERNS="$BLACKLIST_PATTERNS,$BLACKLIST"
    else
      BLACKLIST_PATTERNS="$BLACKLIST"
    fi
  fi
  
  debug_log "Final patterns:"
  debug_log "  WHITELIST_PATTERNS: $WHITELIST_PATTERNS"
  debug_log "  BLACKLIST_PATTERNS: $BLACKLIST_PATTERNS"
}

# Validate whitelist paths against target directory
validate_whitelist() {
  # Only process if we have whitelist patterns
  if [[ -n "$WHITELIST_PATTERNS" ]]; then
    local pattern
    local valid_whitelist=""
    local invalid_whitelist=""
    
    IFS=',' read -ra pattern_array <<< "$WHITELIST_PATTERNS"
    for pattern in "${pattern_array[@]}"; do
      # Skip empty patterns
      [[ -z "$pattern" ]] && continue
      
      # Skip regex patterns for this check
      if [[ "$pattern" == regex:* ]]; then
        if [[ -z "$valid_whitelist" ]]; then
          valid_whitelist="$pattern"
        else
          valid_whitelist="$valid_whitelist,$pattern"
        fi
        continue
      fi
      
      # Check absolute path patterns
      if [[ "$pattern" == /* ]]; then
        if [[ "$pattern" == "$TARGET_DIR"/* ]]; then
          # Valid whitelist pattern
          if [[ -z "$valid_whitelist" ]]; then
            valid_whitelist="$pattern"
          else
            valid_whitelist="$valid_whitelist,$pattern"
          fi
        fi
      else
        # Relative or component patterns are always valid
        if [[ -z "$valid_whitelist" ]]; then
          valid_whitelist="$pattern"
        else
          valid_whitelist="$valid_whitelist,$pattern"
        fi
      fi
    done
    
    # Update the whitelist patterns to only valid ones
    WHITELIST_PATTERNS="$valid_whitelist"
    debug_log "Valid whitelist patterns: $WHITELIST_PATTERNS"
    debug_log "Invalid whitelist patterns: $invalid_whitelist"
  fi
}

# Create array to track visited inodes to prevent symlink loops
declare -A VISITED_INODES

# Check if we've already visited this inode
is_visited_inode() {
  local path="$1"
  local dev_inode
  
  if [[ ! -e "$path" ]]; then
    return 1  # Path doesn't exist
  fi
  
  # Get device:inode combination
  dev_inode=$(stat -c '%d:%i' "$path" 2>/dev/null)
  if [[ -z "$dev_inode" ]]; then
    return 1  # Can't get inode info
  fi
  
  if [[ -n "${VISITED_INODES[$dev_inode]}" ]]; then
    debug_log "Loop detected: $path -> ${VISITED_INODES[$dev_inode]}"
    return 0  # Already visited
  else
    VISITED_INODES[$dev_inode]="$path"
    return 1  # Not visited
  fi
}

# Check if a path should be included based on whitelist/blacklist
should_include_path() {
  local path="$1"
  
  # If whitelist is active, path must match a whitelist pattern
  if [[ -n "$WHITELIST_PATTERNS" ]]; then
    if matches_pattern "$path" "$WHITELIST_PATTERNS"; then
      debug_log "Path '$path' matches whitelist pattern"
      return 0
    else
      debug_log "Path '$path' does not match any whitelist pattern"
      return 1
    fi
  fi
  
  # If no whitelist but blacklist exists, path must not match any blacklist pattern
  if [[ -n "$BLACKLIST_PATTERNS" ]]; then
    if matches_pattern "$path" "$BLACKLIST_PATTERNS"; then
      debug_log "Path '$path' matches blacklist pattern"
      return 1
    else
      debug_log "Path '$path' does not match any blacklist pattern"
      return 0
    fi
  fi
  
  # No whitelist or blacklist, include everything
  return 0
}

# Calculate dir size using du with appropriate options
get_dir_size() {
  local dir="$1"
  local du_opts="-sb"  # -s: summary, -b: bytes
  
  # Add options based on configuration
  if [[ "$ONE_FILE_SYSTEM" == "true" ]]; then
    du_opts+=" -x"  # Don't cross filesystem boundaries
  fi
  
  if [[ "$DEREFERENCE" == "true" ]]; then
    du_opts+=" -L"  # Follow symlinks
  fi
  
  # Run du and extract only the size (first field)
  local size
  size=$(du $du_opts "$dir" 2>/dev/null | awk '{print $1}')
  
  # Check for du errors
  if [[ -z "$size" ]]; then
    warn "Could not get size of: $dir"
    echo "0"
  else
    echo "$size"
  fi
}

# Build find command with appropriate options
build_find_command() {
  local find_cmd="find"
  
  # Follow symlinks if requested
  if [[ "$DEREFERENCE" == "true" ]]; then
    find_cmd+=" -L"
  fi
  
  # Add target directory
  find_cmd+=" \"$TARGET_DIR\""
  
  # Stay on one filesystem if requested
  if [[ "$ONE_FILE_SYSTEM" == "true" ]]; then
    find_cmd+=" -xdev"
  fi
  
  # Set max depth based on level (unless level is 0)
  if [[ "$LEVEL" -gt 0 ]]; then
    find_cmd+=" -maxdepth $LEVEL"
  fi
  
  # Only include directories
  find_cmd+=" -type d"
  
  # Exclude hidden directories if requested
  if [[ "$EXCLUDE_HIDDEN" == "true" ]]; then
    find_cmd+=" -not -path '*/.*'"
  fi
  
  echo "$find_cmd"
}

# Analyze filesystem and generate results
analyze_filesystem() {
  local find_cmd
  local size_bytes
  local whitelisted_paths=()
  local results=()
  local io_errors=0
  local total_paths=0
  
  # Build find command for regular depth-limited traversal
  find_cmd=$(build_find_command)
  debug_log "Find command: $find_cmd"
  
  # Execute find command and process directories
  while IFS= read -r dir; do
    ((total_paths++))
    debug_log "Processing directory: $dir"
    
    if [[ "$DEREFERENCE" == "true" ]] && is_visited_inode "$dir"; then
      warn "Skipping symlink loop at: $dir"
      continue
    fi
    
    # Check whitelist/blacklist to see if we should include this path
    if should_include_path "$dir"; then
      # Calculate directory size
      size_bytes=$(get_dir_size "$dir")
      
      # Apply min-size filter if --all is not specified
      if [[ "$ALL" == "false" && "$size_bytes" -lt "$MIN_SIZE_BYTES" ]]; then
        debug_log "Skipping dir (below min-size): $dir ($size_bytes bytes < $MIN_SIZE_BYTES bytes)"
        continue
      fi
      
      # Store result
      results+=("$size_bytes	$dir")
      debug_log "Added result: $size_bytes	$dir"
    else
      debug_log "Skipping dir (filtered): $dir"
    fi
  done < <(eval "$find_cmd" 2>/dev/null)
  
  # Handle whitelisted paths beyond the specified level
  if [[ -n "$WHITELIST_PATTERNS" ]]; then
    debug_log "Processing whitelisted paths beyond level $LEVEL"
    
    # Find all whitelisted paths beyond the level
    IFS=',' read -ra pattern_array <<< "$WHITELIST_PATTERNS"
    for pattern in "${pattern_array[@]}"; do
      # Skip empty patterns
      [[ -z "$pattern" ]] && continue
      
      # Skip regex patterns for this check
      if [[ "$pattern" == regex:* ]]; then
        continue
      fi
      
      # Handle absolute path patterns
      if [[ "$pattern" == /* && "$pattern" == "$TARGET_DIR"/* ]]; then
        if [[ -d "$pattern" ]]; then
          whitelisted_paths+=("$pattern")
        fi
      else
        # Handle relative/component patterns by running a deep find
        local deep_find="find"
        if [[ "$DEREFERENCE" == true ]]; then
          deep_find+=" -L"
        fi
        deep_find+=" \"$TARGET_DIR\""
        if [[ "$ONE_FILE_SYSTEM" == true ]]; then
          deep_find+=" -xdev"
        fi
        deep_find+=" -type d -path \"*$pattern*\" 2>/dev/null"
        
        while IFS= read -r wpath; do
          [[ -z "$wpath" ]] && continue
          whitelisted_paths+=("$wpath")
        done < <(eval "$deep_find")
      fi
    done
    
    # Process each whitelisted path
    for wpath in "${whitelisted_paths[@]}"; do
      # Skip paths within the normal level (already processed)
      local depth=$(echo "$wpath" | tr -cd '/' | wc -c)
      local target_depth=$(echo "$TARGET_DIR" | tr -cd '/' | wc -c)
      local rel_depth=$((depth - target_depth))
      
      if [[ "$rel_depth" -le "$LEVEL" ]]; then
        debug_log "Skipping whitelisted path (within level): $wpath"
        continue
      fi
      
      debug_log "Processing whitelisted path: $wpath"
      
      if [[ "$DEREFERENCE" == "true" ]] && is_visited_inode "$wpath"; then
        warn "Skipping symlink loop at: $wpath"
        continue
      fi
      
      # Calculate directory size
      size_bytes=$(get_dir_size "$wpath")
      if [[ "$size_bytes" -eq 0 ]]; then
        ((io_errors++))
      fi
      
      # Store result (no min-size filtering for whitelisted paths)
      results+=("$size_bytes	$wpath")
      debug_log "Added whitelisted result: $size_bytes	$wpath"
    done
  fi
  
  # Sort results
  local sort_cmd="sort"
  if [[ "$SORT" == "size" ]]; then
    sort_cmd+=" -n"  # Numeric sort
  elif [[ "$SORT" == "name" ]]; then
    sort_cmd+=" -k2"  # Sort by second field (path)
  fi
  
  if [[ "$REVERSE" == "true" ]]; then
    sort_cmd+=" -r"  # Reverse sort
  fi
  
  # Apply cut filter and format results
  local formatted_results=()
  for result in "${results[@]}"; do
    # Extract size and path
    local size path
    size=$(echo "$result" | awk '{print $1}')
    path=$(echo "$result" | cut -f2-)
    
    # Apply cut filter (exempt whitelisted paths)
    if [[ -n "$CUT" && "$size" -lt "$CUT_BYTES" ]]; then
      if [[ -n "$WHITELIST_PATTERNS" ]] && matches_pattern "$path" "$WHITELIST_PATTERNS"; then
        debug_log "Keeping whitelisted path despite cut filter: $path"
      else
        debug_log "Skipping path (below cut size): $path ($size bytes < $CUT_BYTES bytes)"
        continue
      fi
    fi
    
    # Format size
    local human_size
    human_size=$(format_size "$size")
    
    # Store formatted result
    formatted_results+=("$human_size	$path")
  done
  
  # Sort and output results
  if [[ "$TREE" == "true" ]]; then
    display_tree_visualization "${formatted_results[@]}"
  else
    printf "%s\n" "${formatted_results[@]}" | eval "$sort_cmd"
  fi
  
  if [[ "${#formatted_results[@]}" -eq 0 ]]; then
    echo "No directories found"
  fi
  
  # Check if all paths failed
  if [[ "$io_errors" -gt 0 && "$io_errors" -eq "$total_paths" ]]; then
    error "All paths failed with I/O errors" 3
  fi
}

# Display results in a tree-like structure
display_tree_visualization() {
  local -a formatted_results=("$@")
  local -A dir_sizes
  local -A dir_paths
  local -A dir_depths
  local -a sorted_dirs
  local parent_path
  
  # Build associative arrays for directories and their sizes
  for result in "${formatted_results[@]}"; do
    local size path
    size=$(echo "$result" | awk '{print $1}')
    path=$(echo "$result" | cut -f2-)
    
    # Store size and path
    dir_sizes["$path"]="$size"
    dir_paths["$path"]="$path"
    
    # Calculate directory depth relative to target
    local depth
    if [[ "$path" == "$TARGET_DIR" ]]; then
      depth=0
    else
      # Replace target dir with empty string and count remaining slashes
      local rel_path="${path#$TARGET_DIR/}"
      depth=$(echo "$rel_path" | tr -cd '/' | wc -c)
      ((depth++))  # Add 1 since we removed the first slash
    fi
    dir_depths["$path"]=$depth
  done
  
  # Sort directories by path for hierarchical display
  for path in "${!dir_sizes[@]}"; do
    sorted_dirs+=("$path")
  done
  
  # Sort directories naturally by path to ensure proper tree structure
  IFS=$'\n' sorted_dirs=($(printf "%s\n" "${sorted_dirs[@]}" | sort))
  
  # First, display the root directory with its size
  local root_shown=false
  for path in "${sorted_dirs[@]}"; do
    if [[ "$path" == "$TARGET_DIR" ]]; then
      printf "%s\t%s\n" "${dir_sizes[$path]}" "$(basename "$path")"
      root_shown=true
      break
    fi
  done
  
  # If root wasn't in the results, show it anyway with a placeholder
  if [[ "$root_shown" == "false" ]]; then
    printf "?\t%s\n" "$(basename "$TARGET_DIR")"
  fi
  
  # Display the tree for all other directories
  for path in "${sorted_dirs[@]}"; do
    # Skip root as we've already displayed it
    if [[ "$path" == "$TARGET_DIR" ]]; then
      continue
    fi
    
    local size="${dir_sizes[$path]}"
    local depth="${dir_depths[$path]}"
    local indent=""
    
    # Find the parent path for proper tree branch drawing
    parent_path=$(dirname "$path")
    
    # Create indentation based on depth
    for ((i=0; i<depth; i++)); do
      indent+="  "
    done
    
    # Add tree connector for non-root directories
    if [[ "$depth" -gt 0 ]]; then
      # Use different tree connectors based on whether this is the last item in its branch
      local is_last=true
      for check_path in "${sorted_dirs[@]}"; do
        # Skip paths that aren't siblings
        if [[ "$(dirname "$check_path")" != "$parent_path" ]]; then
          continue
        fi
        # Skip the current path and ones we've already processed
        if [[ "$check_path" == "$path" || "$check_path" < "$path" ]]; then
          continue
        fi
        # If we're here, there's a sibling after the current path
        is_last=false
        break
      done
      
      if [[ "$is_last" == "true" ]]; then
        indent="${indent:0:-2}└─"
      else
        indent="${indent:0:-2}├─"
      fi
    fi
    
    # Extract the base directory name
    local dirname=$(basename "$path")
    
    # Print formatted tree entry
    printf "%s%s\t%s\n" "$indent" "$size" "$dirname"
  done
}

# Main function
main() {
  # Parse command line arguments
  parse_arguments "$@"
  
  # Load pattern files
  load_patterns
  
  # Validate whitelist paths
  validate_whitelist
  
  # Run the analysis
  analyze_filesystem
}

# Entry point
main "$@"