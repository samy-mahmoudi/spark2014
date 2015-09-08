package PO_T
  with Abstract_State => (State with External)
is

   --  TU: 3. If a variable or a package which declares a state abstraction is
   --  declared immediately within the same declarative region as a
   --  ``single_task_declaration`` or a ``single_protected_declaration``, then
   --  the Part_Of aspect of the variable or state abstraction may denote the
   --  task or protected unit. This indicates that the object or state
   --  abstraction is not part of the visible state or private state of its
   --  enclosing package. [Loosely speaking, flow analysis will treat the
   --  object as though it were declared within its "owner". This can be useful
   --  if, for example, a protected object's operations need to reference an
   --  object whose Address aspect is specified.  The protected (as opposed to
   --  task) case corresponds to the previous notion of "virtual protected"
   --  objects in RavenSPARK.]
   --  An object or state abstraction which "belongs" to a task unit in this
   --  way is treated as a local object of the task (e.g., it cannot be named
   --  in a Global aspect specification occurring outside of the body of the
   --  task unit, just as an object declared immediately within the task body
   --  could not be).  An object or state abstraction which "belongs" to a
   --  protected unit in this way is treated as a component of the (anonymous)
   --  protected type (e.g., it can never be named in any Global aspect
   --  specification, just as a protected component could not be).  However,
   --  the presence or absence of such a Part_Of aspect specification is
   --  ignored in determining the legality of an Initializes or
   --  Initial_Condition aspect specification; the notional equivalence
   --  described above breaks down in that case. [Very roughly speaking, the
   --  restrictions implied by such a Part_Of aspect specification are not
   --  really "in effect" during library unit elaboration; or at least that's
   --  one way to view it.]

   protected P_Int is
      function Get return Integer;

      entry Set (X : Integer);
   private
      Condition : Boolean := True;
   end P_Int;

   The_Protected_Int : Integer := 0
     with Part_Of => P_Int;

private

   protected Hidden_PO
     with Part_Of => State
   is
      function Get return Integer;

      entry Set (X : Integer);
   private
      The_Protected_Int : Integer := 0;
      Switch            : Boolean := True;
   end Hidden_PO;

end PO_T;
