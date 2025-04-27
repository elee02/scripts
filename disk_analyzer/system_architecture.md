# System Architecture of `disk_analyzer.sh`

## Introduction

`disk_analyzer.sh` is architected as a high-fidelity, depth-aware analysis utility implemented in POSIX-compliant Bash. It is designed to provide practitioners with comprehensive insights into filesystem utilization by enabling precise control over recursion depth, size thresholds, sorting preferences, and pattern-based inclusion/exclusion rules. By integrating modular subsystems for argument parsing, traversal, caching, filtration, ordering, and rendering, the script achieves a balance of extensibility, performance, and maintainability.

## Architectural Philosophy

The fundamental design principle of `disk_analyzer.sh` is to build upon stable, well-tested system utilities rather than reinventing functionality at a lower level. This approach maximizes reliability, performance, and compatibility across different environments. Specifically:

1. **Leverage System Tools:** Wherever possible, the script delegates complex operations to mature system tools (`du`, `find`, `sort`, etc.) that have been optimized and battle-tested over decades.

2. **Minimize Reimplementation:** Low-level functionality is only reimplemented when doing so provides significant efficiency gains or when the required behavior cannot be achieved using existing tools.

3. **Tool Selection Criteria:** System tools are selected based on:
   - Performance characteristics (CPU, memory, and I/O efficiency)
   - POSIX compliance and availability across target platforms
   - Robust error handling and edge case management
   - Consistent behavior across different system configurations

This philosophy enables the script to benefit from the optimizations built into system utilities while focusing development effort on the unique value-add of the tool: sophisticated filtering, pattern management, and result presentation.

## Architectural Overview

The architecture is organized into layered modules, each encapsulating a discrete concern. This separation of responsibilities supports independent evolution of features, simplifies testing, and enables plug-in extensions. The data and control flow between modules follows a deterministic pipeline, ensuring predictable resource usage even in large-scale directory hierarchies.

## Core Modules and Subsystems

### 1. CLI Argument Parsing
- **Responsibilities:** Interpret, validate, and normalize user-supplied flags and positional arguments.
- **Key Flags:** `--level`, `--min-size`, `--all`, `--sort`, `--reverse`, `--cut`, `--whitelist`, `--blacklist`, `--whitelist-file`, `--blacklist-file`, `--one-file-system` (`-x`), `--dereference` (`-L`).
- **Implementation Details:** Leverage a hybrid `getopts` and `while/case` loop. Perform syntactic validation (numeric checks, valid sort keys, valid size formats like `10M`, `2G`). Semantic validation ensures conflicting options are handled according to precedence rules (e.g., `--all` overrides `--min-size` during traversal). Combining short options requiring arguments (e.g., `-l`, `-m`, `-s`, `-c`, `-w`, `-b`) is **not supported** due to `getopts` limitations and will cause parsing errors. Each option must be specified separately. Options like `-x` and `-L` (if added as short flags without arguments) could potentially be combined with others *not* requiring arguments, but the current implementation requires separate specification for clarity and consistency.
- **Error Handling:** On detection of invalid arguments (e.g., bad size format `1X`, non-numeric level) or unsupported combinations, emit a concise usage synopsis and exit code `1`.

### 2. Configuration and Pattern Management
- **Responsibilities:** Load and reconcile whitelist (`.disk_analyzer_include`) and blacklist (`.disk_analyzer_ignore`) patterns.
- **Precedence Logic:** Whitelists (if present) override all blacklist directives. In their absence, blacklist patterns exclude matching paths. This applies even in nested scenarios (e.g., whitelist `/data` overrides blacklist `/data/tmp`).
- **File Discovery:** Search default locations and explicit paths.
- **Pattern Syntax:** Primarily handles **Bash-style glob patterns**. If a pattern starts with `regex:`, it's treated as an ERE (Extended Regular Expression) and matched using appropriate tools (e.g., `grep -E`).
- **Pattern Matching Rules:** Patterns can be:
  1. Absolute paths (starting with `/`) - matched against absolute file paths
  2. Relative paths (not starting with `/`) - matched against paths relative to target
  3. Simple path components - matched anywhere in the path
- **Cascading Pattern Files:** When both local and home directory pattern files exist:
  1. Files are merged, with local patterns taking precedence
  2. Duplicate patterns are deduplicated (first occurrence wins)
  3. Comments (lines starting with `#`) are stripped

### 3. Whitelist vs Target Path Conflict

1. For each whitelist path:
   - If it is not a subdirectory of the target directory, log:
     "Whitelist path `<whitelist>` is outside the target `<target>`; ignoring whitelist entry."
     and skip it.
   - Otherwise include it in the scan.
2. Continue scanning within the target directory plus any valid (in‑scope) whitelist entries.
3. Blacklist paths outside the target directory are silently ignored (since they can't match anything).
4. If a whitelist pattern partially overlaps with the target directory (e.g., target is `/data` and whitelist is `/data2/foo`), the whitelist path is considered out-of-scope and will be ignored with a warning.
5. Only paths that are actual subpaths of the target directory are considered valid for whitelisting.

### 4. Filesystem Traversal Engine
- **Responsibilities:** Enumerate filesystem nodes up to `LEVEL`, respecting mount point (`-x`) and symlink (`-L`) options.
- **Mechanisms:** Likely uses `find` for efficiency and robustness.
  - `find <path> [options] -maxdepth $LEVEL ...`
  - A `--level` of 0 restricts the analysis to only the target directory itself, with no descent into subdirectories.
  - **Symlink Handling:** Default is *not* to follow symlinks (`find`'s default). If `-L` or `--dereference` is specified, `find -L` is used.
  - **Mount Point Handling:** Default is to cross mount points. If `-x` or `--one-file-system` is specified, `find -xdev` (or equivalent logic) is used.
  - **Option Precedence:** When both `-x` and `-L` are specified, and a symlink points to another filesystem, `-x` takes precedence (the link will not be followed).
- **Pruning Logic:** When `--all` is not enabled, may halt descent into subdirectories whose parent size (obtained early via a preliminary `du` or similar) falls below `--min-size`, unless the path matches a whitelist pattern.
- **Whitelist and Depth Interaction:** Whitelisted paths are always processed regardless of the `--level` setting. The traversal engine will:
  1. First gather all paths up to the specified `--level`
  2. Then add any whitelisted paths that may be deeper than `--level`
  3. Report both:
     - The parent directory (up to the specified `--level`) with its size
     - The whitelisted path at its actual depth with its size

### 5. Size Computation and Cache Layer
- **Responsibilities:** Compute accurate sizes using `du`.
- **Caching Strategy:** May use an in-memory associative array keyed by absolute path to store `du` results.
- **`du` Invocation:**
  - Uses `du -b` (apparent size in bytes) or `du -sb` (block usage in bytes). `-b` is often preferred for consistency.
  - **Symlink Handling:** Uses `du` (no follow), `du -L` (follow all), or `du -H` (follow command-line symlinks) based on the `-L` flag matching the traversal engine's behavior. Default is no-follow.
  - **Mount Point Handling:** Uses `du` (crosses mounts) or `du -x` (stays on one filesystem) based on the `-x` flag. Default is to cross.
  - **Hard Links:** `du` counts the size contribution of a hard-linked file each time one of its links is encountered.
  - **Special Files:** `du` typically reports size 0 for device files, sockets, etc.
- **Performance Optimizations:** Batching or parallelizing `du` calls might be implemented.
- **Symlink Loop Detection:**
  1. Maintain a tracking associative array of visited inodes (device_id:inode combination)
  2. Before processing any file/directory, check if its inode is already in the visited set
  3. If a loop is detected, skip the path and log a warning
  4. This prevents infinite recursion when following symbolic links with `-L`

### 6. Quantitative and Qualitative Filtering
- **Responsibilities:** Apply numeric thresholds (`--min-size`, `--cut`) and pattern-based inclusion/exclusion.
- **Size Parsing:** Interpret suffixes (`K`, `M`, `G`, etc., case-insensitive, powers of 1024) and convert to bytes. Handles potential errors from invalid formats during argument parsing.
- **Pattern Matching:** Uses Bash-style glob matching (e.g., Bash `[[ $path == $pattern ]]`) or `grep -E` for `regex:` patterns.
  1. **Whitelist Application:** If whitelists exist, paths *must* match a whitelist pattern.
  2. **Blacklist Enforcement:** If no whitelists exist, paths matching a blacklist pattern are excluded.
- **Filtering Pass:** Iterates through collected path/size data.
- **Min-Size Filter:** Applied *during* traversal (pruning) for directories that are not whitelisted. If `--all` is set, this filter is disabled during traversal.
- **Cut Filter:** Applied *after* all data is collected and sorted, removing final entries below the threshold. The `--cut` filter is **always applied**, even when `--all` is specified. **Important:** Whitelisted paths are exempt from the `--cut` filter and will always be shown regardless of size.

### 7. Sorting and Ordering
- **Responsibilities:** Order the filtered result set.
- **Implementation:** Pipes filtered lines into `sort -h` (human-numeric sort). Uses `-r` flag when `--reverse` is specified.
- **Option Interaction:** By default, sort is by size in ascending order (smallest to largest). If `-r` or `--reverse` is specified, sort is in descending order (largest to smallest).
- **Sort Keys:** Currently supports sorting by size. Future implementations may support:
  * `-s name` for sorting by path name (alphabetically)
  * Only one sort key can be active at a time, with `-r` applying to the selected key

### 8. Output Rendering and Visualization
- **Responsibilities:** Present the final, sorted list in a concise, human-readable format, with optional hierarchical tree structures.
- **Default Mode:** Emit lines in the form `<size>	<path>`, where size uses the most appropriate unit.
- **Extended Mode (`--tree`):** Render tree-like indentation showing directory nesting, aggregating sizes for deeper levels beyond `--level`.
- **Error Handling:** 
  * Non-critical errors produce warnings on stderr but allow processing to continue
  * Warnings include: permission denied errors, IO errors during traversal, symlink loop detection
  * Critical errors (invalid arguments, inaccessible target directory) cause termination with appropriate exit code
  * The script will only exit with code 3 (I/O error) if all paths fail; partial failures will produce warnings but allow the script to continue

### Presentation Layer

Responsible for formatting and emitting the scan results.

- Support for tree‑style rendering via `-t` / `--tree`, which prints the directory hierarchy with indentation by depth. This flag purely affects presentation and may be used alongside any filtering, sorting, or traversal options without conflict.

## Implementation Details Using `du` and `tree`

The `disk_analyzer.sh` script leverages the following Unix/Linux command-line tools to implement its core functionality:

1. **`du` (Disk Usage):**
   - Primary tool for calculating directory and file sizes.
   - Supports depth-limited traversal with the `--max-depth` option.
   - Example: `du -h --max-depth=2 /path/to/dir` calculates sizes up to 2 levels deep.

2. **`tree` (Directory Tree Visualization):**
   - Used for rendering hierarchical directory structures.
   - Example: `tree -L 2 /path/to/dir` limits the tree depth to 2 levels.

3. **`find` (Filesystem Traversal):**
   - Used for locating files and directories based on criteria like size, name, and depth.
   - Example: `find /path/to/dir -maxdepth 2 -type d` lists directories up to depth 2.

4. **`sort` (Sorting):**
   - Used to sort output by size, name, or other criteria.
   - Example: `sort -h` sorts human-readable sizes in ascending order.

5. **`awk` and `xargs` (Stream Processing):**
   - `awk` is used for filtering and processing text output.
   - `xargs` is used to build and execute commands from input streams.

### Integration Workflow

1. **Filesystem Traversal:**
   - Use `find` to traverse directories and apply filters (e.g., depth, size).
   - Example: `find /path/to/dir -maxdepth 2 -type d -size +10M`.

2. **Size Calculation:**
   - Use `du` to calculate sizes for directories and files.
   - Example: `du -h --max-depth=2 /path/to/dir`.

3. **Sorting and Filtering:**
   - Use `sort` and `awk` to sort and filter results.
   - Example: `du -h --max-depth=2 /path/to/dir | sort -h | awk '$1 > 10 {print $0}'`.

4. **Tree Rendering:**
   - Use `tree` for a visual representation of the directory structure.
   - Example: `tree -L 2 /path/to/dir`.

5. **Pattern Matching:**
   - Use `grep` or `awk` to apply whitelist and blacklist patterns.
   - Example: `du -h --max-depth=2 /path/to/dir | grep -E 'pattern'`.

### Example Command Combinations

- **Basic Size Analysis:**
  ```bash
  du -h --max-depth=2 /path/to/dir | sort -h
  ```

- **Filtered Analysis:**
  ```bash
  find /path/to/dir -type d -size +10M | xargs du -h | sort -h
  ```

- **Tree Visualization:**
  ```bash
  tree -L 2 /path/to/dir
  ```

These tools provide a robust foundation for implementing the features described in the `disk_analyzer.sh` script, ensuring compatibility, performance, and maintainability.

## Detailed Operational Workflow

1. **Bootstrap & Defaults:** Initialize parameters to defaults (`LEVEL=1`, `MIN_SIZE_BYTES=1048576`, `SORT=size`, `REVERSE=false`, etc.).
2. **Argument Ingestion:** Parse CLI inputs; perform cross-flag validation (e.g., disallow negative levels, enforce numeric sizes).
3. **Configuration Load:** Source pattern files/arguments. Determine pattern types (glob/regex).
4. **Pattern Processing:**
   - Validate whitelist entries against target directory
   - Parse patterns and identify which should be applied as Bash glob patterns vs. regex patterns
5. **Initial Traversal:** Generate candidate paths using `find` (or similar) respecting `LEVEL`, `-x`, `-L`.
   - Extend traversal beyond `LEVEL` for whitelisted paths
   - Implement loop detection for symlinks when `-L` is used
6. **Size Evaluation & Caching:** For each candidate, run `du` (respecting `-x`, `-L`) or retrieve cached size. Handle I/O errors gracefully (log, skip).
7. **Filtering:** 
   - Apply whitelist/blacklist logic according to precedence rules
   - Apply `--min-size` (if not `--all`)
   - Apply `--cut` threshold (always, regardless of `--all`, but exempting whitelisted paths)
8. **Sorting:** Feed surviving entries into `sort` with appropriate options based on sort key and direction.
9. **Final Presentation:** Format and output each entry; exit with code `0` unless all paths failed (exit code `3`).

## Performance, Scalability, and Robustness

- **Concurrency Controls:** Optional `--jobs` flag to parallelize `du` calls, with default single-threaded mode to preserve predictability.
- **I/O Error Handling:** Detect unreadable/inaccessible paths during traversal (`find`) or size calculation (`du`). Log errors to STDERR. Skip the problematic path and continue processing others. Exit with code `3` only if all paths fail.
- **Resource Throttling:** Consider adding `--timeout`.
- **Memory Footprint:** Retain minimal in-memory structures; flush cache entries for deep levels beyond three to regulate shell memory usage.

## Security and Compliance Considerations

- **Privilege Separation:** Encourage invocation under a non-root user; only escalate via `sudo` for restricted directories.
- **Injection Mitigation:** Sanitize all pattern inputs and carefully quote variables to prevent command injection.
- **Auditability:** Optionally log accessed paths and actions to an audit file for forensic analysis.

## Extensibility and Future Directions

- **Plugin Hooks:** Define callback points (`pre_traverse`, `post_filter`, `on_render`) to allow third-party scripts to augment behavior.
- **Structured Exports:** Implement JSON, YAML, or CSV output modes for downstream processing and integration with monitoring systems.
- **GUI Frontend:** Prototype a minimal curses-based TUI for interactive exploration, leveraging the same core modules.

## Deployment and Repository Layout

```
~/scripts/
├── disk_analyzer.sh              # Core executable
├── .disk_analyzer_ignore         # Default blacklist patterns
├── .disk_analyzer_include        # Default whitelist patterns
└── lib/                          # Potential plugin directory
```

*End of System Architecture Document.*

