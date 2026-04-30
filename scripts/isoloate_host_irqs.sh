HOUSEKEEPING_CPUS="${1:-0-3}"

echo "Stop irqbalance first if needed:"
echo "  sudo systemctl stop irqbalance"
echo

for dir in /proc/irq/[0-9]*; do
  irq=${dir##*/}

  [ -f "$dir/smp_affinity_list" ] || continue

  before=$(cat "$dir/smp_affinity_list" 2>/dev/null || echo "?")

  if echo "$HOUSEKEEPING_CPUS" | sudo tee "$dir/smp_affinity_list" >/dev/null 2>&1; then
    after=$(cat "$dir/smp_affinity_list" 2>/dev/null || echo "?")
    printf "IRQ %-5s %12s -> %s\n" "$irq" "$before" "$after"
  else
    printf "IRQ %-5s %12s -> failed\n" "$irq" "$before"
  fi
done
