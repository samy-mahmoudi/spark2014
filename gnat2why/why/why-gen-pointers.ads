------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--                      W H Y - G E N - P O I N T E R S                     --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--                       Copyright (C) 2018, AdaCore                        --
--                                                                          --
-- gnat2why is  free  software;  you can redistribute  it and/or  modify it --
-- under terms of the  GNU General Public License as published  by the Free --
-- Software  Foundation;  either version 3,  or (at your option)  any later --
-- version.  gnat2why is distributed  in the hope that  it will be  useful, --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of  MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public License  distributed with  gnat2why;  see file COPYING3. --
-- If not,  go to  http://www.gnu.org/licenses  for a complete  copy of the --
-- license.                                                                 --
--                                                                          --
-- gnat2why is maintained by AdaCore (http://www.adacore.com)               --
--                                                                          --
------------------------------------------------------------------------------

with Gnat2Why.Util;        use Gnat2Why.Util;
with SPARK_Atree.Entities; use SPARK_Atree.Entities;
with Types;                use Types;
with Why.Ids;              use Why.Ids;
with Why.Sinfo;            use Why.Sinfo;

package Why.Gen.Pointers is
   --  This package encapsulates the encoding of access types into Why.

   procedure Declare_Ada_Pointer (P : W_Section_Id; E : Entity_Id);
   --  Emit all necessary Why3 declarations to support Ada pointers.
   --  @param P the Why section to insert the declaration
   --  @param E the type entity to translate

   procedure Declare_Allocation_Function (E : Entity_Id; File : W_Section_Id);
   --  Generate program functions called when allocating deep objects.
   --  The allocation function called depends on the type of the
   --  allocated object (elementary/composite) and whether it is initilized
   --  or not.

   procedure Create_Rep_Pointer_Theory_If_Needed
     (P : W_Section_Id;
      E : Entity_Id);
   --  Similar to Create_Rep_Record_Theory_If_Needed but handles objects of
   --  access type. It declares a pointer type as a why record with three
   --  fields: pointer_address, is_null_pointer, and pointer_address.
   --  It also defines the needed functions to manipulate this type.

   function New_Ada_Pointer_Update
     (Ada_Node : Node_Id;
      Domain   : EW_Domain;
      Name     : W_Expr_Id;
      Value    : W_Expr_Id)
      return W_Expr_Id;
   --  Generate a Why3 expression that corresponds to the update to an Ada
   --  pointer (the pointed value). Emit all necessary checks.
   --  Note that this function does not generate an assignment, instead it
   --  returns a functional update. It will look like
   --    { name with Pointer_Value = value }
   --  The assignment, if required, needs to be generated by the caller.

   function New_Pointer_Address_Access
     (E     : Entity_Id;
      Name  : W_Expr_Id;
      Local : Boolean := False)
      return W_Term_Id;
   --  Return an access to the Pointer_Address field of the pointer why record.
   --  @param E the Ada type entity
   --  @param Name name of the pointer to access
   --  @param Local whether we want the local or the global access

   function New_Pointer_Is_Null_Access
     (E     : Entity_Id;
      Name  : W_Expr_Id;
      Local : Boolean := False)
      return W_Term_Id;
   --  Return an access to the Is_Null field of the pointer why record.
   --  @param E the Ada type entity
   --  @param Name name of the pointer to access
   --  @param Local whether we want the local or the global access

   function New_Pointer_Value_Access
     (Ada_Node : Node_Id;
      E        : Entity_Id;
      Name     : W_Expr_Id;
      Local    : Boolean := False;
      Domain   : EW_Domain := EW_Term)
      return W_Term_Id;
   --  Return an access to the Pointer_Value field of the pointer why record.
   --  @param E the Ada type entity
   --  @param Name name of the pointer to access
   --  @param Local whether we want the local or the global access

   function Root_Pointer_Type (E : Entity_Id) return Entity_Id
     with Pre => Is_Access_Type (E);
   --  Return the first pointer type defined with the same designated type.
   --  This handles also subtypes.

end Why.Gen.Pointers;
