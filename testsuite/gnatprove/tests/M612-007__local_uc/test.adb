with Ada.Unchecked_Conversion;

package body Test is
   type A is new Integer range 0 .. 20;
   type B is new Natural range 0 .. 20;

   function A_To_B is new Ada.Unchecked_Conversion (A, B);

   procedure Test is
      function B_To_A is new Ada.Unchecked_Conversion (B, A);
   begin
      null;
   end Test;

end Test;
