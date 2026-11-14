* Behavioural E/G forms lowered to B sources, against closed forms.
* Expected results: behavioural_sources.expected.json
* Oracle (analytic), with v(a) = 0.5, v(b) = 2:
*   E1 VALUE        2 v(a) + 1                                  = 2
*   E2 POLY(2)      1 + 2 va + 3 vb + 4 va^2 + 5 va vb + 6 vb^2 = 38  (SPICE 2G6 order)
*   G3 TABLE        (0,0) (1,2) (2,2), x = 0.5 sits on the first segment's
*                   straight part (corner half-width 0.1): i = 1, into 1 ohm
*   B5              temper at the default 27 degC               = 27
* HSPICE's VCR and VCCAP, and VALUE on an H card, are refused (plain
* ngspice-44.2 stops on each): src/tests/expressions.zig.
va a 0 0.5
vb b 0 2
rb b 0 1k
e1 o1 0 value={2*v(a)+1}
e2 o2 0 poly(2) a 0 b 0 1 2 3 4 5 6
g3 0 o3 table {v(a)} = (0,0) (1,2) (2,2)
r3 o3 0 1
b5 o5 0 v=temper
.op
.end
