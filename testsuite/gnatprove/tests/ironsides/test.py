from test_support import *

prove_all(steps=1, prover=["cvc4"], counterexample=False, opt=["--no-loop-unrolling", "--no-inlining"])
