---
name: file-split
description: Split large files into smaller parts using `split` command. Use ONLY when the user asks to split/chunk a file, mentions file splitting by size, or asks to break a large file into parts for transfer. Generates a metadata txt file with original MD5 and merge command.
---

# File Split

Split large files into smaller parts with automatic metadata generation.

## Script

The split script is at `.claude/skills/file-split/file-split.sh`.

Usage:
```bash
bash .claude/skills/file-split/file-split.sh <file_path> [split_size]
```

- `<file_path>`: Path to the file to split (required)
- `[split_size]`: Size for each part (default: 9G)

## Steps to split a file

1. Run the script with the file path:
   ```bash
   bash .claude/skills/file-split/file-split.sh /path/to/large_file.tar
   ```
2. Or with a custom split size:
   ```bash
   bash .claude/skills/file-split/file-split.sh /path/to/large_file.tar 5G
   ```

## Output

- Split parts are created in the same directory as the original file, named `<basename>_part_<NN>.<ext>`
- A `<basename>.reconstruct.txt` file is generated containing:
  - Original file MD5 hash
  - Command to reconstruct the original file

## Example

```bash
bash .claude/skills/file-split/file-split.sh /os_nfs/06_images/Wings_vllm-ascend_v0.20.2rc1-a3_910C_Qwen36-27B_aarch64.tar
```
