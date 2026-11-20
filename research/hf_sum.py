import re
rows = []
for line in open("hf_check.log"):
    m = re.match(r"(\S+) spoke (\S+) mine (\S+) debt \$([\d,]+)", line)
    if m: rows.append((m[1], float(m[2]), float(m[3]), float(m[4].replace(",", ""))))
real = [r for r in rows if r[3] >= 1]
bad = [r for r in real if abs(r[1] - r[2]) > 0.001 * r[1]]
print("checked", len(rows), "with debt>=$1", len(real), "mismatch", len(bad), "debt $%.0f" % sum(r[3] for r in real))
print("largest:", sorted(real, key=lambda r: -r[3])[:4])
