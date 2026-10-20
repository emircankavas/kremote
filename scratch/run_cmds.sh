#!/bin/sh
# Runs every generated snippet command and prints its exit code and output.
# The same file is used on macOS and inside WSL, so the two results are comparable.
n=0
while IFS= read -r line; do
  case "$line" in
    "### "*)
      printf '%-22s ' "${line#\#\#\# }"
      ;;
    *)
      out=$(/bin/sh -c "$line" 2>&1)
      printf 'rc=%s [%s]\n' "$?" "$(printf '%s' "$out" | tr '\n' '|')"
      n=$((n + 1))
      ;;
  esac
done < "$1"
echo "cases: $n"
