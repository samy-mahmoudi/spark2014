private package Power_14.Source_A_14
   with Abstract_State => (State with Part_Of => Power_14.State)
is
   procedure Read (Level : out Integer)
      with Global => State,
           Depends => (Level => State);
end Power_14.Source_A_14;
