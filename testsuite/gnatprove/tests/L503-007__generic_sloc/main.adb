with Gen;

procedure Main is
   type Sub is new Integer range 1 .. 10;
   package A is new Gen (Integer);
   package B is new Gen (Sub);
   pragma Unreferenced (A,B);
begin
   null;
end Main;
