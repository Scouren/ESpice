.espice 1
// A 2:1 resistive divider.
.subckt divider (top mid bot) {
    R1 (top mid) resistor 10k
    R2 (mid bot) resistor 10k
}
