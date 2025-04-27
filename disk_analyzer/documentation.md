# `disk_analyzer.sh` Documentation

## Abstract

`disk_analyzer.sh` represents a meticulously engineered Bash-based analytic framework for the systematic quantification and interrogation of file system utilization. By orchestrating depth-limited traversal, parametrized size thresholds, bi-directional sorting, and pattern-driven inclusion/exclusion schemas, the utility affords practitioners the capacity to perform both macroscopic audits and granular forensics of storage hierarchies. Its design reflects principles of modularity, reproducibility, and performance determinism.

## Design Philosophy

The script is deliberately built on top of stable, well-established system utilities rather than reimplementing functionality at low levels. This architectural choice:

1. **Maximizes Performance:** Leverages decades of optimization in tools like `du`, `find`, and `sort`
2. **Ensures Reliability:** Benefits from the extensive testing and robustness of core system utilities
3. **Maintains Compatibility:** Works across various Unix-like environments without custom dependencies
4. **Simplifies Maintenance:** Reduces the codebase complexity by delegating complex operations to specialized tools

The script only implements custom logic when it provides significant value beyond what the system tools offer or when seamlessly integrating the output of multiple tools.

## System Prerequisites

- **Shell Environment:** A POSIX-compliant shell, with Bash version 4.0 or later recommended to ensure compatibility with associative arrays and advanced string manipulation primitives.
- **Core Dependencies:** GNU `du` for size aggregation, `find` for filesystem traversal, `sort` for ordering results, `awk` and `xargs` for stream processing, and `printf` for formatted output. All utilities should conform to standard coreutils behavior.
- **Privileges:** Read permissions on target mount points; usage of `sudo` is advised when traversing protected system directories (e.g., `/var`, `/usr`).

## Deployment Procedure

1. **Acquisition:** Retrieve the script into a user-controlled directory:
   ```bash
   mkdir -p "$HOME/scripts" && \
   curl -fsSL https://example.com/disk_analyzer.sh -o "$HOME/scripts/disk_analyzer.sh"
   ```
2. **Permission Configuration:** Grant execution bit to the script:
   ```bash
   chmod 755 "$HOME/scripts/disk_analyzer.sh"
   ```
3. **Path Integration (Optional):** Append to the user’s `PATH` for global invocation:
   ```bash
   echo 'export PATH="$HOME/scripts:$PATH"' >> ~/.bashrc && source ~/.bashrc
   ```

## Invocation Semantics

```bash
disk_analyzer.sh [OPTIONS] [TARGET_DIRECTORY]
```
- **TARGET_DIRECTORY:** Defines the root of the scan. Defaults to the current working directory if unspecified.

## Command-Line Interface

| Option                            | Semantics                                                                                                                                              | Default    |
|-----------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|------------|
| `-l`, `--level <DEPTH>`           | Specifies the maximum recursion depth, beyond which directory aggregates are collapsed into their parent nodes, preserving hierarchical abstraction. Whitelist entries will override this limit for specific paths (see "Filter and Option Precedence"). A `--level` value of 0 restricts analysis to the target directory with no descent.    | `1`        |
| `-m`, `--min-size <SIZE>`         | Establishes a lower bound for aggregated directory size at the specified depth: subdirectories whose total size (sum of all contents at that level) fall below this threshold are omitted unless `--all` is asserted. | `1M`       |
| `-a`, `--all`                     | Supersedes `--min-size`, compelling exhaustive traversal up to the specified recursion level, irrespective of size constraints. Does not override the post-sort `--cut` filter.                          | `false`    |
| `-s`, `--sort <size|name>`        | Determines primary sort order of the output. Sorting is by size by default.                                                   | `size`      |
| `-r`, `--reverse`                 | Inverts the sort order. By default, sorting is ascending (smallest to largest for size). With `-r`, sorting is descending (largest to smallest for size).                                                                                | `false`    |
| `-c`, `--cut <SIZE>`              | Excises final output entries whose aggregated directory size at the specified depth falls below the cutoff, after all other filters and aggregations. This filter is always applied, even when `--all` is specified. **Important:** Whitelisted paths are exempt from this cutoff and will always be displayed regardless of size.                 | —          |
| `-w`, `--whitelist <PATTERNS>`    | Delineates inclusion patterns (glob or regex) that override all exclusion parameters, enforcing a positive selection policy. Patterns can be absolute paths, relative to target directory, or simple path components (see "Pattern Matching Rules").                              | —          |
| `--whitelist-file <FILE>`         | References a file containing newline-delimited whitelist patterns; supports inline comments prefixed with `#`.                                           | —          |
| `-b`, `--blacklist <PATTERNS>`    | Enumerates exclusion patterns to be applied when no whitelist is active, supporting fine-grained negative filtration.                                     | —          |
| `--blacklist-file <FILE>`         | Points to a file of blacklist entries, one per line, with comment support.                                                                              | —          |
| `-h`, `--help`                    | Emits comprehensive usage text and terminates execution.                                                                                                | —          |
| `-t`, `--tree`                    | Renders the output in a tree‑like structure, indenting subdirectories to reflect hierarchy.                                                              | false      |
| `-x`, `--one-file-system`         | Prevents traversal across filesystem mount points, even when symlinks are followed with `-L`. This takes precedence over `-L` when a symlink target is on another filesystem.                                                                                                       | false      |
| `-L`, `--dereference`             | Follow all symbolic links encountered during traversal. Default behavior is to *not* follow symbolic links. When combined with `-x`, the script will not follow links to other filesystems.                                              | false      |

**Note on Option Parsing:**
- Short options **cannot** be combined (e.g., `-la` is invalid; use `-l <DEPTH> -a`).
- Options requiring arguments must have their arguments provided immediately (e.g., `-s name`, `-m 5M`). Combining flags like `-sarc` is invalid. Use separate flags like `-s size -a -r -c 1M`.

### Filter and Option Precedence

Understanding the order of operations is crucial when combining options:

1.  **Path Selection (Whitelist/Blacklist):**
    *   If any whitelist pattern (`-w`, `--whitelist`, `--whitelist-file`, `.disk_analyzer_include`) is active, **only** paths matching the whitelist are considered. Blacklists are ignored.
    *   If **no** whitelist is active, blacklist patterns (`-b`, `--blacklist`, `--blacklist-file`, `.disk_analyzer_ignore`) are applied first to exclude paths.
    *   **Nested Conflict Example:** If `/data` is whitelisted and `/data/tmp` is blacklisted, `/data/tmp` **will be included** because the whitelist takes absolute precedence. If only the blacklist `/data/tmp` exists, it will be excluded.
    *   **Whitelist and Depth Interaction:** Whitelisted paths are **always processed regardless of the `--level` setting**. If a path `/data/archive/old` is whitelisted but `--level` is set to 1, the whitelisted path will still be included in the output at its true depth. Both the parent directory (up to level 1) and the whitelisted path will be shown with their respective sizes.

2.  **Traversal Constraints:**
    *   `--level <DEPTH>` limits the recursion depth for non-whitelisted paths. A level of 0 means only the target directory itself, with no descent into subdirectories.
    *   `--one-file-system` (`-x`) prevents crossing mount points, even when following symbolic links with `-L`.
    *   `--dereference` (`-L`) controls symbolic link following. By default, symlinks are *not* followed. The script implements loop detection to prevent infinite recursion when following symbolic links.
    *   **Precedence:** When both `-x` and `-L` are specified, and a symbolic link points to another filesystem, `-x` takes precedence and the link will not be followed.

3.  **Initial Size Filtering (`--min-size` / `--all`):**
    *   If `--all` is **not** used, directories whose aggregated size at the specified depth falls below `--min-size` are pruned *during* traversal (unless whitelisted).
    *   If `--all` **is** used, `--min-size` is ignored during traversal.

4.  **Sorting (`--sort`, `--reverse`):**
    *   The results are sorted by size by default, in ascending order (smallest to largest).
    *   `--reverse` inverts the sort order to descending (largest to smallest).
    *   If `-s name` is specified, sorting is by name instead of size, and `-r` will reverse the alphabetical order.

5.  **Final Cut-Off (`--cut`):**
    *   Applied *after* sorting, removing entries whose aggregated size is below the `--cut` threshold.
    *   **Note:** `--cut` is always applied, even when `--all` is specified.
    *   **Important:** Whitelisted paths are *exempt* from the `--cut` filter and will always be shown in the output regardless of size.

### Pattern Matching Rules

Patterns for whitelist and blacklist can be specified in three forms:

1. **Absolute paths:** Starting with `/` (e.g., `/var/log/apache2`)
   * Matches exactly against the absolute path of files/directories

2. **Relative paths:** Not starting with `/` (e.g., `log/apache2`)
   * Matches against the path relative to the target directory
   * Path components can include glob patterns (e.g., `*.log`)

3. **Simple path components:** (e.g., `*.tmp`, `cache`)
   * Matches any path that contains that component
   * Equivalent to `**/component/**` in glob syntax

Patterns are treated as **Bash-style glob patterns** by default (supporting `*`, `?`, `[...]`, etc.). This provides an intuitive and developer-friendly syntax. To use extended regular expressions, prefix the pattern with `regex:`.

### Whitelist vs Target Path Conflict

If a whitelist entry falls outside the specified target directory, the script will:
- Log a warning:  
  "Whitelist path `<whitelist>` is outside the target directory `<target>`; ignoring whitelist entry."
- Continue scanning only within the target directory, skipping any out‑of‑scope whitelist.

If a whitelist pattern partially overlaps with the target directory (e.g., target is `/data` and whitelist is `/data2/foo`), the whitelist path is considered out-of-scope and will be ignored with a warning.

Only paths that are actual subpaths of the target directory are considered valid for whitelisting.

If a blacklist entry falls outside the target directory, it will be silently ignored since it cannot affect the results anyway.

## Pattern File Formalism

- **Default Locations:** `.disk_analyzer_include` (whitelist) and `.disk_analyzer_ignore` (blacklist) are consulted within the target directory, cascading to the user's home directory if not found locally.
- **Cascading Behavior:** 
  * When both local and home directory pattern files exist, they are merged, with local patterns processed first.
  * Duplicate patterns are de-duplicated, with the first occurrence (from the local file) taking effect.
- **Syntax:** One discrete pattern per line; lines commencing with `#` are interpreted as comments and ignored. Patterns are treated as **glob patterns** by default. To use extended regular expressions, prefix the pattern with `regex:`.
  ```text
  # Glob Examples
  */cache/**
  *.log

  # Regex Example (match paths ending in digits)
  regex:.*[0-9]$
  ```

## Output Conventions

- Each output record composes a human-readable size token, a tab delimiter, and the associated path.
- Directory nodes at the maximal recursion depth are presented as aggregate entries to preserve hierarchical summarization.
- Whitelisted paths are shown at their true depth, along with their parent directories up to the `--level` setting.
- **Sample Excerpt:**
  ```text
  1.2G	/var/log
  600M	/var/log/apache2
   80M	/var/log/nginx
  ```
- If `--tree` is specified, results are displayed as a hierarchical tree with indentation corresponding to directory depth, respecting all filters and sort options.

## Exemplars of Application

1. **Macro-Level Audit** (depth = 2; minimum = 5M; descending sort):
   ```bash
   disk_analyzer.sh -l 2 -m 5M -r /var
   ```
2. **Exhaustive Forensic Drill** (depth = 3; full traversal; cutoff = 1M):
   ```bash
   disk_analyzer.sh -l 3 -a -c 1M ~/projects
   ```
3. **Targeted Inclusion** (whitelist patterns):
   ```bash
   disk_analyzer.sh -w "*/src/*,*/lib/*" .
   ```
4. **Composite Pattern Files:**
   ```bash
   disk_analyzer.sh --whitelist-file ~/includes.txt --blacklist-file ~/excludes.txt /opt
   ```
5. **Whitelisted Deep Path with Size Cutoff:**
   ```bash
   disk_analyzer.sh -l 1 -c 10M -w "/data/archive/old_logs" /data
   ```
   Even though `/data/archive/old_logs` is deeper than level 1 and may be smaller than 10M, it will be shown in the output.

## Observability and Diagnostic Instrumentation

- **Verbose Tracing:** Environment variable `DEBUG=true` can be employed to emit decision-making traces, revealing internal evaluation branches:
  ```bash
  DEBUG=true disk_analyzer.sh -l 1 .
  ```
- **Error Handling:** The script provides warnings on stdout/stderr for non-critical issues, while continuing execution. Critical errors that prevent proper operation will cause termination with appropriate exit codes.
- **Exit Status Semantics:**
  - `0`: Normal termination
  - `1`: Argument parsing failure
  - `2`: Target directory inaccessible or nonexistent
  - `3`: I/O error during traversal

## Performance Considerations

- To mitigate I/O overhead on expansive file systems, judiciously constrain `--level` and activate `--min-size` filters.
- Optimal throughput may be achieved on SSD-resident volumes or high-bandwidth network file systems.
- Parallelized invocation by segmenting root directories and externally consolidating results can further enhance scalability.
- **Symbolic Links:** By default, symlinks are not followed. Use `-L` to follow them, which may increase scan time.
  - The script implements loop detection to prevent infinite recursion when following symbolic links.
  - Loops are detected by tracking visited inodes to ensure each filesystem object is processed only once.
- **Mount Points:** By default, the script may cross filesystem boundaries. Use `-x` to stay within the initial filesystem, which is often faster and safer.

## Integration into Automation Pipelines

- **Scheduled Audits:** Integrate with crontab for periodic capacity assessments:
  ```cron
  0 03 * * * /usr/local/bin/disk_analyzer.sh -l 1 -c 100M /var > /var/log/disk_report.log
  ```
- **CI/CD Preflight Checks:** Embed within deployment pipelines to enforce storage usage budgets and detect regressions in artifact size.

## Size Calculation Details

- **Hard Links:** Files with multiple hard links will be counted each time they are encountered within the traversal, potentially inflating the reported size of directories containing them. This is standard behavior for tools like `du`.
- **Special Files:** Device files, sockets, pipes, etc., are typically reported with a size of zero and included in totals unless explicitly excluded by patterns.
- **Units:** Size suffixes (`K`, `M`, `G`, `T`, `P`) are case-insensitive and based on powers of 1024 (KiB, MiB, GiB, etc.).

## Troubleshooting Matrix

| Symptom                                  | Probable Etiology                                   | Remediation Strategy                                                           |
|------------------------------------------|-----------------------------------------------------|--------------------------------------------------------------------------------|
| Absence of output                        | Complete exclusion by filters or empty hierarchy     | Lower `--min-size`/`--cut`; review patterns; check `--level`; ensure target is not empty |
| Permission denied errors                 | Insufficient filesystem privileges                  | Escalate privileges with `sudo`; adjust ACLs/permissions; use `-x` to avoid problematic mounts |
| Unexpected directory omissions           | Overly restrictive `--min-size`/`--cut` or blacklist | Validate units; audit patterns; check `--level`; consider `--all`. Note: whitelisted paths are exempt from `--cut` filter.              |
| Script errors on invalid size (`-m`/`-c`) | Malformed size argument (e.g., `1Z`, `abc`)         | Correct the size format (e.g., `1M`, `500K`, `2G`). Check `--help`.            |
| Slow performance                         | Deep traversal, large directories, slow disk, network filesystem, following symlinks | Reduce `--level`; use `--min-size`; use `-x`; avoid `-L`; run on faster storage |
| Incorrect sizes (symlinks/mounts)        | Default handling of symlinks/mount points           | Use `-L` to follow symlinks if needed; use `-x` to stay on one filesystem if needed |
| Mid-analysis file access errors          | Files deleted/permissions changed during scan       | Rerun scan; ensure stable filesystem state; check logs for specific errors (if DEBUG=true) |
| Infinite loop or excessive runtime       | Symlink cycles without proper loop detection        | Ensure you're using recent script version with loop detection; avoid `-L` when unnecessary |
| Combined option conflicts                | Combining short options incorrectly                    | Use separate options with their arguments (e.g., `-l 2 -m 5M -r`) |

---

For a rigorous examination of the underlying architecture and module interactions, consult **system_architecture.md**.

## Implementation Using `du` and `tree`

The `disk_analyzer.sh` script is built on top of the following core Unix/Linux command-line tools:

1. **`du` (Disk Usage):**
   - Used to calculate the size of directories and files.
   - Example: `du -sh /path/to/dir` provides a human-readable summary of the directory size.
   - For depth-limited traversal: `du --max-depth=N`.

2. **`tree` (Directory Tree Visualization):**
   - Used to render a tree-like structure of directories and files.
   - Example: `tree -L N /path/to/dir` limits the depth of the tree to `N` levels.

3. **`find` (Filesystem Traversal):**
   - Used to locate files and directories based on various criteria (e.g., size, name, depth).
   - Example: `find /path/to/dir -maxdepth N -type d` lists directories up to depth `N`.

4. **`sort` (Sorting):**
   - Used to sort the output of commands by size, name, or other criteria.
   - Example: `sort -h` sorts human-readable sizes.

5. **`awk` and `xargs` (Stream Processing):**
   - `awk` is used for text processing and filtering.
   - `xargs` is used to build and execute commands from standard input.

### Example Workflow

1. **Directory Size Calculation:**
   - Use `du` to calculate sizes:
     ```bash
     du -h --max-depth=2 /path/to/dir | sort -h
     ```

2. **Tree Visualization:**
   - Use `tree` for a hierarchical view:
     ```bash
     tree -L 2 /path/to/dir
     ```

3. **Filtering by Size:**
   - Use `find` to filter directories by size:
     ```bash
     find /path/to/dir -type d -size +10M
     ```

4. **Combining Tools:**
   - Combine `du`, `find`, and `sort` for advanced filtering and sorting:
     ```bash
     du -h --max-depth=2 /path/to/dir | sort -h | awk '$1 > 10 {print $0}'
     ```

5. **Whitelist and Blacklist Patterns:**
   - Use `grep` or `awk` to include/exclude paths based on patterns.
   - Example:
     ```bash
     du -h --max-depth=2 /path/to/dir | grep -E 'pattern'
     ```

These tools form the foundation of the `disk_analyzer.sh` script, enabling efficient and modular implementation of its features.

