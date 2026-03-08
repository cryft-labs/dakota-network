"""One-shot: change validator count from 11 (0x0b) to 9 (0x09) in BesuGenesis.json."""
import os

path = r"C:\Users\Chad\Documents\dakota-network\Contracts\Genesis\BesuGenesis.json"
tmp  = path + ".tmp"

old = '"0000000000000000000000000000000000000000000000000000000000000001": "000000000000000000000000000000000000000000000000000000000000000b"'
new = '"0000000000000000000000000000000000000000000000000000000000000001": "0000000000000000000000000000000000000000000000000000000000000009"'

count = 0
with open(path, "r", encoding="utf-8") as fin, open(tmp, "w", encoding="utf-8", newline="\n") as fout:
    for line in fin:
        if old in line:
            line = line.replace(old, new)
            count += 1
        fout.write(line)

os.replace(tmp, path)
print(f"Replaced {count} occurrence(s).  Validator count: 11 (0x0b) → 9 (0x09)")
