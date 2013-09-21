#!/bin/bash

rm -rf gnatprove
rm /home/florian/projects/oxford-cde/vcs/vcs_01/*.smt2

gnatprove -P test.gpr \
    -j 4 \
    --prover smtlib2_dummy \
    -d \
    -f \
    --warnings=off \
    --report=all \
    -v \
    --proof=no_split \
    foo.adb

cp gnatprove/*.smt2 /home/florian/projects/oxford-cde/vcs/vcs_01
