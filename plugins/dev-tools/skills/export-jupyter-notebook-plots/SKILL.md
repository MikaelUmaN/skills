---
name: export-jupyter-notebook-plots
description: Extract all plots from a Jupyter notebook as PNGs, organized by markdown header sections into a nested folder structure.
license: Apache-2.0
compatibility: Cross-platform. Requires Python via uv (astral.sh/uv) and a Jupyter notebook (.ipynb) file.
argument-hint: <notebook-path> [output-dir]
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
user-invocable: true
---

Extract all embedded plots from a Jupyter notebook and save them as PNGs in a folder hierarchy that mirrors the notebook's markdown header structure.

Arguments: $ARGUMENTS

## Argument parsing

Parse arguments from the arguments string:
- **First positional arg** = path to the notebook file (required). Can be absolute or relative to cwd.
- **Second positional arg** = output directory (optional). Can be absolute or relative to cwd. Defaults to a `plots/` folder next to the notebook.

If no notebook path is provided, tell the user the required usage and stop.

### Resolving the notebook path

1. If the path exists as given (absolute or relative to cwd), use it.
2. If not found, try globbing for `**/<name>` in the cwd to locate it.
3. If multiple matches are found, use AskUserQuestion to let the user pick.
4. If no matches, tell the user the file was not found and stop.

## Extraction

Run the following Python script via `uv run python -c "..."`, substituting the resolved notebook path and output directory. Use a timeout of 120000ms.

```python
import json, base64, os, re, sys

nb_path = "<NOTEBOOK_PATH>"
out_dir = "<OUTPUT_DIR>"

with open(nb_path) as f:
    nb = json.load(f)

def slugify(text):
    """Convert heading text to a filesystem-safe folder name."""
    text = text.strip().lower()
    text = re.sub(r'[^\w\s-]', '', text)
    text = re.sub(r'[\s]+', '-', text)
    text = re.sub(r'-+', '-', text).strip('-')
    return text or '_unnamed'

# Track current section path
heading_path = []  # list of (level, slug) tuples
current_folder = '_root'
count = 0

for cell_idx, cell in enumerate(nb['cells']):
    if cell['cell_type'] == 'markdown':
        source = ''.join(cell['source'])
        for line in source.split('\n'):
            m = re.match(r'^(#{1,6})\s+(.+)', line.strip())
            if m:
                level = len(m.group(1))
                slug = slugify(m.group(2))
                # Remove any headings at this level or deeper
                heading_path = [(l, s) for l, s in heading_path if l < level]
                heading_path.append((level, slug))
                current_folder = os.path.join(*[s for _, s in heading_path])
                break  # use first heading in the cell

    elif cell['cell_type'] == 'code':
        exec_num = cell.get('execution_count')
        cell_id = exec_num if exec_num is not None else cell_idx
        img_idx = 0
        for out in cell.get('outputs', []):
            img_data = out.get('data', {}).get('image/png')
            if img_data:
                if isinstance(img_data, list):
                    img_data = ''.join(img_data)
                png_bytes = base64.b64decode(img_data)
                folder = os.path.join(out_dir, current_folder)
                os.makedirs(folder, exist_ok=True)
                fname = f'plot_{cell_id}_{img_idx}.png'
                with open(os.path.join(folder, fname), 'wb') as fout:
                    fout.write(png_bytes)
                img_idx += 1
                count += 1

print(f'\nExtracted {count} plots from {nb_path}')
print(f'Output directory: {out_dir}\n')

# Print folder tree summary
for root, dirs, files in sorted(os.walk(out_dir)):
    level = root.replace(out_dir, '').count(os.sep)
    indent = '  ' * level
    folder_name = os.path.basename(root)
    png_count = len([f for f in files if f.endswith('.png')])
    if png_count:
        print(f'{indent}{folder_name}/ ({png_count} plots)')
    else:
        print(f'{indent}{folder_name}/')
```

**Important**: When substituting `<NOTEBOOK_PATH>` and `<OUTPUT_DIR>` into the script, use the resolved absolute paths and ensure any quotes or special characters are properly escaped.

## After extraction

Report the summary output to the user (total count and folder tree).
