--  TU: 5. Invariant checking is extended to include checking of global inputs
--  and outputs, and for all subprograms. For purposes of determining type
--  invariant verification conditions, a global of a given mode (i.e, in, out,
--  or in out) is treated like a parameter of the given mode. This rule applies
--  regardless of where the global object in question is declared.

package Type_Invariant_Legal_5 with
  Abstract_State => State
is

   type T is private;

   function Pub return Integer with Global => State;
   function E_Pub return Integer with Global => State;

   procedure Pub_In with Global => (Input => State);
   procedure Pub_Out with Global => (Output => State);
   procedure Pub_In_Out with Global => (In_Out => State);

private
   type T is new Natural with Type_Invariant => T /= 0;

   X : T := 1 with Part_Of => State;  --  @INVARIANT_CHECK:PASS

   function Priv return Integer with Global => State;
   function E_Priv return Integer with Global => State;

   function E_Pub return Integer is (Integer(X));  --  @INVARIANT_CHECK:NONE
   function E_Priv return Integer is (Integer(X));  --  @INVARIANT_CHECK:NONE

end Type_Invariant_Legal_5;
