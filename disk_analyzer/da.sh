#!/usr/bin/env bash

# Default values
LEVEL=1
LEVEL_SET=false
MIN_SIZE=0
SHOW_HIDDEN=false
CUT_SIZE=0
SORT_METHOD="none"
REVERSE=false
TREE_MODE=false
HUMAN_READABLE=true
IGNORE_PATTERN=""
PATTERN=""
IGNORE_FILE=""
FILES_FIRST=false
DIRS_FIRST=false
TARGET_DIR="."

# Help function
show_help() {
    cat << EOF
Usage: ${0##*/} [OPTIONS] [TARGET_DIR]

Options:
  -l, --level N          Set depth level for directory scanning (default: 1)
  -m, --min-size SIZE    Minimum size to show directory contents (e.g., 1M, 1G)
  -a, --all              Show hidden files (default: false)
  -c, --cut SIZE         Omit paths smaller than SIZE from output
  -s, --sort METHOD      Sort by "name" or "size" (default: none)
  -r, --reverse          Reverse sort order (only with --sort size)
  -t, --tree             Display results in tree format
  -b, --bytes            Show sizes in bytes (non-human readable)
  -I, --ignore-pattern   Exclude files matching pattern (like tree -I)
  -P, --pattern          Only include files matching pattern (like tree -P)
  -i, --ignore-file      Ignore files matching patterns from .gitignore
  --filesfirst           Sort files before directories
  --dirsfirst            Sort directories before files
  -h, --help             Display this help and exit

TARGET_DIR defaults to current directory if not specified.

Size units: K (KiB), M (MiB), G (GiB), T (TiB)
EOF
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -l|--level) LEVEL="$2"; LEVEL_SET=true; shift ;;
        -m|--min-size) MIN_SIZE="$2"; shift ;;
        -a|--all) SHOW_HIDDEN=true ;;
        -c|--cut) CUT_SIZE="$2"; shift ;;
        -s|--sort) SORT_METHOD="$2"; 
                   # Validate sort method
                   if [[ "$SORT_METHOD" != "name" && "$SORT_METHOD" != "size" ]]; then
                       echo "Error: Sort method must be 'name' or 'size'" >&2
                       exit 1
                   fi
                   shift ;;
        -r|--reverse) REVERSE=true ;;
        -t|--tree) TREE_MODE=true ;;
        -b|--bytes) HUMAN_READABLE=false ;;
        -I|--ignore-pattern) IGNORE_PATTERN="$2"; shift ;;
        -P|--pattern) PATTERN="$2"; shift ;;
        -i|--ignore-file|--gitignore) IGNORE_FILE="$2"; shift ;;
        --filesfirst) FILES_FIRST=true ;;
        --dirsfirst) DIRS_FIRST=true ;;
        -h|--help) show_help; exit 0 ;;
        *) TARGET_DIR="$1" ;;
    esac
    shift
done

# Validate arguments
if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: Target directory does not exist or is not accessible." >&2
    exit 1
fi

if [[ "$LEVEL" -lt 0 ]]; then
    echo "Error: Level must be a positive integer or 0 for unlimited." >&2
    exit 1
fi

# Convert human-readable sizes to bytes for comparison
convert_to_bytes() {
    local size=$1
    if [[ "$size" =~ ^[0-9]+[Kk]$ ]]; then
        size=$(( ${size%[Kk]} * 1024 ))
    elif [[ "$size" =~ ^[0-9]+[Mm]$ ]]; then
        size=$(( ${size%[Mm]} * 1024 * 1024 ))
    elif [[ "$size" =~ ^[0-9]+[Gg]$ ]]; then
        size=$(( ${size%[Gg]} * 1024 * 1024 * 1024 ))
    elif [[ "$size" =~ ^[0-9]+[Tt]$ ]]; then
        size=$(( ${size%[Tt]} * 1024 * 1024 * 1024 * 1024 ))
    fi
    echo "$size"
}

MIN_SIZE_BYTES=$(convert_to_bytes "$MIN_SIZE")
CUT_SIZE_BYTES=$(convert_to_bytes "$CUT_SIZE")

# Build find command options
find_opts=("-type" "d")
if [[ "$SHOW_HIDDEN" = false ]]; then
    find_opts+=("-not" "-path" "*/.*")
fi

# Build du command options
du_opts=("-b") # Always use bytes for internal calculations
if [[ "$LEVEL" -gt 0 ]]; then
    du_opts+=("--max-depth=$LEVEL")
fi

# Matches a path against a pattern like tree's -P option
match_pattern() {
    local path="$1"
    local pattern="$2"
    local basename=$(basename "$path")
    
    # Skip git object directories for -P matching
    if [[ "${path}" == *".git/objects/"* && "${#basename}" -eq 2 ]]; then
        # Special case for .git/objects/ directories (git hash storage)
        # Only match if the pattern exactly matches the hash
        if [[ "$basename" == "$pattern" ]]; then
            echo "true"
        else
            echo "false"
        fi
        return
    fi

    # Use case insensitive glob pattern matching like tree
    shopt -s nocasematch
    # Match exact pattern or if pattern is contained in basename
    if [[ "$basename" == "$pattern" || "$basename" == $pattern || "$basename" == *"$pattern"* ]]; then
        echo "true"
    else
        echo "false"
    fi
    shopt -u nocasematch
}

# Check if a path should be ignored based on pattern
should_ignore() {
    local path="$1"
    local basename=$(basename "$path")
    
    # Skip if it matches ignore pattern
    if [[ -n "$IGNORE_PATTERN" ]]; then
        # Handle multiple patterns separated by |
        local patterns
        IFS='|' read -ra patterns <<< "$IGNORE_PATTERN"
        for pattern in "${patterns[@]}"; do
            shopt -s nocasematch
            if [[ "$basename" == $pattern ]]; then
                echo "true"
                return
            fi
            shopt -u nocasematch
        done
    fi
    
    echo "false"
}

# Check if path contains any component matching the ignore pattern
path_contains_ignore() {
    local path="$1"
    
    if [[ -z "$IGNORE_PATTERN" ]]; then
        echo "false"
        return
    fi
    
    # Handle multiple patterns separated by |
    local patterns
    IFS='|' read -ra patterns <<< "$IGNORE_PATTERN"
    
    # Split path into components and check each one
    local IFS='/'
    local components=($path)
    
    for component in "${components[@]}"; do
        if [[ -n "$component" ]]; then
            for pattern in "${patterns[@]}"; do
                shopt -s nocasematch
                if [[ "$component" == $pattern ]]; then
                    echo "true"
                    return
                fi
                shopt -u nocasematch
            done
        fi
    done
    
    echo "false"
}

# Function to generate size list
generate_size_list() {
    local target="$1"
    
    # First pass to get all directory sizes
    local size_map_file=$(mktemp)
    # Use level limit if specified
    local level_opt=""
    if [[ "$LEVEL_SET" == true ]]; then
        level_opt="--max-depth=$LEVEL"
    fi
    sudo du -a $level_opt "${du_opts[@]}" "$target" | sort -k2 | tee "$size_map_file" > /dev/null
    
    # Second pass to apply min-size filtering
    local result_file=$(mktemp)
    
    while read -r size path; do
        # Skip if this path contains an ignored component
        if [[ "$(path_contains_ignore "$path")" == "true" ]]; then
            continue
        fi
        
        # Check if this path should be excluded due to min-size
        local parent_path=$(dirname "$path")
        # Get exact parent size to avoid multiple matches
        local parent_size=$(awk -v p="$parent_path" '$2 == p {print $1; exit}' "$size_map_file")
        
        # Skip if size is below cut threshold
        if [[ "$size" -lt "$CUT_SIZE_BYTES" ]]; then
            continue
        fi
        
        # Skip if level is set and this path exceeds the level depth
        if [[ "$LEVEL_SET" == true ]]; then
            local rel_path="${path#$target/}"
            local depth=$(echo "$rel_path" | tr -cd '/' | wc -c)
            if [[ $depth -ge $LEVEL ]]; then
                continue
            fi
        fi
        
        # Skip if parent is below min-size (unless it's the target)
        if [[ "$parent_size" -lt "$MIN_SIZE_BYTES" && "$path" != "$target" ]]; then
            continue
        fi
        
        # Skip if pattern is specified and it doesn't match
        if [[ -n "$PATTERN" ]]; then
            if [[ "$(match_pattern "$path" "$PATTERN")" != "true" ]]; then
                continue
            fi
        fi
        
        # Format size if human readable
        local display_size="$size"
        if [[ "$HUMAN_READABLE" = true ]]; then
            display_size=$(numfmt --to=iec --suffix=B "$size")
        fi
        
        printf "%s\t%s\n" "$display_size" "$path"
    done < "$size_map_file" > "$result_file"
    
    # Apply sorting and optional grouping
    # Capture sorted output
    if [[ "$SORT_METHOD" == "size" ]]; then
        if [[ "$REVERSE" = true ]]; then
            sorted_output=$(sort -h -k1 "$result_file")
        else
            sorted_output=$(sort -h -r -k1 "$result_file")
        fi
    elif [[ "$SORT_METHOD" == "name" ]]; then
        sorted_output=$(sort -k2 "$result_file")
    else
        sorted_output=$(cat "$result_file")
    fi

    # Group files and directories if requested
    if [[ "$FILES_FIRST" == true || "$DIRS_FIRST" == true ]]; then
        files_output=""
        dirs_output=""
        while IFS=$'\t' read -r sz p; do
            if [[ -f "$p" ]]; then
                files_output+="${sz}\t${p}\n"
            else
                dirs_output+="${sz}\t${p}\n"
            fi
        done <<< "$sorted_output"
        if [[ "$FILES_FIRST" == true ]]; then
            printf "%b" "$files_output$dirs_output"
        else
            printf "%b" "$dirs_output$files_output"
        fi
    else
        printf "%s\n" "$sorted_output"
    fi
    
    rm "$size_map_file" "$result_file"
}

# Recursive function to print tree with du-style summary and options
print_tree() {
    local path="$1" indent="$2" depth="$3" is_last="$4"
    local basename=$(basename "$path")
    
    # Skip if it should be ignored
    if [[ -n "$IGNORE_PATTERN" ]] && [[ "$(should_ignore "$path")" == "true" ]]; then
        return
    fi
    
    # Skip if pattern is specified and it doesn't match, unless it's the root
    if [[ -n "$PATTERN" && "$path" != "$TARGET_DIR" ]]; then
        # Skip Git object directories for -P matching (avoid false positives)
        if [[ "$path" == *".git/objects/"* && $(basename "$path" | wc -c) -eq 3 ]]; then
            # Only continue if exact pattern match for git object dirs
            if [[ "$(match_pattern "$path" "$PATTERN")" != "true" ]]; then
                return
            fi
        else
            # For non-root paths, they must match the pattern or have a descendant that matches
            local matches=$(find "$path" -name "*${PATTERN}*" -print -quit 2>/dev/null)
            if [[ -z "$matches" ]] && [[ "$(match_pattern "$path" "$PATTERN")" != "true" ]]; then
                return
            fi
        fi
    fi
    
    # Get cumulative size
    local size_bytes=$(du -sb "$path" 2>/dev/null | cut -f1)
    
    # Format size display
    local disp_size=$size_bytes
    if [[ "$HUMAN_READABLE" == true ]]; then
        disp_size=$(numfmt --to=iec --suffix=B "$size_bytes")
    fi
    
    # Print root node only once
    if [[ "$depth" -eq 0 ]]; then
        echo "[${disp_size}]  ${basename}"
    fi
    
    # Stop recursion if reached depth limit
    # Stop if we've reached level limit and it's set explicitly
    if [[ "$LEVEL_SET" == true && $depth -ge $LEVEL ]]; then
        return
    fi
    
    # If below min-size, treat as leaf and do not descend
    if [[ "$path" != "$TARGET_DIR" && $size_bytes -lt $MIN_SIZE_BYTES ]]; then
        return
    fi
    
    # Collect immediate children and filter
    local entries=()
    while IFS= read -r child; do
        if [[ -n "$child" ]]; then
            # Skip if it should be ignored
            if [[ -n "$IGNORE_PATTERN" ]] && [[ "$(should_ignore "$child")" == "true" ]]; then
                continue
            fi
            
            # Skip if pattern is specified and it doesn't match
            if [[ -n "$PATTERN" ]]; then
                # Skip Git object directories for -P matching (avoid false positives)
                if [[ "$child" == *".git/objects/"* && $(basename "$child" | wc -c) -eq 3 ]]; then
                    # Only include git object dirs with exact pattern match
                    if [[ "$(match_pattern "$child" "$PATTERN")" != "true" ]]; then
                        continue
                    fi
                else
                    # For pattern matching, check if this path or any descendant matches
                    local matches=$(find "$child" -name "*${PATTERN}*" -print -quit 2>/dev/null)
                    if [[ -z "$matches" ]] && [[ "$(match_pattern "$child" "$PATTERN")" != "true" ]]; then
                        continue
                    fi
                fi
            fi
            
            # Get child's size safely
            local child_size=$(du -sb "$child" 2>/dev/null | cut -f1)
            
            # Skip if below cut threshold
            if (( child_size < CUT_SIZE_BYTES )); then
                continue
            fi
            
            # Add to entries array with tab delimiter to avoid spaces-in-path issues
            entries+=("${child_size}$(printf '\t')${child}")
        fi
    done < <(
        find "$path" -mindepth 1 -maxdepth 1 \
            $( [[ "$SHOW_HIDDEN" == false ]] && echo "-not -path '*/.*'" ) \
            -print
    )
    
    # Sort entries
    if [[ ${#entries[@]} -gt 0 ]]; then
        if [[ "$SORT_METHOD" == "size" ]]; then
            if [[ "$REVERSE" == true ]]; then
                mapfile -t entries < <(printf "%s\n" "${entries[@]}" | sort -t $'\t' -n -k1,1)
            else
                mapfile -t entries < <(printf "%s\n" "${entries[@]}" | sort -t $'\t' -n -r -k1,1)
            fi
        elif [[ "$SORT_METHOD" == "name" ]]; then
            mapfile -t entries < <(printf "%s\n" "${entries[@]}" | sort -t $'\t' -k2,2)
        fi
    fi
    
    # Apply filesfirst or dirsfirst if requested
    if [[ "$FILES_FIRST" == true || "$DIRS_FIRST" == true ]]; then
        local files=() dirs=()
        for entry in "${entries[@]}"; do
            local child="${entry#*$'\t'}"
            if [[ -d "$child" ]]; then
                dirs+=("$entry")
            else
                files+=("$entry")
            fi
        done
        
        if [[ "$FILES_FIRST" == true ]]; then
            entries=("${files[@]}" "${dirs[@]}")
        else
            entries=("${dirs[@]}" "${files[@]}")
        fi
    fi
    
    # Process each child with proper indent and symbols
    local total=${#entries[@]}
    for i in "${!entries[@]}"; do
        local entry="${entries[$i]}"
        local child="${entry#*$'\t'}"
        local child_size="${entry%%$'\t'*}"
        local child_basename=$(basename "$child")
        local disp_child_size="$child_size"
        if [[ "$HUMAN_READABLE" == true ]]; then
            disp_child_size=$(numfmt --to=iec --suffix=B "$child_size")
        fi

        local branch next_indent
        if [[ $i -eq $((total-1)) ]]; then
            branch="└── "
            next_indent="    "
        else
            branch="├── "
            next_indent="│   "
        fi

        echo -e "${indent}${branch}[${disp_child_size}]  ${child_basename}"

        print_tree "$child" "${indent}${next_indent}" $((depth+1)) \
          "$([[ $i -eq $((total-1)) ]] && echo true || echo false)"
    done
}

# Function to generate tree view with accurate du summary
generate_tree_view() {
    print_tree "$TARGET_DIR" "" 0
}

# Main execution
if [[ "$TREE_MODE" = true ]]; then
    generate_tree_view "$TARGET_DIR"
else
    generate_size_list "$TARGET_DIR"
fi