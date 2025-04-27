#!/usr/bin/env python3
"""
disk_analyzer.py - A comprehensive disk space analysis tool

This is a Python implementation of the disk_analyzer.sh tool described in the system architecture
documentation. It provides the same functionality with additional Python-specific optimizations
and features while maintaining the same interface and behavior.
"""

import os
import sys
import re
import argparse
import fnmatch
from pathlib import Path
from typing import List, Dict, Tuple, Set, Optional, Union, Pattern
import stat
import time
import math
import json
from collections import defaultdict
import platform
import subprocess
import shutil
import warnings
from functools import lru_cache
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

# Constants
DEFAULT_LEVEL = 1
DEFAULT_MIN_SIZE = '0K'
DEFAULT_SORT_KEY = 'size'
DEFAULT_SORT_REVERSE = False
DEFAULT_TREE_VIEW = False
DEFAULT_ONE_FS = False
DEFAULT_DEREFERENCE = False

# Exit codes
EXIT_SUCCESS = 0
EXIT_ARG_ERROR = 1
EXIT_TARGET_ERROR = 2
EXIT_IO_ERROR = 3

# Size units
SIZE_UNITS = {
    'K': 1024,
    'M': 1024**2,
    'G': 1024**3,
    'T': 1024**4,
    'P': 1024**5,
    'KB': 1024,
    'MB': 1024**2,
    'GB': 1024**3,
    'TB': 1024**4,
    'PB': 1024**5,
    'KiB': 1024,
    'MiB': 1024**2,
    'GiB': 1024**3,
    'TiB': 1024**4,
    'PiB': 1024**5,
}

# Output format settings
SIZE_COLUMN_WIDTH = 12  # Increased width for size column in output
PATH_FORMAT = 'relative'  # Options: 'absolute', 'relative', 'basename'
TREE_INDENT = '  '  # Indent for tree view

# Debug mode - This will be set by command line arguments
DEBUG = os.environ.get('DEBUG', '').lower() in ('true', '1', 't')

class DiskAnalyzerError(Exception):
    """Base exception class for disk analyzer errors."""
    pass

class SizeFormatError(DiskAnalyzerError):
    """Exception raised for invalid size formats."""
    pass

class PatternError(DiskAnalyzerError):
    """Exception raised for invalid patterns."""
    pass

class TraversalError(DiskAnalyzerError):
    """Exception raised during filesystem traversal."""
    pass

def debug_log(message: str) -> None:
    """Log debug messages if DEBUG is enabled."""
    if DEBUG:
        print(f"[DEBUG] {message}", file=sys.stderr)

def parse_size(size_str: str) -> int:
    """
    Parse a human-readable size string into bytes.
    
    Args:
        size_str: The size string to parse (e.g., '10M', '1.5G')
    
    Returns:
        The size in bytes
    
    Raises:
        SizeFormatError: If the size string is invalid
    """
    if not size_str:
        raise SizeFormatError("Empty size string")
    
    # Check for pure numeric value
    if size_str.isdigit():
        return int(size_str)
    
    # Extract numeric part and unit
    match = re.match(r'^([\d.]+)\s*([A-Za-z]+)?$', size_str.strip())
    if not match:
        raise SizeFormatError(f"Invalid size format: {size_str}")
    
    number_part = match.group(1)
    unit_part = (match.group(2) or 'B').upper()
    
    try:
        number = float(number_part)
    except ValueError:
        raise SizeFormatError(f"Invalid numeric part: {number_part}")
    
    if unit_part == 'B' or not unit_part:
        return int(number)
    
    if unit_part in SIZE_UNITS:
        return int(number * SIZE_UNITS[unit_part])
    
    # Try without the 'B' (e.g., 'K' instead of 'KB')
    if unit_part.endswith('B'):
        unit_part = unit_part[:-1]
        if unit_part in SIZE_UNITS:
            return int(number * SIZE_UNITS[unit_part])
    
    raise SizeFormatError(f"Invalid size unit: {unit_part}")

def format_size(size_bytes: int) -> str:
    """
    Format a size in bytes into a human-readable string.
    
    Args:
        size_bytes: The size in bytes
    
    Returns:
        Human-readable size string (e.g., '1.23 MB')
    """
    if size_bytes == 0:
        return "0 B"
    
    size_names = ('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    i = int(math.floor(math.log(size_bytes, 1024)))
    p = math.pow(1024, i)
    s = round(size_bytes / p, 2)
    
    # Handle cases where we get 1024 KB which should be 1 MB, etc.
    if s >= 1024 and i + 1 < len(size_names):
        i += 1
        s /= 1024
        s = round(s, 2)
    
    # Format with fixed width for alignment
    return f"{s:.2f} {size_names[i]}"

def compile_pattern(pattern: str) -> Union[Pattern, str]:
    """
    Compile a pattern into either a regex or glob pattern.
    
    Args:
        pattern: The pattern string, optionally prefixed with 'regex:'
    
    Returns:
        Either a compiled regex pattern or a glob pattern string
    
    Raises:
        PatternError: If the pattern is invalid
    """
    if pattern.startswith('regex:'):
        try:
            return re.compile(pattern[6:])
        except re.error as e:
            raise PatternError(f"Invalid regex pattern '{pattern[6:]}': {e}")
    return pattern

def match_pattern(path: str, pattern: Union[Pattern, str], is_absolute: bool = False) -> bool:
    """
    Match a path against a pattern (regex or glob).
    
    Args:
        path: The path to match
        pattern: The compiled regex or glob pattern
        is_absolute: Whether the pattern should be matched absolutely
    
    Returns:
        True if the path matches the pattern, False otherwise
    """
    if isinstance(pattern, re.Pattern):
        return bool(pattern.search(path))
    
    # Handle absolute patterns
    if pattern.startswith('/'):
        return fnmatch.fnmatch(path, pattern)
    
    # Handle relative patterns
    if is_absolute:
        return fnmatch.fnmatch(path, f'*/{pattern}')
    else:
        return fnmatch.fnmatch(path, pattern) or fnmatch.fnmatch(path, f'*/{pattern}')

def load_pattern_file(file_path: str) -> List[str]:
    """
    Load patterns from a file, stripping comments and empty lines.
    
    Args:
        file_path: Path to the pattern file
    
    Returns:
        List of patterns
    
    Raises:
        DiskAnalyzerError: If the file cannot be read
    """
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            patterns = []
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    patterns.append(line)
            return patterns
    except IOError as e:
        raise DiskAnalyzerError(f"Could not read pattern file {file_path}: {e}")

def find_pattern_files(target_dir: str, filename: str) -> List[str]:
    """
    Find pattern files in the target directory and home directory.
    
    Args:
        target_dir: The target directory to scan
        filename: The pattern file name to look for
    
    Returns:
        List of found pattern files (local first, then home directory)
    """
    files = []
    
    # Check target directory
    local_file = os.path.join(target_dir, filename)
    if os.path.isfile(local_file):
        files.append(local_file)
    
    # Check home directory
    home_file = os.path.join(os.path.expanduser('~'), filename)
    if home_file != local_file and os.path.isfile(home_file):
        files.append(home_file)
    
    return files

def get_inode(path: str) -> Tuple[int, int]:
    """
    Get the device and inode numbers for a path.
    
    Args:
        path: The path to check
    
    Returns:
        Tuple of (device_id, inode) numbers
    """
    try:
        stat_info = os.lstat(path)
        return (stat_info.st_dev, stat_info.st_ino)
    except OSError:
        return (0, 0)

def should_follow_link(path: str, follow_symlinks: bool, one_filesystem: bool, visited_inodes: Set[Tuple[int, int]]) -> bool:
    """
    Determine whether to follow a symbolic link.
    
    Args:
        path: The path to check
        follow_symlinks: Whether symlinks should be followed
        one_filesystem: Whether to stay on one filesystem
        visited_inodes: Set of already visited inodes
    
    Returns:
        True if the link should be followed, False otherwise
    
    Raises:
        TraversalError: If a symlink loop is detected
    """
    if not follow_symlinks:
        return False
    
    try:
        stat_info = os.lstat(path)
        if not stat.S_ISLNK(stat_info.st_mode):
            return False
        
        # Check if we're staying on one filesystem
        if one_filesystem:
            target_stat = os.stat(path)
            if target_stat.st_dev != os.stat(os.path.dirname(path)).st_dev:
                return False
        
        # Check for symlink loops
        inode = (stat_info.st_dev, stat_info.st_ino)
        if inode in visited_inodes:
            raise TraversalError(f"Symlink loop detected at {path}")
        
        visited_inodes.add(inode)
        return True
    except OSError as e:
        debug_log(f"Error checking symlink {path}: {e}")
        return False

def get_file_size(path: str, follow_symlinks: bool = False) -> int:
    """
    Get the size of a file or directory, similar to 'du -b'.
    
    Args:
        path: The path to measure
        follow_symlinks: Whether to follow symlinks
    
    Returns:
        The apparent size in bytes
    
    Raises:
        OSError: If the path cannot be accessed
    """
    try:
        if follow_symlinks:
            stat_fn = os.stat
        else:
            stat_fn = os.lstat
        
        # For directories, we want to get disk usage similar to 'du'
        # This means we need to include the size of the directory itself
        if os.path.isdir(path) and not os.path.islink(path):
            total = stat_fn(path).st_blocks * 512  # Block size in bytes
            try:
                with os.scandir(path) as it:
                    for entry in it:
                        try:
                            if entry.is_dir(follow_symlinks=follow_symlinks):
                                total += get_file_size(entry.path, follow_symlinks)
                            else:
                                # Use block size for files too to match du behavior
                                total += stat_fn(entry.path).st_blocks * 512
                        except OSError as e:
                            debug_log(f"Error accessing {entry.path}: {e}")
                            continue
            except OSError as e:
                debug_log(f"Error scanning directory {path}: {e}")
            return total
        else:
            # For regular files, use block size to match 'du' output
            return stat_fn(path).st_blocks * 512
    except OSError as e:
        debug_log(f"Error getting size for {path}: {e}")
        raise

def process_directory_batch(batch, follow_symlinks):
    """
    Process a batch of directories to get their sizes.
    
    Args:
        batch: List of directory paths to process
        follow_symlinks: Whether to follow symlinks
    
    Returns:
        Dictionary mapping paths to their sizes
    """
    result = {}
    for path in batch:
        try:
            result[path] = get_file_size(path, follow_symlinks)
        except OSError as e:
            debug_log(f"Error processing directory {path}: {e}")
    return result

def walk_directory(
    root: str,
    max_depth: int = None,
    follow_symlinks: bool = False,
    one_filesystem: bool = False,
    whitelist_patterns: List[Union[Pattern, str]] = None,
    min_size: int = 0,
    all_files: bool = False,
    show_progress: bool = False,
    use_parallel: bool = False,
    max_workers: int = None
) -> Dict[str, int]:
    """
    Walk a directory tree and collect sizes of files and directories.
    
    Args:
        root: The root directory to scan
        max_depth: Maximum recursion depth (None for unlimited)
        follow_symlinks: Whether to follow symbolic links
        one_filesystem: Whether to stay on one filesystem
        whitelist_patterns: List of whitelist patterns
        min_size: Minimum size to include (unless whitelisted)
        all_files: Include all files regardless of size
        show_progress: Whether to show a progress indicator
        use_parallel: Whether to use parallel processing for large directories
        max_workers: Maximum number of worker threads (None = auto)
    
    Returns:
        Dictionary mapping paths to their sizes in bytes
    """
    sizes = {}
    visited_inodes = set()
    root_dev = os.stat(root).st_dev if one_filesystem else None
    
    # Initialize with root directory
    try:
        sizes[root] = 0
    except OSError as e:
        raise TraversalError(f"Could not access target directory {root}: {e}")
    
    # Set up parallel processing
    if use_parallel:
        if max_workers is None:
            max_workers = min(32, os.cpu_count() + 4)
        executor = ThreadPoolExecutor(max_workers=max_workers)
        debug_log(f"Using parallel processing with {max_workers} workers")
    
    # For progress indicator
    total_items = 0
    processed_items = 0
    progress_lock = threading.Lock()
    last_update_time = time.time()
    update_interval = 0.1  # Update progress every 0.1 seconds to avoid excessive I/O
    
    # Count total items if showing progress
    if show_progress:
        try:
            sys.stderr.write("Counting items... ")
            sys.stderr.flush()
            
            for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
                total_items += len(filenames) + 1  # +1 for the directory itself
                if max_depth is not None:
                    current_depth = dirpath[len(root):].count(os.sep)
                    if current_depth >= max_depth:
                        # Don't recurse deeper, but still include this directory
                        dirnames.clear()
                
                # Update count periodically for very large directories
                if total_items % 1000 == 0:
                    sys.stderr.write(f"\rCounting items: {total_items} found so far")
                    sys.stderr.flush()
            
            sys.stderr.write(f"\rCounting complete: {total_items} items found\n")
            sys.stderr.flush()
        except Exception as e:
            debug_log(f"Error counting items: {e}")
            show_progress = False
    
    def update_progress():
        nonlocal processed_items, last_update_time
        processed_items += 1
        
        # Only update the display every update_interval seconds to reduce I/O overhead
        current_time = time.time()
        if show_progress and total_items > 0 and (current_time - last_update_time >= update_interval or processed_items == total_items):
            with progress_lock:
                percent = min(100, int(processed_items * 100 / total_items))
                sys.stderr.write(f"\rProcessing: {percent}% complete ({processed_items}/{total_items})")
                sys.stderr.flush()
                last_update_time = current_time
    
    # For parallel file size calculations
    futures = []
    directories_for_parallel = []
    
    # First pass: collect all directories and files
    all_paths = []
    dir_paths = []
    file_paths = []
    
    for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=follow_symlinks):
        current_depth = dirpath[len(root):].count(os.sep)
        
        # Determine if this directory is whitelisted
        is_whitelisted = False
        if whitelist_patterns:
            rel_path = os.path.relpath(dirpath, root)
            for pattern in whitelist_patterns:
                if match_pattern(rel_path, pattern):
                    is_whitelisted = True
                    break
        
        # Skip deeper directories if beyond max_depth and not whitelisted
        if not is_whitelisted and max_depth is not None and current_depth > max_depth:
            dirnames.clear()  # Don't process subdirectories
            continue
        
        dir_paths.append(dirpath)
        
        # Process files in this directory
        for filename in filenames:
            file_path = os.path.join(dirpath, filename)
            file_paths.append(file_path)
            update_progress()
    
    all_paths = dir_paths + file_paths
    
    # Process files and directories using parallel processing if enabled
    if use_parallel:
        debug_log(f"Processing {len(file_paths)} files and {len(dir_paths)} directories in parallel")
        
        # Process files in parallel batches
        batch_size = 500 if len(file_paths) > 1000 else 100
        file_batches = [file_paths[i:i+batch_size] for i in range(0, len(file_paths), batch_size)]
        
        for batch in file_batches:
            # Submit batch processing tasks with block size calculation
            future = executor.submit(
                lambda b: {
                    path: (os.lstat(path).st_blocks * 512 if os.path.islink(path) and not follow_symlinks 
                           else os.stat(path).st_blocks * 512)
                    for path in b if os.path.exists(path)
                }, 
                batch
            )
            futures.append(future)
        
        # Process results as they complete
        for future in as_completed(futures):
            try:
                batch_results = future.result()
                sizes.update(batch_results)
                update_progress()
            except Exception as e:
                debug_log(f"Error in parallel batch processing: {e}")
        
        # Now calculate directory sizes based on file sizes (bottom-up)
        dir_sizes = {}
        for dirpath in reversed(dir_paths):  # Process from deepest to shallowest
            dir_size = 0
            
            # Sum up immediate children
            try:
                with os.scandir(dirpath) as it:
                    for entry in it:
                        child_path = entry.path
                        if child_path in sizes:
                            dir_size += sizes[child_path]
            except OSError as e:
                debug_log(f"Error scanning directory {dirpath}: {e}")
            
            dir_sizes[dirpath] = dir_size
            sizes[dirpath] = dir_size
            
            # Add this directory's size to parent
            if dirpath != root:
                parent_dir = os.path.dirname(dirpath)
                if parent_dir in dir_sizes:
                    dir_sizes[parent_dir] += dir_size
        
    else:
        # Sequential processing (original approach)
        for dirpath, dirnames, filenames in os.walk(root, topdown=False, followlinks=follow_symlinks):
            current_depth = dirpath[len(root):].count(os.sep)
            update_progress()
            
            # Skip if we've exceeded max depth (but still process whitelisted paths)
            is_whitelisted = False
            if whitelist_patterns:
                rel_path = os.path.relpath(dirpath, root)
                for pattern in whitelist_patterns:
                    if match_pattern(rel_path, pattern):
                        is_whitelisted = True
                        break
            
            if not is_whitelisted and max_depth is not None and current_depth > max_depth:
                continue
            
            # Initialize directory size
            dir_size = 0
            
            # Process files in this directory
            for filename in filenames:
                file_path = os.path.join(dirpath, filename)
                update_progress()
                
                try:
                    # Get file size (symlink or regular file) using block size
                    if os.path.islink(file_path) and not follow_symlinks:
                        file_size = os.lstat(file_path).st_blocks * 512
                    else:
                        file_size = os.stat(file_path).st_blocks * 512
                    
                    # Add file size to directory size
                    dir_size += file_size
                    
                    # Also add this file to our sizes dict if we're at or below max_depth
                    if max_depth is None or current_depth <= max_depth or is_whitelisted:
                        sizes[file_path] = file_size
                        
                except OSError as e:
                    debug_log(f"Error accessing {file_path}: {e}")
            
            # Store the directory's own size
            sizes[dirpath] = dir_size
            
            # Add this directory's size to the parent directory
            if dirpath != root:
                parent_dir = os.path.dirname(dirpath)
                if parent_dir in sizes:
                    sizes[parent_dir] += dir_size
    
    if use_parallel:
        executor.shutdown()
    
    if show_progress:
        sys.stderr.write("\rProcessing: 100% complete                              \n")
        sys.stderr.flush()
    
    return sizes

def filter_paths(
    sizes: Dict[str, int],
    root: str,
    min_size: int = 0,
    cut_size: int = None,
    whitelist_patterns: List[Union[Pattern, str]] = None,
    blacklist_patterns: List[Union[Pattern, str]] = None,
    all_files: bool = False
) -> Dict[str, int]:
    """
    Filter paths based on size and pattern criteria.
    
    Args:
        sizes: Dictionary of path sizes
        root: The root directory
        min_size: Minimum size to include (unless whitelisted)
        cut_size: Final cutoff size (applied after all other filters)
        whitelist_patterns: List of whitelist patterns
        blacklist_patterns: List of blacklist patterns
        all_files: Include all files regardless of size
    
    Returns:
        Filtered dictionary of path sizes
    """
    filtered = {}
    whitelist_matches = set()
    
    # First pass: identify whitelisted paths
    if whitelist_patterns:
        for path in sizes:
            rel_path = os.path.relpath(path, root)
            for pattern in whitelist_patterns:
                if match_pattern(rel_path, pattern):
                    whitelist_matches.add(path)
                    break
    
    # Second pass: apply filters
    for path, size in sizes.items():
        rel_path = os.path.relpath(path, root)
        is_whitelisted = path in whitelist_matches
        
        # Apply whitelist/blacklist filters
        if whitelist_patterns:
            if not is_whitelisted:
                continue
        elif blacklist_patterns:
            excluded = False
            for pattern in blacklist_patterns:
                if match_pattern(rel_path, pattern):
                    excluded = True
                    break
            if excluded:
                continue
        
        # Apply size filters
        if not all_files and not is_whitelisted and size < min_size:
            continue
        
        filtered[path] = size
    
    # Apply cut filter (except for whitelisted paths)
    if cut_size is not None:
        filtered = {
            path: size 
            for path, size in filtered.items() 
            if size >= cut_size or path in whitelist_matches
        }
    
    return filtered

def sort_paths(
    paths: Dict[str, int],
    sort_key: str = 'size',
    reverse: bool = False
) -> List[Tuple[str, int]]:
    """
    Sort paths by the specified key.
    
    Args:
        paths: Dictionary of path sizes
        sort_key: Key to sort by ('size' or 'name')
        reverse: Whether to sort in reverse order
    
    Returns:
        List of (path, size) tuples sorted according to criteria
    """
    if sort_key == 'name':
        return sorted(paths.items(), key=lambda x: x[0], reverse=reverse)
    else:  # 'size'
        return sorted(paths.items(), key=lambda x: x[1], reverse=reverse)

def format_path(path: str, root: str, format_type: str = 'absolute') -> str:
    """
    Format a path according to the specified format type.
    
    Args:
        path: The path to format
        root: The root directory
        format_type: One of 'absolute', 'relative', or 'basename'
    
    Returns:
        The formatted path
    """
    if format_type == 'absolute':
        return path
    elif format_type == 'relative':
        return os.path.relpath(path, root)
    elif format_type == 'basename':
        return os.path.basename(path)
    else:
        return path  # Default to absolute path

def build_tree_output(sorted_paths: List[Tuple[str, int]], root: str) -> List[str]:
    """
    Build tree-style output showing directory hierarchy.
    
    Args:
        sorted_paths: List of (path, size) tuples
        root: The root directory
    
    Returns:
        List of formatted output lines
    """
    output = []
    path_depths = {}
    
    # First pass: calculate depths and parent-child relationships
    tree = defaultdict(list)
    for path, size in sorted_paths:
        rel_path = os.path.relpath(path, root)
        if rel_path == '.':
            parts = []
        else:
            parts = Path(rel_path).parts
        depth = len(parts)
        path_depths[path] = depth
        
        if depth > 0:
            parent = os.path.dirname(path)
            tree[parent].append(path)
    
    # Second pass: generate output with proper indentation
    for path, size in sorted_paths:
        depth = path_depths[path]
        indent = TREE_INDENT * depth
        formatted_size = format_size(size)
        
        # Align sizes in a fixed-width column
        size_field = formatted_size.ljust(SIZE_COLUMN_WIDTH)
        
        # Get path name based on depth
        if path == root:
            path_name = os.path.basename(path)
        else:
            path_name = os.path.basename(path)
            
        output_line = f"{indent}{size_field}  {path_name}"
        output.append(output_line)
    
    return output

def parse_args(args=None):
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description='Analyze disk usage with flexible filtering and sorting options.',
        add_help=False
    )
    
    # Target directory (positional)
    parser.add_argument(
        'target',
        nargs='?',
        default='.',
        help='Target directory to analyze (default: current directory)'
    )
    
    # Traversal options
    parser.add_argument(
        '-l', '--level',
        type=int,
        default=DEFAULT_LEVEL,
        help=f'Maximum recursion depth (default: {DEFAULT_LEVEL})'
    )
    parser.add_argument(
        '-x', '--one-file-system',
        action='store_true',
        default=DEFAULT_ONE_FS,
        help='Stay on one filesystem (default: False)'
    )
    parser.add_argument(
        '-L', '--dereference',
        action='store_true',
        default=DEFAULT_DEREFERENCE,
        help='Follow symbolic links (default: False)'
    )
    
    # Size filtering
    parser.add_argument(
        '-m', '--min-size',
        default=DEFAULT_MIN_SIZE,
        help=f'Minimum size threshold (default: {DEFAULT_MIN_SIZE})'
    )
    parser.add_argument(
        '-a', '--all',
        action='store_true',
        help='Include all files regardless of size (still respects --cut)'
    )
    parser.add_argument(
        '-c', '--cut',
        help='Final cutoff size (applied after sorting, whitelisted paths exempt)'
    )
    
    # Pattern filtering
    parser.add_argument(
        '-w', '--whitelist',
        help='Comma-separated whitelist patterns (overrides blacklists)'
    )
    parser.add_argument(
        '--whitelist-file',
        help='File containing whitelist patterns (one per line)'
    )
    parser.add_argument(
        '-b', '--blacklist',
        help='Comma-separated blacklist patterns'
    )
    parser.add_argument(
        '--blacklist-file',
        help='File containing blacklist patterns (one per line)'
    )
    
    # Sorting
    parser.add_argument(
        '-s', '--sort',
        choices=['size', 'name'],
        default=DEFAULT_SORT_KEY,
        help=f'Sort key (size or name) (default: {DEFAULT_SORT_KEY})'
    )
    parser.add_argument(
        '-r', '--reverse',
        action='store_true',
        default=DEFAULT_SORT_REVERSE,
        help='Reverse sort order (default: False)'
    )
    
    # Output
    parser.add_argument(
        '-t', '--tree',
        action='store_true',
        default=DEFAULT_TREE_VIEW,
        help='Display results in tree format (default: False)'
    )
    parser.add_argument(
        '-f', '--format',
        choices=['absolute', 'relative', 'basename'],
        default=PATH_FORMAT,
        help='Path format in output (default: relative)'
    )
    
    # Debug and Performance options
    parser.add_argument(
        '-d', '--debug',
        action='store_true',
        help='Enable debug logging'
    )
    parser.add_argument(
        '-p', '--progress',
        action='store_true',
        help='Show progress indicator'
    )
    parser.add_argument(
        '--parallel',
        action='store_true',
        help='Enable parallel processing for better performance'
    )
    parser.add_argument(
        '--workers',
        type=int,
        help='Number of worker threads for parallel processing (default: CPU count + 4)'
    )
    
    # Help
    parser.add_argument(
        '-h', '--help',
        action='help',
        help='Show this help message and exit'
    )
    
    return parser.parse_args(args)

def validate_args(args):
    """Validate command line arguments."""
    # Set debug mode from args
    global DEBUG
    if args.debug:
        DEBUG = True

    # Validate level
    if args.level < 0:
        raise DiskAnalyzerError("Level must be a non-negative integer")
    
    # Validate sizes
    try:
        args.min_size_bytes = parse_size(args.min_size)
    except SizeFormatError as e:
        raise DiskAnalyzerError(f"Invalid min-size format: {e}")
    
    if args.cut:
        try:
            args.cut_size = parse_size(args.cut)
        except SizeFormatError as e:
            raise DiskAnalyzerError(f"Invalid cut-size format: {e}")
    else:
        args.cut_size = None
    
    # Validate target directory
    if not os.path.exists(args.target):
        raise DiskAnalyzerError(f"Target directory does not exist: {args.target}")
    if not os.path.isdir(args.target):
        raise DiskAnalyzerError(f"Target is not a directory: {args.target}")
    
    # Convert target to absolute path
    args.target = os.path.abspath(args.target)
    
    # Load pattern files
    args.whitelist_patterns = []
    args.blacklist_patterns = []
    
    # Process whitelist patterns
    if args.whitelist:
        args.whitelist_patterns.extend(p.strip() for p in args.whitelist.split(','))
    
    if args.whitelist_file:
        try:
            args.whitelist_patterns.extend(load_pattern_file(args.whitelist_file))
        except DiskAnalyzerError as e:
            raise DiskAnalyzerError(f"Error loading whitelist file: {e}")
    
    # Check for whitelist pattern files if no patterns specified
    if not args.whitelist_patterns:
        for pattern_file in find_pattern_files(args.target, '.disk_analyzer_include'):
            try:
                args.whitelist_patterns.extend(load_pattern_file(pattern_file))
            except DiskAnalyzerError as e:
                debug_log(f"Error loading whitelist file {pattern_file}: {e}")
    
    # Process blacklist patterns (only if no whitelist patterns)
    if not args.whitelist_patterns:
        if args.blacklist:
            args.blacklist_patterns.extend(p.strip() for p in args.blacklist.split(','))
        
        if args.blacklist_file:
            try:
                args.blacklist_patterns.extend(load_pattern_file(args.blacklist_file))
            except DiskAnalyzerError as e:
                raise DiskAnalyzerError(f"Error loading blacklist file: {e}")
        
        # Check for blacklist pattern files if no patterns specified
        if not args.blacklist_patterns:
            for pattern_file in find_pattern_files(args.target, '.disk_analyzer_ignore'):
                try:
                    args.blacklist_patterns.extend(load_pattern_file(pattern_file))
                except DiskAnalyzerError as e:
                    debug_log(f"Error loading blacklist file {pattern_file}: {e}")
    
    # Compile patterns
    try:
        args.whitelist_patterns = [compile_pattern(p) for p in args.whitelist_patterns]
        args.blacklist_patterns = [compile_pattern(p) for p in args.blacklist_patterns]
    except PatternError as e:
        raise DiskAnalyzerError(f"Invalid pattern: {e}")
    
    # Validate whitelist paths are within target directory
    valid_whitelist_patterns = []
    for pattern in args.whitelist_patterns:
        if isinstance(pattern, str) and pattern.startswith('/'):
            # Absolute path pattern - check if it's within target directory
            abs_pattern = os.path.abspath(pattern)
            if not abs_pattern.startswith(args.target + os.sep):
                print(
                    f"Warning: Whitelist path '{pattern}' is outside the target directory; "
                    f"ignoring whitelist entry.",
                    file=sys.stderr
                )
                continue
        valid_whitelist_patterns.append(pattern)
    args.whitelist_patterns = valid_whitelist_patterns
    
    return args

def main():
    """Main entry point for the disk analyzer."""
    try:
        # Parse and validate arguments
        args = parse_args()
        try:
            args = validate_args(args)
        except DiskAnalyzerError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(EXIT_ARG_ERROR)
        
        debug_log(f"Starting analysis of {args.target} with options: {vars(args)}")
        
        # Traverse directory and collect sizes
        try:
            # Add a note about size calculation method if debug is enabled
            if args.debug:
                debug_log("Using st_blocks * 512 to calculate sizes (matches 'du' behavior)")
                
            sizes = walk_directory(
                root=args.target,
                max_depth=args.level,
                follow_symlinks=args.dereference,
                one_filesystem=args.one_file_system,
                whitelist_patterns=args.whitelist_patterns,
                min_size=args.min_size_bytes,
                all_files=args.all,
                show_progress=args.progress,
                use_parallel=args.parallel,
                max_workers=args.workers
            )
        except TraversalError as e:
            print(f"Error during traversal: {e}", file=sys.stderr)
            sys.exit(EXIT_IO_ERROR)
        
        if not sizes:
            print("No matching files found.", file=sys.stderr)
            sys.exit(EXIT_IO_ERROR)
        
        # Filter paths
        if args.progress:
            print("Filtering results...", file=sys.stderr)
            
        filtered_sizes = filter_paths(
            sizes=sizes,
            root=args.target,
            min_size=args.min_size_bytes,
            cut_size=args.cut_size,
            whitelist_patterns=args.whitelist_patterns,
            blacklist_patterns=args.blacklist_patterns,
            all_files=args.all
        )
        
        if not filtered_sizes:
            print("No files matched the specified criteria.", file=sys.stderr)
            sys.exit(EXIT_SUCCESS)
        
        # Sort paths
        if args.progress:
            print("Sorting results...", file=sys.stderr)
            
        sorted_paths = sort_paths(
            filtered_sizes,
            sort_key=args.sort,
            reverse=args.reverse
        )
        
        # Generate output
        if args.tree:
            output_lines = build_tree_output(sorted_paths, args.target)
        else:
            output_lines = []
            for path, size in sorted_paths:
                formatted_size = format_size(size)
                formatted_path = format_path(path, args.target, args.format)
                
                # Align sizes in a fixed-width column for better readability
                size_field = formatted_size.ljust(SIZE_COLUMN_WIDTH)
                output_lines.append(f"{size_field}  {formatted_path}")
        
        # Print results
        print('\n'.join(output_lines))
        
        sys.exit(EXIT_SUCCESS)
    
    except KeyboardInterrupt:
        print("\nOperation cancelled by user.", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        if DEBUG:
            import traceback
            traceback.print_exc()
        sys.exit(1)

if __name__ == '__main__':
    main()