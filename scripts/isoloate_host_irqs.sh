for irq in $(grep -i igc /proc/interrupts | cut -d: -f1); do
  echo 0-3 | sudo tee /proc/irq/$irq/smp_affinity_list
done
