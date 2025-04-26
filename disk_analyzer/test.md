# Test Cases for `disk_analyzer.sh`

Based on `documentation.md` and `system_architecture.md`.

**Note:** These test cases describe scenarios and expected outcomes. They assume a suitable test directory structure can be created for verification.

## I. Argument Parsing & Basic Execution

1.  **Test ID:** ARG_001
  *   **Description:** Run with no arguments in a directory.
  *   **Command:** `disk_analyzer.sh`
  *   **Expected Outcome:** Scans the current directory (`.`) with default level 1, default min-size 1M, sorted by size ascending. Exit code 0.
2.  **Test ID:** ARG_002
  *   **Description:** Specify a target directory.
  *   **Command:** `disk_analyzer.sh /path/to/target`
  *   **Expected Outcome:** Scans `/path/to/target` with default level 1, default min-size 1M, sorted by size ascending. Exit code 0.
3.  **Test ID:** ARG_003
  *   **Description:** Invalid option.
  *   **Command:** `disk_analyzer.sh --invalid-option`
  *   **Expected Outcome:** Prints usage error to stderr. Exit code 1.
4.  **Test ID:** ARG_004
  *   **Description:** Option requiring argument is missing the argument.
  *   **Command:** `disk_analyzer.sh --level`
  *   **Expected Outcome:** Prints usage error to stderr. Exit code 1.
5.  **Test ID:** ARG_005
  *   **Description:** Invalid argument value (non-numeric level).
  *   **Command:** `disk_analyzer.sh --level abc`
  *   **Expected Outcome:** Prints usage error to stderr. Exit code 1.
6.  **Test ID:** ARG_006
  *   **Description:** Invalid argument value (bad size format).
  *   **Command:** `disk_analyzer.sh --min-size 1X`
  *   **Expected Outcome:** Prints usage error to stderr. Exit code 1.
7.  **Test ID:** ARG_007
  *   **Description:** Non-existent target directory.
  *   **Command:** `disk_analyzer.sh /path/does/not/exist`
  *   **Expected Outcome:** Prints error about inaccessible target directory to stderr. Exit code non-zero (likely 1 or specific error code).
8.  **Test ID:** ARG_008
  *   **Description:** Target directory with no read permissions.
  *   **Preconditions:** Create a directory, `chmod 000 target_no_read`.
  *   **Command:** `disk_analyzer.sh target_no_read`
  *   **Expected Outcome:** Prints error about inaccessible target directory to stderr. Exit code non-zero.

## II. Level / Depth Control (`-l`, `--level`)

9.  **Test ID:** LVL_001
  *   **Description:** Default level (1).
  *   **Command:** `disk_analyzer.sh /path/to/deep/structure`
  *   **Expected Outcome:** Shows only items directly within the target directory and the target directory itself (if size permits). Subdirectories are listed but their contents are not explored further in the output list.
10. **Test ID:** LVL_002
  *   **Description:** Level 0.
  *   **Command:** `disk_analyzer.sh --level 0 /path/to/target`
  *   **Expected Outcome:** Shows only the total size of `/path/to/target`. No descent into subdirectories.
11. **Test ID:** LVL_003
  *   **Description:** Specific level (e.g., 2).
  *   **Command:** `disk_analyzer.sh --level 2 /path/to/deep/structure`
  *   **Expected Outcome:** Shows items up to two levels deep from the target directory root.
12. **Test ID:** LVL_004
  *   **Description:** Level deeper than actual structure.
  *   **Command:** `disk_analyzer.sh --level 10 /path/to/shallow/structure`
  *   **Expected Outcome:** Shows all items in the structure. Behaves correctly without error.

## III. Size Filtering (`--min-size`, `--all`, `--cut`)

13. **Test ID:** SIZE_001
  *   **Description:** Default minimum size (1M).
  *   **Preconditions:** Structure with files/dirs both above and below 1M.
  *   **Command:** `disk_analyzer.sh`
  *   **Expected Outcome:** Only items >= 1M are listed (unless pruning prevents deeper items from being seen).
14. **Test ID:** SIZE_002
  *   **Description:** Custom minimum size (e.g., 10K).
  *   **Preconditions:** Structure with files/dirs around 10K.
  *   **Command:** `disk_analyzer.sh --min-size 10K`
  *   **Expected Outcome:** Only items >= 10K are listed.
15. **Test ID:** SIZE_003
  *   **Description:** Custom minimum size (e.g., 2G).
  *   **Preconditions:** Structure with files/dirs around 2G.
  *   **Command:** `disk_analyzer.sh --min-size 2G`
  *   **Expected Outcome:** Only items >= 2G are listed.
16. **Test ID:** SIZE_004
  *   **Description:** `--all` flag.
  *   **Preconditions:** Structure with very small files/dirs.
  *   **Command:** `disk_analyzer.sh --all`
  *   **Expected Outcome:** All items are listed, regardless of size (respecting level). `--min-size` is ignored for listing, but may still affect traversal pruning if not whitelisted.
17. **Test ID:** SIZE_005
  *   **Description:** `--cut` flag.
  *   **Preconditions:** Structure with various sizes.
  *   **Command:** `disk_analyzer.sh --cut 5M`
  *   **Expected Outcome:** All items are traversed (respecting level), sizes calculated, sorted, and *then* items < 5M are removed from the final output.
18. **Test ID:** SIZE_006
  *   **Description:** `--all` and `--cut` interaction.
  *   **Preconditions:** Structure with various sizes, including very small ones.
  *   **Command:** `disk_analyzer.sh --all --cut 5M`
  *   **Expected Outcome:** All items are traversed and considered (no `--min-size` pruning), but the final output only includes items >= 5M.
19. **Test ID:** SIZE_007
  *   **Description:** `--cut` with whitelisted item below threshold.
  *   **Preconditions:** Whitelist file includes `/path/to/target/small_file` (e.g., 1K).
  *   **Command:** `disk_analyzer.sh --whitelist-file .disk_analyzer_include --cut 1M /path/to/target`
  *   **Expected Outcome:** `small_file` is listed despite being below the cut threshold because it was whitelisted. Other non-whitelisted items below 1M are cut.

## IV. Sorting (`--sort`, `-r`)

20. **Test ID:** SORT_001
  *   **Description:** Default sort (size ascending).
  *   **Command:** `disk_analyzer.sh`
  *   **Expected Outcome:** Output is sorted from smallest size to largest size.
21. **Test ID:** SORT_002
  *   **Description:** Reverse sort (`-r`).
  *   **Command:** `disk_analyzer.sh -r`
  *   **Expected Outcome:** Output is sorted from largest size to smallest size.
22. **Test ID:** SORT_003
  *   **Description:** Sort by name (future feature).
  *   **Command:** `disk_analyzer.sh -s name`
  *   **Expected Outcome:** (If implemented) Output is sorted alphabetically by path name.
23. **Test ID:** SORT_004
  *   **Description:** Sort by name reverse (future feature).
  *   **Command:** `disk_analyzer.sh -s name -r`
  *   **Expected Outcome:** (If implemented) Output is sorted reverse alphabetically by path name.

## V. Pattern Matching (Whitelist/Blacklist)

24. **Test ID:** PAT_001
  *   **Description:** Basic blacklist (`--blacklist`).
  *   **Preconditions:** Directory contains `file.tmp`.
  *   **Command:** `disk_analyzer.sh --blacklist '*.tmp'`
  *   **Expected Outcome:** `file.tmp` is not listed.
25. **Test ID:** PAT_002
  *   **Description:** Basic whitelist (`--whitelist`).
  *   **Preconditions:** Directory contains `important.dat` and other files.
  *   **Command:** `disk_analyzer.sh --whitelist '*.dat'`
  *   **Expected Outcome:** Only `important.dat` (and potentially parent directories containing it, depending on level/size) is listed. Other files are excluded.
26. **Test ID:** PAT_003
  *   **Description:** Whitelist overrides blacklist (command line).
  *   **Preconditions:** Directory contains `keep/this.log` and `ignore/this.log`.
  *   **Command:** `disk_analyzer.sh --whitelist 'keep/*.log' --blacklist '*.log'`
  *   **Expected Outcome:** `keep/this.log` is listed, `ignore/this.log` is not.
27. **Test ID:** PAT_004
  *   **Description:** Blacklist file (`.disk_analyzer_ignore`).
  *   **Preconditions:** Create `.disk_analyzer_ignore` with `*.tmp` in the target directory. Directory contains `file.tmp`.
  *   **Command:** `disk_analyzer.sh`
  *   **Expected Outcome:** `file.tmp` is not listed.
28. **Test ID:** PAT_005
  *   **Description:** Whitelist file (`.disk_analyzer_include`).
  *   **Preconditions:** Create `.disk_analyzer_include` with `*.dat` in the target directory. Directory contains `important.dat` and other files.
  *   **Command:** `disk_analyzer.sh`
  *   **Expected Outcome:** Only `important.dat` (and parents) is listed.
29. **Test ID:** PAT_006
  *   **Description:** Whitelist file overrides blacklist file.
  *   **Preconditions:** `.disk_analyzer_include` contains `keep/*.log`. `.disk_analyzer_ignore` contains `*.log`. Directory contains `keep/this.log` and `ignore/this.log`.
  *   **Command:** `disk_analyzer.sh`
  *   **Expected Outcome:** `keep/this.log` is listed, `ignore/this.log` is not.
30. **Test ID:** PAT_007
  *   **Description:** Command line overrides files (Whitelist).
  *   **Preconditions:** `.disk_analyzer_include` contains `*.dat`. Directory contains `important.dat` and `critical.cfg`.
  *   **Command:** `disk_analyzer.sh --whitelist '*.cfg'`
  *   **Expected Outcome:** Only `critical.cfg` is listed. The file pattern is ignored in favor of the command line one.
31. **Test ID:** PAT_008
  *   **Description:** Command line overrides files (Blacklist).
  *   **Preconditions:** `.disk_analyzer_ignore` contains `*.tmp`. Directory contains `file.tmp` and `file.bak`.
  *   **Command:** `disk_analyzer.sh --blacklist '*.bak'`
  *   **Expected Outcome:** `file.bak` is not listed. `file.tmp` *is* listed (assuming no whitelist). The file pattern is ignored.
32. **Test ID:** PAT_009
  *   **Description:** Absolute path pattern.
  *   **Preconditions:** File exists at `/tmp/test_data/absolute.txt`.
  *   **Command:** `disk_analyzer.sh --whitelist '/tmp/test_data/absolute.txt' /tmp/test_data`
  *   **Expected Outcome:** `/tmp/test_data/absolute.txt` is listed.
33. **Test ID:** PAT_010
  *   **Description:** Relative path pattern.
  *   **Command:** `disk_analyzer.sh --whitelist 'subdir/relative.txt' .`
  *   **Expected Outcome:** `./subdir/relative.txt` is listed.
34. **Test ID:** PAT_011
  *   **Description:** Regex pattern (Whitelist).
  *   **Preconditions:** Files `image1.jpg`, `image2.png`.
  *   **Command:** `disk_analyzer.sh --whitelist 'regex:.*\.jpe?g$' .`
  *   **Expected Outcome:** Only `image1.jpg` is listed.
35. **Test ID:** PAT_012
  *   **Description:** Regex pattern (Blacklist).
  *   **Preconditions:** Files `data.txt`, `log.txt`.
  *   **Command:** `disk_analyzer.sh --blacklist 'regex:^log.*'`
  *   **Expected Outcome:** `log.txt` is not listed.
36. **Test ID:** PAT_013
  *   **Description:** Whitelist path deeper than `--level`.
  *   **Preconditions:** Structure `/target/level1/level2/deep_file.dat`.
  *   **Command:** `disk_analyzer.sh --level 1 --whitelist '**/deep_file.dat' /target`
  *   **Expected Outcome:** Both `/target/level1` (respecting level 1) and `/target/level1/level2/deep_file.dat` (due to whitelist) are listed with their respective sizes.
37. **Test ID:** PAT_014
  *   **Description:** Whitelist path outside target directory.
  *   **Preconditions:** Whitelist file contains `/outside/path`.
  *   **Command:** `disk_analyzer.sh --whitelist-file .disk_analyzer_include /target/directory`
  *   **Expected Outcome:** Warning message "Whitelist path `/outside/path` is outside the target `/target/directory`; ignoring whitelist entry." printed to stderr. `/outside/path` is not scanned or listed. Scan proceeds within `/target/directory`.
38. **Test ID:** PAT_015
  *   **Description:** Whitelist pattern partially overlapping target.
  *   **Preconditions:** Whitelist file contains `/data2/foo`.
  *   **Command:** `disk_analyzer.sh --whitelist-file .disk_analyzer_include /data`
  *   **Expected Outcome:** Warning message "Whitelist path `/data2/foo` is outside the target `/data`; ignoring whitelist entry." printed to stderr. Scan proceeds only within `/data`.

## VI. Filesystem Traversal (`-x`, `-L`)

39. **Test ID:** FS_001
  *   **Description:** Default behavior (cross mount points, don't follow symlinks).
  *   **Preconditions:** A symlink exists, a separate filesystem is mounted within the target.
  *   **Command:** `disk_analyzer.sh /target`
  *   **Expected Outcome:** Symlink is listed with its own size (usually small). Mounted filesystem is traversed and included in parent directory sizes.
40. **Test ID:** FS_002
  *   **Description:** One File System (`-x`).
  *   **Preconditions:** A separate filesystem is mounted at `/target/mountpoint`.
  *   **Command:** `disk_analyzer.sh -x /target`
  *   **Expected Outcome:** Traversal stops at `/target/mountpoint`. Its size contribution to `/target` reflects only the mount point directory itself, not the contents of the mounted filesystem.
41. **Test ID:** FS_003
  *   **Description:** Dereference Symlinks (`-L`).
  *   **Preconditions:** A symlink `/target/link` points to `/target/real_dir`.
  *   **Command:** `disk_analyzer.sh -L /target`
  *   **Expected Outcome:** The size reported for `/target/link` reflects the size of `/target/real_dir`. `find` and `du` follow the link.
42. **Test ID:** FS_004
  *   **Description:** Interaction `-x` and `-L` (Symlink points across filesystem).
  *   **Preconditions:** Symlink `/target/link` points to `/other_fs/data`. `/other_fs` is a different filesystem.
  *   **Command:** `disk_analyzer.sh -x -L /target`
  *   **Expected Outcome:** `-x` takes precedence. The symlink `/target/link` is *not* followed because it crosses a filesystem boundary. Its size reflects the link itself.
43. **Test ID:** FS_005
  *   **Description:** Symlink Loop Detection (`-L`).
  *   **Preconditions:** Create a symlink loop: `ln -s B A; ln -s A B`.
  *   **Command:** `disk_analyzer.sh -L .`
  *   **Expected Outcome:** The script detects the loop, prints a warning to stderr (e.g., "Symlink loop detected at ./B"), skips the problematic path, and continues processing other files/directories. It does not enter an infinite loop. Exit code 0 (unless other critical errors occur).

## VII. Output Format (`--tree`)

44. **Test ID:** OUT_001
  *   **Description:** Default output format.
  *   **Command:** `disk_analyzer.sh`
  *   **Expected Outcome:** Output lines are `<size> <path>`, tab-separated.
45. **Test ID:** OUT_002
  *   **Description:** Tree output format (`--tree`).
  *   **Command:** `disk_analyzer.sh --tree`
  *   **Expected Outcome:** Output shows directory hierarchy using indentation. Sizes may be aggregated differently depending on implementation details (e.g., showing inclusive size for directories).

## VIII. Error Handling & Edge Cases

46. **Test ID:** ERR_001
  *   **Description:** Permission denied during traversal.
  *   **Preconditions:** A subdirectory exists with no read/execute permissions for the user running the script.
  *   **Command:** `disk_analyzer.sh /target`
  *   **Expected Outcome:** A warning message regarding the inaccessible subdirectory is printed to stderr. The script continues processing other parts of the directory tree. Exit code 0 (if some paths were successful).
47. **Test ID:** ERR_002
  *   **Description:** I/O error during size calculation (e.g., file unlinked between `find` and `du`).
  *   **Preconditions:** Difficult to reliably reproduce, but simulate by removing a file mid-scan if possible, or test with special files that `du` might error on.
  *   **Command:** `disk_analyzer.sh /target`
  *   **Expected Outcome:** A warning message regarding the I/O error for the specific path is printed to stderr. The script skips that path and continues. Exit code 0 (if some paths were successful).
48. **Test ID:** ERR_003
  *   **Description:** All paths fail (e.g., target exists but is completely unreadable).
  *   **Preconditions:** `chmod 000 /target; chmod 000 /target/*`
  *   **Command:** `disk_analyzer.sh /target`
  *   **Expected Outcome:** Multiple errors printed to stderr. Exit code 3.
49. **Test ID:** EDGE_001
  *   **Description:** Empty target directory.
  *   **Command:** `disk_analyzer.sh /empty_dir`
  *   **Expected Outcome:** No size/path lines printed (or possibly just the directory itself with size 0 or minimal block size, depending on `du` behavior and filters). Exit code 0.
50. **Test ID:** EDGE_002
  *   **Description:** Directory with only empty files.
  *   **Command:** `disk_analyzer.sh /dir_with_empty_files`
  *   **Expected Outcome:** Files listed with size 0 (if `--all` is used or `--min-size` is 0). Directory size might be non-zero due to metadata. Exit code 0.
51. **Test ID:** EDGE_003
  *   **Description:** Paths with special characters (spaces, quotes, etc.).
  *   **Preconditions:** Create files/dirs like `'file with spaces'`, `"quoted'name"`, `*star*file`.
  *   **Command:** `disk_analyzer.sh .`
  *   **Expected Outcome:** Script handles paths correctly without errors due to special characters. Output displays paths accurately. Exit code 0.
52. **Test ID:** EDGE_004
  *   **Description:** Very deep directory structure.
  *   **Command:** `disk_analyzer.sh --level 50 /very/deep/path`
  *   **Expected Outcome:** Script handles deep recursion without crashing (performance may degrade). Memory usage should be managed (cache flushing mentioned in docs). Exit code 0.
53. **Test ID:** EDGE_005
  *   **Description:** Hard links.
  *   **Preconditions:** Create a file `file.dat`, then `ln file.dat hardlink.dat`.
  *   **Command:** `disk_analyzer.sh .`
  *   **Expected Outcome:** `du` (and thus the script) counts the size contribution for *both* `file.dat` and `hardlink.dat`. The total size of the directory will reflect this double counting, which is standard `du` behavior. Exit code 0.