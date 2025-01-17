###################
Translation to Why3
###################

*************************
Content of the Why3 files
*************************

This section should describe what is generated in the Why3 files and
why, and also give pointers to specific part of the gnat2why code to
facilitate investigation of issues in these generated files. Here we
do not explain what is generated for the purpose of counterexample
generation only.

Modules for Entities
====================

What is translated: all visible entities that are spark-compatible (+
fake entities for invisible / non-spark globals), both library-level
and scoped, from the current and withed units.

Visibility: Precision is maximal, based on current unit and spec of
withed units only, both private and public declarations, stopping at
SPARK boundaries. Example: private types, deferred constants, private
expression functions, abstract states...

.. code-block:: ada

     package P1 with SPARK_Mode is
       type T1 is tagged private;
       C1 : constant T1;
       function Get_F (X : T1) return Integer;
     private
       type T1 is tagged record
	 F : Integer;
       end record;
       C1 : constant T1 := (F => 1);
       function Get_F (X : T1) return Integer is (X.F);
     end P1;

     with P1; use P1;
     package P2 with SPARK_Mode is
       type T2 is new T1 with private;
       C2 : constant T2;
       function Get_G (X : T1) return Integer;

     private
       pragma SPARK_Mode (Off);
       type T2 is new T1 with record
	 G : Integer;
       end record;
       C2 : constant T2 := (F => 1, G => 2);
       function Get_G (X : T1) return Integer is (X.G);
     end P2;

     with P2; use P2;
     package P3 with SPARK_Mode is
       X : T2;
     end record;

When analyzing P3, proof knows that X has a component called F and
that it can be retrieved using Get_F. It also knows that Get_F (C1)
is 1. On the other hand, it does not know anything about G, not even
that there is a new component in T2. It does not know the value of C2
or the meaning of Get_G either, so it cannot prove that Get_G (C2)
is 2.

Types
-----

There are two modules (at least) for every visible type entity, one
for declarations, one for type completion (predicates, invariants,
default initialization…). This is necessary to avoid circularity
issues (predicates and invariants may refer to functions defined after
the type in the Ada unit, type bounds and default initialization may
depend on variables which are always translated after types in Why
units [NB. this is because of loops, where constants depending on the
loop index are translated as variables. Indeed, type bounds and
default values are not usually allowed to depend on variables]).

Common Features
^^^^^^^^^^^^^^^

Some elements are declared in all types. They are listed here and are
not repeated in the following sections.

References and Havoc
""""""""""""""""""""

Why is an ML-like language. In particular, declared variables are
usually constant and cannot be modified. Why provides a way to define
mutable variable using a polymorphic reference type named ref.
However, to avoid introducing polymorphism which can be harmful to
some background solvers, we do not use this type in gnat2why. Instead,
for each type that we declare, we introduce a monomorphic reference
type as a record with a single mutable field. Here is what this
declaration would look like for a given type t:

.. code-block:: whyml

    type t__ref = { mutable t__content : t }

To allow compatibility between references, it is therefore important
to only have one such reference type for each type. As a result, when
types are only clones of existing types (see static array types or
classwide types for instance), we do not redefine the reference type
for them, and rather use the existing reference type (see
``Gnat2why.Types.Translate_Types`` to see when the reference type is not
emitted).

NB: Because of this, we need to not rename types which are clones of
existing types to avoid breaking the naming correspondence between the
type contained in the reference and its content field. This is why no
new type alias is generated for static array types and the Why3 map
type is used directly instead (see Why.Inter.New_Kind_Base_Type which
is called by Why.Inter.Type_Of_Node).

In addition to the monomorphic reference type, a specific havoc
function is declared for each type. It is a program function which
modifies the content of a reference in an unknown way. Here is what it
looks like for a given type t:

.. code-block:: whyml

    val t__havoc (x : t__ref) : unit
    writes {x}

A havoc function is introduced every time a new reference type is
declared. It is called to havoc an object when we know it can have been
modified in an unknown way since the last time it was read. In
particular, volatile objects with asynchronous writers are havoced
every time they are read.

Predefined / primitive equality
"""""""""""""""""""""""""""""""

For every Ada type, we also introduce an equality function for the predefined
equality named ``bool_eq``. A notable exception, predefined equality is not
used on scalar types. Instead, equality on such types is directly
translated as the Why built-in equality on the types representative
types (see section about scalar types).

For types which ultimately are record types, we also define a function named
``user_eq`` for the primitive equality. It is only used when primitive equality
is redefined for the type (see ``Why.Gen.Expr.New_Ada_Equality``).

When it is declared, the boolean equality ``bool_eq`` is given a
definition depending on the kind of the type. Here is for example the
equality which would be generated for a record type with a single ``F``
component of type ``Integer``:

.. code-block:: whyml

    function bool_eq (a : t) (y : t) : bool =
    Standard__integer__rep.to_rep a.__split_fields.rec__t__f =
    Standard__integer__rep.to_rep b.__split_fields.rec__t__f

It simply states that two records are equal when their ``F`` components
are equal.

As for the user-defined primitive equality, it is declared with no
definition. The definition will be given during the type completion if
a primitive equality has been encountered:

.. code-block:: whyml

    function user_eq (a : t) (b : t) : bool

Dummy values
""""""""""""

For each type, a constant dummy value is introduced. It is used to
give a value to components which are not present in record types due
to discriminant constraints (see following section about record
types):

.. code-block:: whyml

    function dummy : t

Scalar Types
^^^^^^^^^^^^

All scalar types have a resentative type, which is the Why type used
to represent this scalar type. It differs depending on the kind of
scalar type which is declared. Scalar types also have a more complete
form, which includes additional constraints (bounds, modulus etc).
These closed forms are only used for objects which are stored inside
data structures, to avoid the need for complex invariants whenever
possible.

Primitive equality on scalar types is translated as Why equality on
the corresponding representative types.

We first explain how static non-empty scalar types are translated into
SPARK, going over each kind of type individually. Dynamic (and
statically empty) types are handled a bit differently, this is
explained afterwards (see ``Gnat2why.Util.Type_Is_Modeled_As_Base`` for the
exact check).

Signed Integer Types
""""""""""""""""""""

The representative type for signed integer types is mathematical
integers. Indeed, solvers have powerful tactics to reason about linear
arithmetic and comparison operators on mathematical integers.
Arithmetic operations and comparisons on signed integer are
translated as operations on mathematical integers so that GNATprove
can benefit from this support.

The closed form of a static signed integer represents exactly the
range of the Ada type. It is encoded using a Why3 range type with
an of_rep function to convert from mathematical
integers as well as a range axiom.

As an example, let us look at the following type:

.. code-block:: ada

   type Signed_Int is range 1 .. 10;

Here are the axioms and declarations generated in Why for it. We do
not repeat parts common to every types here, and scalar attributes are
presented later. Here we inline the clones that are used to factorize
declarations in Why:

.. code-block:: whyml

    module P__signed_int
     use import "int".Int

     type signed_int = < range 1 10 >

     function first : int = 1

     function last : int = 10

     predicate in_range (x : int)  = (first <= x <= last)

     ...
    end

    module P__signed_int__rep
     use import "int".Int
     use import Types__stat_ty

     function to_rep (x : signed_int) : int = signed_int'int x
     function of_rep int : signed_int

     axiom inversion_axiom :
	forall x : signed_int [to_rep x].
	  of_rep (to_rep x) = x

     axiom range_axiom :
	forall x : signed_int [to_rep x]. in_range (to_rep x)

     axiom coerce_axiom :
	forall x : int [to_rep (of_rep x)].
	  in_range x -> to_rep (of_rep x) = x
    end

The range, inversion, and coerce axioms enforce that there is exactly
one element in the closed form of a signed integer type per
mathematical integer between first and last. These modules are
generated respectively by Why.Gen.Scalars.Declare_Scalar_Types and
Why.Gen.Scalars.Define_Scalar_Rep_Proj.

NB: to_rep and of_rep functions as well as related axioms are in a
separate module which is only included when these conversions are
used. This is to improve solver performances by reducing the context
when they are not necessary.

Modular Integer Types
"""""""""""""""""""""

Modular integer types are represented in Why as bit-vectors (machine
integers). More precisely, their representative type is the smallest
bit-vector in which they fit (we only use bit-vectors of size 8, 16,
32, or 64). Indeed, some backend solvers can handle natively bitwise
operations such as shift or rotate on bit-vectors whereas there is no
equivalence on mathematical integers. They also handle wrap-around
semantics of operators natively. Solvers can sometimes be more precise
about non-linear arithmetic on bit-vectors, especially on small
bit-vectors.

Operations on modular types are generally translated as operations on
bit-vectors, followed by a rounding of the specified modulus when
necessary. However, when the type has a modulus which is not a power
of two, care must be taken to do the computation in a type big enough
to avoid wrap-around in the representative type. To this aim,
operations are usually done in a bigger bit-vector when the modulus is
not a power of two. For power, we even go to mathematical integers
since no bit-vector type is big enough.

As for signed integers, the closed form of a static modular type
contains exactly the values that are allowed by the modulus and the
range if any. The closed form is linked to the representative type
using a range predicate, as well as of_rep and to_rep functions to
convert to and from bit-vectors. As an example, let us look at the
following type:

.. code-block:: ada

   type Modular_Int is mod 500;

Here are the axioms and declarations generated in Why for it. Like for
signed integer types, we only give here the relevant declarations and
to_rep and of_rep functions are separated in a different module:

.. code-block:: whyml

     type modular_int

     function attr__ATTRIBUTE_MODULUS : BV16.t =
      (BV16.of_int 500)

     function first : BV16.t = BV16.of_int 0

     function last : BV16.t = BV16.of_int 499

     predicate in_range (x : BV16.t) = (BV16.ule first x /\ BV16.ule x last)

     function to_rep modular_int : BV16.t
     function of_rep BV16.t : modular_int

     axiom inversion_axiom :
	forall x : modular_int [to_rep x].
	  of_rep (to_rep x) = x

     axiom range_axiom :
	forall x : modular_int [to_rep x]. in_range (to_rep x)

     axiom coerce_axiom :
	forall x : BV16.t [to_rep (of_rep x)].
	  let y = BV16.urem x attr__ATTRIBUTE_MODULUS in
	    in_range y -> to_rep (of_rep x) = y

Like for signed integers, the inversion, range, and coerce axiom
ensure that there is exactly one element in the closed form of a
modular integer per element between first and last. The coerce axiom
ensures that modular values are always considered up to the modulus
attribute.

Since background solvers are often bad at converting between
bit-vectors and mathematical integers, we also provide a range
predicate and a range axiom speaking about the mathematical integer
representation of bit-vectors. It is useful when modular integer types
happen to be converted to signed integer types, or to be compared to
some attributes of universal integer types such as array length:

.. code-block:: whyml

     function first_int : int = 0

     function last_int : int = 499

     predicate in_range_int (x : int) = (first_int <= x <= last_int)

     axiom range_int_axiom :
	forall x : modular_int [to_int x]. in_range_int (BV16.t'int (to_rep x))

Enumerations
""""""""""""

Enumerations are translated just like signed integer types. The
specific names of enumerated values do not even appear in the
generated Why code. They are directly translated as their position
(see ``Gnat2why.Expr.Transform_Enum_Literal``). A notable exception to
this scheme are standard boolean types (see Is_Standard_Boolean_Type)
for which no new theory is introduced and which are translated
directly as booleans in Why.

Floating Point Types
""""""""""""""""""""

The representative type of an Ada floating point type is a machine
floating point type of the corresponding size (8, 16, 32, or 64).
Background solvers which support floating point numbers abide by the
IEEE 754 standard. Operations on floating point numbers in Ada are
translated using the corresponding built-in operation in solvers, but
only if the Ada standard is enforcing the IEEE 754 behavior.

Then, like for integer types, a closed form is defined for static
floating point types which only allows numbers in the specified range.

As an example, let us look at the following type:

.. code-block:: ada

   type Floating_Point is digits 6 range 0.0 .. 100.0;

Here are the axioms and declarations generated in Why for it. Like for
signed integer types, we only give here the relevant declarations and
to_rep and of_rep functions are separated in a different module:

.. code-block:: whyml

     type floating_point

     function first : Float32.t = (0.0:Float32.t)

     function last : Float32.t = (100.0:Float32.t)

     predicate in_range (x : Float32.t)  =
      (Float32.t'isFinite x) && (Float32.le first x /\ Float32.le x last)

     function to_rep floating_point : Float32.t
     function of_rep Float32.t : floating_point

     axiom inversion_axiom :
	forall x : floating_point [to_rep x].
	  of_rep (to_rep x) = x

     axiom range_axiom :
	forall x : floating_point [to_rep x]. in_range (to_rep x)

     axiom coerce_axiom :
	forall x : Float32.t [to_rep (of_rep x)].
	  in_range x -> to_rep (of_rep x) = x

Fixed Point Types
"""""""""""""""""

A value of fixed point types is translated as an integer, the represented value
being the product of the small of the fixed point type with this value. To avoid
confusion, we use an alias of int names __fixed. Except from that, static fixed
point types are translated as static integer types, with a range, conversion
functions and coerce and range axioms. For example, let us consider the
following type:

.. code-block:: ada

   type My_Fixed is delta 3.0 / 1000.0 range 0.0 .. 3.0;

Here are the axioms and declarations generated in Why for it. Like for
integer types, we only give here the relevant declarations and
to_rep and of_rep functions are separated in a different module:

.. code-block:: whyml

 type my_fixed

 function num_small
   : Main.__fixed =
  1

 function den_small
   : Main.__fixed =
  512

 function first
   : Main.__fixed =
  0

 function last
   : Main.__fixed =
  1536

 predicate in_range
   (x : Main.__fixed)  =
  ( (first <= x) /\ (x <= last) )

  function to_rep t : __fixed

  function of_rep __fixed : t

  axiom range_axiom :
    forall x : t. in_range (to_rep x)

  axiom inversion_axiom :
    forall x : t [to_rep x].
      of_rep (to_rep x) = x

  axiom coerce_axiom :
    forall x : __fixed [to_rep (of_rep x)].
      in_range x -> to_rep (of_rep x) = x

Operations on values of a
fixed point type depend on the value of the small of the type. For every
possible small, a new module is introduced which defines operations for this
small. As an example, here is the module introduced for fixed point types of
small 1 / 512 like My_Fixed above:

.. code-block:: whyml

 module Fixed_Point__1_512

   function num_small : int = 1

   function den_small : int = 512

   (* multiplication between a fixed-point value and an integer *)

   function fxp_mult_int (x : __fixed) (y : int) : __fixed = x * y

   (* division between a fixed-point value and an integer
      case 1:
         If the divident is zero, then the result is zero.
      case 2:
         If both arguments are of the same sign, then the mathematical
         result is either exact, or between exact and exact+1, which are the
         possible results.

         for example:
              x =  5, y =  3, exact = 1, math = 1.666.., result in { 1, 2 }
              x = -5, y = -3, exact = 1, math = 1.666.., result in { 1, 2 }
      case 3:
         If arguments are of opposite signs, then the mathematical
         result is either exact, or between exact-1 and exact, which are the
         possible results.

         for example:
              x = -5, y =  3, exact = -1, math = -1.666.., result in { -2, -1 }
              x =  5, y = -3, exact = -1, math = -1.666.., result in { -2, -1 }
    *)

    function fxp_div_int (x : __fixed) (y : int) : __fixed

    axiom fxp_div_int_def :
      forall x : __fixed. forall y : int [fxp_div_int x y].
        if x = 0 then
          fxp_div_int x y = 0
        else if x > 0 /\ y > 0 then
          pos_div_relation (fxp_div_int x y) x y
        else if x < 0 /\ y < 0 then
          pos_div_relation (fxp_div_int x y) (-x) (-y)
        else if x < 0 /\ y > 0 then
          pos_div_relation (- (fxp_div_int x y)) (-x) y
        else if x > 0 /\ y < 0 then
          pos_div_relation (- (fxp_div_int x y)) x (-y)
        else (* y = 0 *)
          true

  ...

  end

Note that, in the Why generated code, the type system is not used to ensure that
we always use the correct operation for fixed point types.

Dynamic scalar types
""""""""""""""""""""

When scalar types have dynamic bounds, or when they are statically
empty, no new closed type is generated for them. Instead, their closed
view is set to the closed view of their base type. Otherwise, the
translation is unchanged, except that first and last bounds can be
functions instead of constants if their values depend on variables. As
a result, the range predicate is replaced by a dynamic_property
predicate, which takes the current value of first and last as
additional parameters.

Additionally, as no new closed type is generated for them, dynamic
scalar types do not have a specific module for projection to the
representative type (of_rep and to_rep and related axioms), but rather
use the projections of their base type.

This specific translation is triggered when
``Gnat2why.Util.Type_Is_Modeled_As_Base`` returns ``True``. As an example, let
us look at the translation of the following signed integer type
declaration, where X is a non-static constant:

.. code-block:: ada

    subtype Dyn_Ty is Integer range 1 .. X;

Here is its translation into Why:

.. code-block:: whyml

    module P__dyn_ty
     use import "int".Int
     use    	Standard__integer
     use    	Standard__integer__rep

     type dyn_ty = Standard__integer.integer

     function first : int = 1

     function last : int

     predicate dynamic_property
	 (first_int : int) (last_int : int) (x : int)  =
      first_int <= x <= last_int

     function to_rep "inline" (x : dyn_ty) : int =
       Standard__integer__rep.to_rep x
     function of_rep "inline" (x : int) : dyn_ty =
       Standard__integer__rep.of_rep x
    end

Here we can see that, since the first bound is static, it is
translated directly as a constant in Why and its value is given at
declaration. The last bound is a constant too, as X is translated as a
constant in Why3, but it is not given a value here, as its value may
depend on other entities which have not been translated yet.

Instead, an axiom is generated in the types completion module to state
the actual value of Dyn_Ty last bound (see
``Gnat2why.Types.Generate_Type_Completion.Create_Axioms_For_Scalar_Bounds``):

.. code-block:: whyml

     axiom last__def_axiom : last = P__x.x

NB: Not generating a closed form for dynamic or statically empty
scalar types is important for soundness. Indeed, the of_rep function
cannot be defined if the closed form happens to be empty. Another
issue is that, if the first and last bounds of a scalar type depend on
variables, then the range predicate may change over time, so that the
range axiom may become unsound.

Scalar Attributes
"""""""""""""""""

Image and Value, they are not interpreted currently:

.. code-block:: whyml

     function attr__ATTRIBUTE_IMAGE rep_type : __image

     predicate attr__ATTRIBUTE_VALUE__pre_check (x : __image)

     function attr__ATTRIBUTE_VALUE __image : rep_type

Array Types
^^^^^^^^^^^

An (n-dimensional) Ada array is translated in Why as an infinite
(n-dimensional) functional map mapping representative values of the
array index types to closed values of the component type along with
values for index bounds. As an example, the objects of the following
array type:

.. code-block:: ada

       type My_Matrix is array
	   (Positive range 1 .. 100,
	    Modular_Int range 1 .. 50) of Natural;

Will be translated as maps from pairs of a mathematical integer and a
bitvector of size 16 to natural closed form along with 4 static
bounds:

.. code-block:: whyml

     type map

     function get map int BV16.t : Standard__natural.natural
     function set map int BV16.t Standard__natural.natural : map

     function first : int = 1

     function last : int = 100

     function first_2 : BV16.t = BV16.of_int 1

     function last_2 : BV16.t = BV16.of_int 50

Representative Array Theories
"""""""""""""""""""""""""""""

To avoid polymorphism, specific theories are introduced for each kind
of functional maps that are used in the program (see
Why.Gen.Arrays.Create_Rep_Array_Theory_If_Needed). To facilitate
conversions between array types, the same theory is reused whenever
possible. More precisely, a specific array theory is introduced per
n-uplet of n-1 representative index types (either mathematical
integers or bitvectors of size 8, 16, 32, or 64) and one component
type. The symbols introduced for these theories are stored in a map to
be reused for other array types with the same representative index
types and the same component types (see the M_Arrays map in
Why.Atree.Modules). To simplify implementation, the maps are indexed
by names which represent the representative n-uplets. These names are
created in a unique way by the function
Why.Gen.Arrays.Get_Array_Theory_Name, and are used to name the Why
module in which the related declarations are stored.

As an example, declarations related to the map type for the My_Matrix
type presented above are all grouped in a module named
Array__Int_BV16__Standard__natural:

.. code-block:: whyml

    module Array__Int_BV16__Standard__natural
      type map

      function get map int BV16.t : Standard__natural.natural
      function set map int BV16.t Standard__natural.natural : map

      axiom Select_eq :
	forall m : map.
	forall i : int.
	forall j : BV16.t.
	forall a : Standard__natural.natural.
	      get (set m i j a) i j = a

      axiom Select_neq :
	forall m : map.
	forall i i2 : int.
	forall j j2 : BV16.t.
	forall a : Standard__natural.natural.
	not (i = i2 /\ j = j2) -> get (set m i j a) i2 j2 = get m i2 j2

      ...
    end

Remark that, to simplify the generation of Why, these declarations are
in fact grouped in an abstract theory named
"_gnatprove_standard".Array__2 which is then cloned with the
appropriate index and component types each time such a theory is
needed. Currently, such abstract theories are only provided up to 4
dimensions, which means that GNATprove cannot currently handle arrays
of 5 or more dimensions. We would need to add new abstract theories in
__gnatprove_standard.mlw to lift this restriction should the need
arise.

As background solvers of GNATprove have theories for one dimensional
abstract maps (this theory is called theory of arrays), we have chosen
to directly translate maps for arrays of dimension 1 to the built-in
Map type in Why to benefit from this support.

As an example, let us consider the following 1 dimensional array type:

.. code-block:: ada

     type My_Array is array (Positive range <>) of Natural;

Here is the map theory introduced for it:

.. code-block:: whyml

    module Array__Int__Standard__natural
      use map.Map

      type map = Map.map int Standard__natural.natural

      function get (a : map) (i : int) : Standard__natural.natural = Map.get a i
      function set (a : map) (i : int) (v : Standard__natural.natural) : map = Map.set a i v
      ...
    end

Remark that this is a trade-off, as, on the one hand, solvers are
usually more efficient on multiple consecutive updates of arrays when
using the theory, while, on the other hand, the built-in support may
hinder quantifier instantiation of universally quantified axioms
involving arrays. Tests were done to decide which choice was the most
relevant for us, but as solvers are improving all the time, it may
have to be revisited at some point.

NB: We could have chosen to also translate multiple dimension arrays
using the theory (by nesting maps, or by indexing them with records).
We did not even try it, as there was already not so much benefits in
using the theory for one dimensional arrays.

Operators on Maps
"""""""""""""""""

In addition to the usual get and set operations on maps, we also
introduce more complex operations that are used to model Ada
operations. The first one is an equality function which checks for
equivalence of elements using the appropriate equality function for
Ada (it can be either the translation of the Ada predefined equality
function on the component type, or the translation of the Ada
primitive equality if the component type is a record) and which only
considers elements in a given range.

Here is the equality predicate introduced for My_Matrix:

.. code-block:: whyml

     function bool_eq (a : map) (a__first : int) (a__last : int)
		      (a__first_2 : BV16.t) (a__last_2 : BV16.t)
		      (b : map) (b__first : int) (b__last : int)
		      (b__first_2 : BV16.t) (b__last_2 : BV16.t) : bool =
	(if a__first <= a__last then
	      b__first <= b__last
	   /\ a__last - a__first = b__last - b__first
	 else b__first > b__last)
     /\ (if BV16.ule a__first_2 a__last_2 then
	      BV16.ule b__first_2 b__last_2
	   /\ BV16.sub a__last_2 a__first_2 =
	      BV16.sub b__last_2 b__first_2
	 else BV16.ugt b__first_2 b__last_2)
     /\ (forall x1  : int.
	(forall x2  : BV16.t.
	   (if a__first <= x1 <= a__last
	    /\ BV16.ule a__first_2 x2
	    /\ BV16.ule x2 a__last_2 then
	      to_rep (get a x1 x2) =
	       to_rep (get b ((b__first - a__first) + x1)
			(BV16.add (BV16.sub b__first_2 a__first_2) x2)))))

The predicate first states that the bounds given for each index for a
and b represent slices of the same length, and then that elements
located inside the slices are equal. This predicate is generated
dynamically for each map type (see
Why.Gen.Arrays.Declare_Equality_Function).

Unlike the equality predicate, other operations on maps are declared
via clones of static modules. The functions slide, concat, and
singleton (used respectively for array sliding and for concatenation)
are defined directly in the abstract theories for maps (concat and
singleton are only defined for 1 dimensional maps as in Ada,
concatenation is only defined for 1 dimensional arrays). Slide slides
all elements stored in a map of a given offset in each dimension. The
offsets are given by the mean of two positions per index, which stand
for the old and the new value of the first index of the Ada array. As
an example, here is the slide function defined for My_Matrix:

.. code-block:: whyml

      function slide map int int BV16.t BV16.t : map

      axiom slide_def :
	forall a : map.
	forall new_first    old_first   : int.
	forall new_first_2  old_first_2 : BV16.t.
	forall i : int.
	forall j : BV16.t.
	  get (slide a old_first new_first old_first_2 new_first_2) i j =
	    get a (i - (new_first - old_first))
		  (BV16.sub j (BV16.sub new_first_2 old_first_2))

The effects of the slide function are described through a defining
axiom. It states that each element of the slided array is equal (not
Ada equal, but really equal) to the corresponding element in the input
array.

Singleton returns a map which contains given element at a given index.
It is under-specified as nothing is said about elements at other
indexes:

.. code-block:: whyml

      function singleton component_type int : map

      axiom singleton_def :
       forall v : Standard_natural.
       forall i : int.
	 get (singleton v i) i = v

Concat takes six parameters, the two maps and the first and last
indexes of the relevant portions. Its behaviour is also specifies
using an axiom. It states that the result of concat is equal to the
first array when between the first set of bounds and to the second
array slided so that the first index of the second set of bound
coincides with the first index following the first array afterward:

.. code-block:: whyml

     function concat map int int map int int : map

     axiom concat_def :
       forall a b : map.
       forall a_first a_last b_first b_last : int.
       forall i : int.
	 (a_first <= i <= a_last ->
	     get (concat a a_first a_last b b_first b_last) i = get a i)
	    /\
	 (i > a_last ->
	   get (concat a a_first a_last b b_first b_last) i =
	   get b (i - a_last + b_first - 1))

Note that the second last bound b_last is supplied but never used
since we do not stop at the last bound for the second slice. Also note
that concat is underspecified as we do not know the value of elements
stored at indexes smaller than a_first.

NB: Since they are defined only for one dimensional array theories,
symbols for singleton and concat are not stored with other array
symbols in the M_Arrays map. Instead, they are stored in a specific
map named M_Arrays_1 which is only populated for one dimensional
arrays.

Comparison Operators
""""""""""""""""""""
Comparison operators (<, >, <=, and >=) are defined for one-dimensional arrays
with a scalar component type. These operators are translated in Why through the
means of a ``compare`` logic function. This function is left uninterpreted, but
its sign is uniquely defined by 3 axioms:

 * ``compare_def_eq`` states that ``compare`` returns 0 if and only if both
   arrays are equal (using Ada equality),
 * ``compare_def_lt`` states that ``compare`` returns a negative number if and
   only if the first array is less than the second (using lexicographic
   ordering), and
 * ``compare_def_gt`` states that ``compare`` returns a positive number if and
   only if the first array is greater than the second.

As an example, here are the axioms used for arrays ranging over a signed integer
type and containing signed integers:

.. code-block:: whyml

  function compare map int int map int int : int

  axiom compare_def_eq :
    forall a b : map.
    forall a_first a_last b_first b_last : int.
      (compare a a_first a_last b b_first b_last = 0 <->
          bool_eq a a_first a_last b b_first b_last = True)

  axiom compare_def_lt :
    forall a b : map.
    forall a_first a_last b_first b_last : int.
      (compare a a_first a_last b b_first b_last < 0 <->
         exists i j : int. i <= a_last /\ j < b_last /\
             (bool_eq a a_first i b b_first j = True /\
             (i = a_last \/
              i < a_last /\ to_rep (get a (i + 1)) < to_rep (get b (j + 1)))))

  axiom compare_def_gt :
    forall a b : map.
    forall a_first a_last b_first b_last : int.
      (compare a a_first a_last b b_first b_last > 0 <->
         exists i j : int. i <= b_last /\ j < a_last /\
             (bool_eq a a_first j b b_first i = True /\
             (i = b_last \/
	      i < b_last /\ to_rep (get a (j + 1)) > to_rep (get b (i + 1)))))

To avoid polluting the context with unnecessary axioms when ``compare`` is not
used, these declarations are grouped in a separate module. For example, here is
the module which would be declared for ``My_Array``:

.. code-block:: whyml

  module Array__Int__Standard__natural_Comp

    function compare map int int map int int : int

    ...
  end Array__Int__Standard__natural_Comp

Logical Operators
"""""""""""""""""

Ada also defines logical operators (and, or, xor, not) for one-dimensional
arrays whose component type is a boolean subtype. These operators are all
translated as uninterpreted logic functions. Definitions applying the underlying
operator on each element of the arrays are given through axioms. As an example,
consider the array type ``Bool_Array`` defined as follows:

.. code-block:: ada

   type Bool_Array is array (Positive range <>) of Boolean;

Here is the axiom generated for the operator xor on ``Bool_Array``:

.. code-block:: whyml

  module Array__Int__Bool__Bool_Op
    use bool.Bool

    function xorb map int int map int int : map

    axiom xorb_def:
     forall a b : map.
     forall a_first a_last b_first b_last : int.
     forall i : int.
       a_first <= i <= a_last ->
       get (xorb a a_first a_last b b_first b_last) i =
            Bool.xorb (get a i) (get b (i - a_first + b_first))

    ...

As explained in section Enumerations, subtypes of Boolean types are
generally translated as boolean in Why. However, it is not the case for subtypes
of Boolean which define their own ranges (see ``Is_Standard_Boolean_Type``).
Those are translated as mathematical integers, just like other enumeration
types. The defining axioms for logical operations on such type therefore need
to introduce conversions. For example, for the following type:

.. code-block:: ada

   subtype Only_True is Boolean range True .. True;

we generate:

.. code-block:: whyml

   module Array__Int__P__only_true__Bool_Op
    use bool.Bool
    use "_gnatprove_standard".Boolean

    function xorb map int int map int int : map

    axiom xorb_def:
     forall a b : map.
     forall a_first a_last b_first b_last : int.
     forall i : int.
       a_first <= i <= a_last ->
       get (xorb a a_first a_last b b_first b_last) i =
            of_rep (Boolean.to_int
	      (Bool.xorb (Boolean.of_int (to_rep (get a i)))
	            (Boolean.of_int (to_rep (get b (i - a_first + b_first))))))

    ...

Note that the equality test is done on the closed form of ``Only_True``, and not
on its representative type or on ``bool``.
Indeed, we do not want to assume an incorrect axiom when the result
of the boolean operation is out of range (here for example, applications of
xor are always out of range of ``Only_True``).

Constrained Arrays with Static Bounds
"""""""""""""""""""""""""""""""""""""

Array types are translated differently depending on whether they are
statically constrained or not (see Why.Gen.Arrays.Declare_Ada_Array).
For statically constrained array types, no new type is introduced.
Instead, constants are declared for the bounds and the underlying map
type is reused as is.

As an example, let us consider the following array type:

.. code-block:: ada

     type My_Array_100 is array (Positive range 1 .. 100) of Natural;

Here are the declarations generated for it:

.. code-block:: whyml

      function first : int := 1
      function last  : int := 100

      type __t = Array__Int__Standard__natural.map

      function bool_eq (x : __t) (y : __t) : bool =
	Array__Int__Standard__natural.bool_eq x first last
		      y first last

We see that boolean equality on arrays reuses the bool_eq function
introduced for maps with appropriate values for bounds. In a similar
way, whenever references to bounds of statically constrained array
objects are encountered, they are directly translated using the
constants defined above, removing completely the need for storing
these values in the actual object.

Unconstrained or Dynamically Constrained Arrays
"""""""""""""""""""""""""""""""""""""""""""""""

Unlike for statically constrained array objects, array bounds are
stored inside objects of an unconstrained or dynamically constrained
type. To this aim, a new why record type is introduced for them,
containing both the map and the bounds. Bounds themselves are
represented as pairs of values of the closed form of the base type of
the index type (indeed, in Ada, bounds of an array object can be
outside the range of the index type if the array is empty). Here is
for example the module that is generated for the bounds of objects of
type My_Array:

.. code-block:: whyml

    module I1

      type t

      function first t : Standard_integer.integer

      function last t : Standard_integer.integer

      function mk int int : t

      axiom mk_def :
	forall f l : int [mk f l].
	  Standard_integer.in_range f ->
	  Standard_integer.in_range l ->
	  (to_rep (first (mk f l)) = f /\
	    to_rep (last (mk f l)) = l)

      predicate dynamic_property
	(range_first : int) (range_last : int) (low : int) (high : int) =
	Standard_integer.in_range low /\ Standard_integer.in_range high /\
	   (low <= high -> (Standard_positive.in_range low
			 /\ Standard_positive.in_range high))
    end

Here first and last are of type Integer (the base type of Positive)
but the dynamic property for the type states that, if the array is non
empty (low <= high) then the bounds must be in Positive. The
additional parameters range_first and range_last stand for the first
and last bounds of the index type. Here they are unused because
Positive is static, so its range predicate does not request them. For
an index type with dynamic bounds, we would have used the appropriate
dynamic_property which takes these additional parameters.

For an array type of dimension n, n modules like the one above are
generated. They are then used to define the actual why translation of
the array type. Here are the declarations introduced for the My_Array
type:

.. code-block:: whyml

      type __t = { elts: Array__Int__Standard__natural.map; rt : I1.t }

      function to_array (a : __t) : Array__Int__Standard__natural.map =
	a.elts

      function of_array (a : Array__Int__Standard__natural.map)
	  (f l : int) : __t =
	{ elts = a; rt = I1.mk f l }

      function first (a : __t) : int = to_rep (I1.first a.rt)
      function last (a : __t) : int = to_rep (I1.last a.rt)
      function length (a : __t) : int =
	if first a <= last a then
	 last a - first a + 1
	else 0

      predicate dynamic_property (range_first range_last f1 l1 : int) =
	I1.dynamic_property range_first range_last f1 l1

      function bool_eq (x : __t) (y : __t) : bool =
	Array__Int__Standard__natural.bool_eq
	  x.elts (first x.rt) (last x.rt)
	  y.elts (first y.rt) (last y.rt)

The type __t defined for objects of type My_Array is record holding
one set of bounds (since the type has one dimension) and an infinite
map of naturals. The theory also provides conversion functions to and
from the representative map type as well as getters computing the
first and last bounds, as well as the length of the array. A
dynamic_property predicate for the array is introduced which groups
all dynamic properties on indexes (here there is only one). Finally,
the predefined equality bool_eq on arrays is defined in terms of the
bool_eq function defined in the representative map theory.

Note that these declarations are not generated directly by Gnat2why,
instead they are given in abstract modules Unconstr_Array(_<dim>) in
the ada_model.mlw file (similar modules names Constr_Array(_<dim>) are
declared for statically constrained array types). These modules are
then cloned by Gnat2why as appropriate (see
Declare_Unconstrained/Declare_Constrained declared in Why.Gen.Arrays).

Conversions
"""""""""""

Most array conversions can be handled by going to the underlying map
type and then apply some sliding if necessary. However, Ada also
allows converting between arrays with different component types, as
long as the component subtype are statically matching. To handle this
case, we introduce specific Why modules containing conversion
functions between distinct map types. Just like representative
theories, these conversion theories are introduced on the fly,
whenever a conversion requesting them is encountered (see
Why.Gen.Arrays.Create_Array_Conversion_Theory_If_Needed). They are
then stored in a map mapping pairs of representative theory names to
conversion symbols (see Why.Atree.Modules.M_Arrays_Conversion). The
appropriate symbol for converting between two array types with
different component types can then be retrieved using the function
Get_Array_Conversion_Name from Why.Gen.Arrays.

As an example, assume we want to convert between the two following
types:

.. code-block:: ada

   type My_Array is array (Positive range <>) of Natural;

   subtype My_Natural is Natural;
   type My_Array_2 is array (Positive range <>) of My_Natural;

Here is the module that will be defined for the conversion from My_Array to My_Array_2:

.. code-block:: whyml

    module Array__Int__Standard__natural__to__Array__Int__my_natural

     function convert (a : Array__Int__Standard__natural.map) :
					   Array__Int__my_natural.map

     axiom convert__def :
      (forall a : Array__Int__Standard__natural.map.
	let b = (convert a) in
	(forall i  : int.
	 to_rep (Array__Int__Standard__natural.get a i) =
	 to_rep (Array__Int__my_natural.get b i)))
    end

The defining axiom for convert states that both maps contain the same
elements. Note that here we need to go to the representative type of
elements to be able to compare them, as their closed types are
different.

NB: Converting between array types with different representative
indexes is not supported yet. To support it, we would probably need to
introduce similar modules with a slightly more complex axiom involving
conversions between indices.

Array Attributes
""""""""""""""""

Record Types, Private Types, and Concurrent Types
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Types that are allowed to have discriminants (record types, task
types, protected types, private types…) are translated as record types
in Why using a single mechanism (see
``Gnat2why.Util.Is_Record_Type_In_Why``). The translation is done in two
phases, first a representative record theory is declared for the type
(see Why.Gen.Records.Declare_Rep_Record_Type), and then a specific
theory is declared, which uses this representative theory (see
Why.Gen.Records.Declare_Ada_Record). This allows sharing a
representative type between record types of a given hierarchy which
have the same components to avoid conversions (see
Oldest_Parent_With_Same_Fields).

Representative Type
"""""""""""""""""""

The representative type of a type which can have discriminants is a
why record type with immutable fields. Mutation of components is
handled by modifying the whole object. A representative why record
type has a layered structure.

At the top-level, a field is defined for each kind of information that
needs to be stored in the object (discriminants, components, tag…)
(see ``Gnat2why.Util.Count_Why_Top_Level_Fields``). Fields for components
or discriminants are themselves records holding the values of the
actual components.

As an example, consider the following record type:

.. code-block:: ada

     type My_Rec (L : Natural) is record
        H : Integer;
     end record;

Its representative type has two top-level fields, one for the
discriminants and one for the components:

.. code-block:: whyml

      type __split_discrs =
	{ rec__my_rec__l : Standard__natural.natural }

      type __split_fields =
	{ rec__my_rec__h : Standard__integer.integer }

      type __rep = { __split_discrs : __split_discrs;
		     __split_fields : __split_fields }

The field __split_discrs contains every discriminant of the type. As
no discriminant can be added to a record hierarchy, all types of a
given hierarchy have the same discriminants. The field __split_fields
contains every component of the type that can be visible in SPARK as
well as Part_Of variables for single protected objects. Note that some
components that are hidden by private derivation may be removed by the
frontend from the component list of record types. As we still want
them in SPARK, we use a table which stores every component of a record
(see ``Gnat2why.Tables.Get_Component_Set``). In the case of tagged types,
these hidden fields can have the same names as other (visible or not)
components. To differentiate them, record fields in Why are prefixed
by the full name of the first type in which they occur (rec__my_rec__h
and not only rec__h).

When the type is derived, or when a subtype is defined, the
representative type is preserved if both no new components are added
(untagged derivation) and there are no component whose type changes in
the derivation (discriminant dependent components). As it is the case
in our example, the following My_Rec_100 subtype will have the same
representative type as My_Rec:

.. code-block:: ada

      subtype My_Rec_100 is My_Rec (100);

Let us consider a slightly different example where My_Rec contains a
discriminant dependent component:

.. code-block:: whyml

     type My_Rec (L : Natural) is record
        C : My_Array (1 .. L);
     end record;

Here, My_Rec_100 will define a new representative type in which the C
component has the more precise My_Array (1 .. 100) type. However, as
discriminants themselves cannot be discriminant dependent, the type
for the discriminants field will be preserved:

.. code-block:: whyml

     type __split_fields =
      { rec__my_rec__c : Array__Int__Standard__natural.map }

     type __rep =
      { __split_discrs : P__my_rec.__split_discrs;
	__split_fields : __split_fields }

Discriminant checks
"""""""""""""""""""

There are two kinds of discriminant checks for types with
discriminants. First, components that are under a variant require a
check when accessed. In Gnat2why, information about record variants is
computed once and for all and then stored in Gnat2why.Tables. It can
be retrieved using Has_Variant_Info and Get_Variant_Info.

For all components of a record type, a predicate is defined that
checks whether the component is present in a record object depending
on the value of its discriminants if any. In the simplest case, if the
record has no discriminant or if the component is not nested in a
variant part, this predicate simply returns True.

As an example, let us consider a record type with a variant part:

.. code-block:: ada

     type My_Rec (L : Natural) is record
	case L is
	when 0 =>
	   null;
	when others =>
	   C : My_Array (1 .. L);
	end case;
     end record;

The C component is only defined in a record if its discriminant is not
zero. This is expressed in its associated discriminant predicate:

.. code-block:: whyml

     predicate types__c__pred (a : __rep)  =
         not (to_rep a.__split_discrs.rec__my_rec__l = 0)

A discriminant check is also needed for types and subtypes with
discriminant constraints to check inclusion of a record in the type /
subtype. If a type or a subtype is constrained, a range predicate is
defined for this check. As an example, here is the range predicate
that would be defined for the My_Rec_100 subtype:

.. code-block:: whyml

     predicate in_range (rec__my_rec__l : int) (a : my_rec)  =
       rec__types__my_rec__l = to_rep a.__split_discrs.rec__my_rec__l

Note that the actual value of the discriminant is not inlined here,
but rather needs to be supplied at each call. This is because this
value may depend on variables, in particular if the subtype is defined
in a loop (loop indices are translated as variables in Why).

Private components
""""""""""""""""""

As stated at the beginning of the section, SPARK always uses the most
precise view of types that is available to it. However, it can happen
that a type is completely or partially hidden from SPARK analysis
under a SPARK_Mode (Off) pragma (see
``Gnat2why.Tables.Has_Private_Part``). When this is the case, SPARK cannot
just ignore the components it is not allowed to see. Instead, it
creates a special field for them, named rec__t for a type T, of an
abstract logic type. As an example, let us consider a semi private
type, of which we can only see the discriminants:

.. code-block:: ada

       package P  is
	  type Priv (B: Boolean) is private;
       private
	  pragma SPARK_Mode (Off);
	  type Priv (B: Boolean) is null record;
       end P;

Here is how it is translated in Why:

.. code-block:: whyml

     type __main_type

     type __split_discrs = { rec__priv__b : bool }

     type __split_fields = { rec__priv : __main_type }

     type __rep =
      { __split_discrs : __split_discrs;
	__split_fields : __split_fields }

As __main_type has no definition, we can deduce nothing about the
rec_priv field, not even whether it actually can take several values
or not.

Record equality
"""""""""""""""

Predefined equality on record types is the conjunction of equalities
on every components. If a component is ultimately a record type, the
primitive equality should be used for it instead of the predefined
equality (see Why.Gen.Expr.New_Ada_Equality). Predefined equality is
generated in the representative module, as it is shared between record
types with same fields. Conversely, the primitive equality symbol
user_eq is declared in specific modules as it can be overridden after
derivation.

As an example, let us consider a the following type structure:

.. code-block:: ada

      type My_Rec (L : Natural) is record ...;

      subtype My_Rec_100 is My_Rec (100);

      type Rec_Eq is new My_Rec (100);

      function "=" (X, Y : My_Rec_2) return Boolean;

      type Big_Rec (B : Boolean) is record
	 X : My_Rec_100;
	 Y : Rec_Eq;
      end record;

Here is the predicate defined for predefined equality on type Big_Rec:

.. code-block:: whyml

    function bool_eq (a : __rep) (b : __rep) : bool =
      (a.__split_discrs.rec__big_rec__b =
       b.__split_discrs.rec__big_rec__b)
      /\ (types__big_rec__x__pred a ->
	     P__my_rec_100.bool_eq
			 a.__split_fields.rec__big_rec__x
			 b.__split_fields.rec__big_rec__x)
      /\ (types__big_rec__y__pred a ->
	    P__rec_eq.user_eq
			 a.__split_fields.rec__big_rec__y
			 b.__split_fields.rec__big_rec__y)

We see that it uses the predefined equality on X and the primitive
equality on Y. Also notice that, if the type has discriminants,
equalities on components are only considered if the components are
indeed present (ie when the predicate discriminant check for the
corresponding component returns True).

For types with a private part, an uninterpreted logic function is
introduced to stand for (primitive or predefined) equality on the
private components of the type. It ensures that nothing can be deduced
for this equality, not even that it is reflexive.

For example, here is the predicate defined for predefined equality on
type Priv:

.. code-block:: whyml

     function __main_eq (a : __main_type) (b : __main_type) : bool

     function bool_eq (a : __rep) (b : __rep) : bool =
      (a.__split_discrs.rec__priv__b = b.__split_discrs.rec__priv__b)
      /\ (__main_eq a.__split_fields.rec__priv
		    b.__split_fields.rec__priv)

Mutable discriminants
"""""""""""""""""""""

Objects of a type with mutable discriminants can be either constrained
or unconstrained (information can be get through the ‘Constrained
attribute). It depends on how the object was declared and cannot be
changed throughout the program. In the why translation of record types
with mutable discriminants, the constrained information is kept as a
separate top-level field.

As an example, consider the following type with mutable discriminants:

.. code-block:: ada

     type My_Option (Present : Boolean := False) is record
	case Present is
	   when True  =>
	      Content : Integer;
	   when False =>
	      null;
	end case;
     end record;

Its representative type contains three fields, one for the
discriminant, one for the field, and an additional boolean flag for
the ‘Constrained attribute:

.. code-block:: whyml

     type __rep =
      { __split_discrs    : __split_discrs;
        __split_fields    : __split_fields;
        attr__constrained : bool }

During assignment of an object with mutable discriminants, care must
be taken to preserve the value of the attr__constrained flag (see
``Gnat2why.Expr.New_Assignment``).

Note that the ‘Constrained attribute on record or array components is
not always the value of the attr_constrained field of the components.
Indeed, to be able to handle assignment of composite objects easily,
the attr_constrained field is always set to False if the component
type is unconstrained whereas ‘Constrained always returns True on
(parts of) constant objects (see ``Gnat2why.Expr.Transform_Attr``).

Conversions
"""""""""""

When two types of a record hierarchy share the same representative
type, no conversion is required. Otherwise, conversions go through the
root type of the hierarchy. More precisely, for every record type or
subtype which is not a root, two conversion functions, to and from the
root type are introduced. As an example, here are the conversion
functions introduced for My_Rec_100:

.. code-block:: whyml

     function to_base (a : __rep) : my_rec =
      {__split_discrs = a.__split_discrs;
       __split_fields =
	{ rec__my_rec__c =
		(of_array a.__split_fields.rec__my_rec__c 1 100) }}

     function of_base (r : my_rec) : __rep =
      { __split_discrs = r.__split_discrs;
	__split_fields =
	{ rec__my_rec__c = (to_array a.__split_fields.rec__my_rec__c) }

As no new discriminant can be introduced in derivation, the field for
discriminants is always preserved. As for regular components, they may
require a conversion if their type has changed, like here for the C
component.

Tagged types
""""""""""""

An object of a tagged type T has the particularity that it can in fact
be a view conversion of an object of descendant of T. To represent
tagged objects, we therefore need a tag, which allows to specialize
treatment when necessary (conversions, dispatching, tag checks…), as
well as a way to store an unknown number of unknown components which
may arise from future derivations.

The tag is represented by an additional top-level field of
mathematical integer type named attr__tag. The concrete value of this
field is never specified. However, each time a record type is
introduced, an abstract logic constant is introduced to represent the
specific tag of objects of this type. This allows to specify the value
of the tag of an object when it is known, so that the object can be
handled more precisely.

In addition to the attr__tag top-level field, tagged types also have a
special regular field named rec__ext__ of the abstract __private type.
It is stored in the __split_fields top-level field, along with other
components and stands for potential hidden component of derived types.

As an example, let us consider the following tagged type:

.. code-block:: ada

     type Root is tagged record
        F : Integer;
     end record;

The why type introduced for it contains two top-level fields, one for
components and one for the tag, and its component field contains a
special component for extensions:

.. code-block:: whyml

     type __split_fields =
      { rec__root__f : Standard__integer.integer;
	rec__ext__ "model_trace:" : __private }

     type __rep =
      { __split_fields : __split_fields;
	attr__tag      : int }

Like for other record types, tagged conversions do through the root of
the type hierarchy. For each tagged type which is not a root, logic
functions are provided to hide components that are not present in the
root type inside the extension and to retrieve them. Note that always
going through the root type may cause some loss of precision when
going from two types which share some components that are not in the
root.

As an example, let us consider a tagged extension of Root named Child:

.. code-block:: ada

     type Child is new Root with record
        G : Integer;
     end record;

Like for Root, the translation of Child has a top-level attr__tag
field as well as a regular rec__ext__ field to store potential
extensions:

.. code-block:: whyml

     type __split_fields =
      { rec__child__g : Standard__integer.integer;
	rec__root__f  : Standard__integer.integer;
	rec__ext__    : __private }

     type __rep =
      { __split_fields : __split_fields;
	attr__tag      : int }

Then, conversions to and from the Root type are defined through the
mean of abstract hide and extraction functions. The result of calling
the extraction functions on the result of a call to the hide function
is given through the mean of an axiom:

.. code-block:: whyml

     function hide_ext__ (g : Standard__integer.integer)
			  (rec__ext__ : __private) :__private

     function extract__g (x : __private) : Standard__integer.integer

     axiom extract__g__conv :
      (forall g : Standard__integer.integer.
      (forall rec__ext__ : __private.
       ((extract__g (hide_ext__ g rec__ext__)) = g)))

     function extract__ext__(x : __private) : __private

     function to_base (a : __rep) : P__root.root =
      {__split_fields =
	    {rec__root__f = a.__split_fields.rec__root__f;
	     rec__ext__ = (hide_ext__ a.__split_fields.rec__child__g
				      a.__split_fields.rec__ext__) };
       attr__tag = a.attr__tag }

     function of_base (r : May_package__root.root) : __rep =
      { __split_fields =
	 { rec__child__g = (extract__g r.__split_fields.rec__ext__);
	   rec__root__f = r.__split_fields.rec__root__f;
	   rec__ext__ = (extract__ext__ r.__split_fields.rec__ext__) };
       attr__tag = r.attr__tag }

To avoid losing information when converting between types which share
a component which is not in the root, the same extraction function is
reused for every type which share the same component. As an example, a
type:

.. code-block:: ada

     type Grand_Child is new Child with record
        H : Integer;
     end record;

Will reuse the extraction function for G declared in Child’s
representative module:

.. code-block:: whyml

     function extract__g (x : __private) : Standard__integer.integer =
        P__child.extract__g x

Note that, as the hide function itself is not preserved, we still need
to introduce a new axiom for G in Grand_Child:

.. code-block:: whyml

     axiom extract__g__conv :
      (forall h g : Standard__integer.integer.
      (forall rec__ext__ : __private.
       extract__g (hide_ext__ h g rec__ext__) = g))

Equality on specific tagged type only compares fields that are visible
in the current view of the objects. So the equality between view
conversions to Root of two objects of type Child will still compare
only the F component:

.. code-block:: whyml

     function bool_eq (a : __rep) (b : __rep) : bool =
      (to_rep a.__split_fields.rec__root__f =
       to_rep b.__split_fields.rec__root__f)

On the other hand, when comparing objects of a classwide type, a check
is first made that the tags match and then the appropriate equality is
used. This behavior is not modelled precisely in SPARK. Instead, an
abstract function __dispatch_eq is introduced in every root type to
stand for the dispatching equality in the hierarchy (see
``Gnat2why.Expr.New_Op_Expr``):

.. code-block:: whyml

     function __dispatch_eq (a : __rep) (b : __rep) : bool

Record Attributes and Component Attributes
""""""""""""""""""""""""""""""""""""""""""

type.tag

Special Cases
"""""""""""""

As record types in Why must contain at least one field, untagged null
records are translated specifically by Gnat2why as an abstract type.
To allow conversions between types of a hierarchy of null records, the
abstract type introduced for the root of the hierarchy is reused by
descendants. Therefore, conversion functions on null record types are
always the identity. As for the predefined equality function, it is
the True function since there is only one object of a null record
type.

As an example, let us consider an untagged null record type:

.. code-block:: ada

    type Null_Rec is null record;

Here are the Why declarations introduced for it:

.. code-block:: whyml

    type null_rec

    function to_base (a : null_rec) : null_rec = a

    function of_base (r : null_rec) : null_rec = r

    function bool_eq (a : null_rec) (b : null_rec) : bool = True

On derived null record types:

.. code-block:: ada

    type Null_Rec_2 is new Null_Rec;

The type of the root is reused:

.. code-block:: whyml

    type null_rec_2 = P__null_rec.null_rec

Simple private types are untagged private types with no discriminants
whose full view is not in SPARK:

.. code-block:: whyml

      package P is
	 type Priv is private;
      private
	 pragma SPARK_Mode (Off);
	 type Priv is new Integer;
      end P;

As such types are used by advanced users to model mathematical types
(unbounded integers, reals…), we keep their translation as simple as
possible to facilitate the task of mapping them to interpreted types
inside proof assistants. Unlike for null record types, we introduce a
representative theory for them, but a minimalist one, where the
representative type is left abstract and predefined equality is
undefined:

.. code-block:: whyml

     type __rep

     function to_base (a : __rep) : __rep =  a

     function of_base (a : __rep) : __rep = a

     function bool_eq (a : __rep) (b : __rep) : bool

For record types which are clones of other types, mostly classwide
types and cloned subtypes (see Why.Gen.Records.Record_Type_Is_Clone),
no new representative module is introduced and the specific module is
simply a clone of the existing cloned type:

.. code-block:: whyml

    module Types__TrootC
     use export Types__root
    end

Additionally, if the cloned type has a different name from the new
type, a renaming is introduced for the record type.

Access Types
^^^^^^^^^^^^
Representative Modules
""""""""""""""""""""""
Access types with the same designated type share a single representative type,
so that it is possible to convert between them. This is necessary even though
we cannot convert between different pool specific access types. Indeed, we still
need all (named) access types to be convertible to anonymous access types. This
representative type is declared inside a representative module. It is introduced
for the first access to a given type translated, then it is reused for the
following access types with the same designated type.

This representative type has three fields. One for the value, one for the
address (represented as a mathematical integer), and a boolean flag to register
whether the access object is null. As an example, consider an access type to
natural numbers:

.. code-block:: ada

  type Ptr is access Natural;

Here is the representative type introduced for it:

.. code-block:: whyml

   type __rep =
     { p__ptr__is_null_pointer : bool;
       p__ptr__pointer_address : int;
       p__ptr__pointer_value   : natural }

Since the address of an access object cannot be retrieved in SPARK, the value
of the address field is never accessed directly in the program. It is only used
so that two access objects pointing to different memory cells which happen to
contain the same object are not considered equal.

Along with the representative type, the presentative module contains other
declarations which are shared between access types. Among them, the null
pointer, a protected access function which checks whether a pointer is null
before returning its value, and the primitive equality over access objects. Here
are these declarations for the ``Ptr`` type defined above:

.. code-block:: whyml

   function __null_pointer : __rep

   axiom __null_pointer__def_axiom :
      __null_pointer.rec__p__ptr__is_null_pointer = True

   val rec__p__ptr__pointer_value_
     (a : __rep) : Standard__natural.natural
    requires { not a.rec__p__ptr__is_null_pointer }
    ensures  { result = a.rec__p__ptr__pointer_value }

   function bool_eq  (a : __rep) (b : __rep) : bool =
      a.rec__p__ptr__is_null_pointer = b.rec__p__ptr__is_null_pointer
   /\ (not a.rec__p__ptr__is_null_pointer ->
          a.rec__p__ptr__pointer_address = b.rec__p__ptr__pointer_address
       /\ a.rec__p__ptr__pointer_value = b.rec__p__ptr__pointer_value)

Remark that primitive equality does not only require that two non-null access
objects have the same address to be equal but also that they have the same
value.
This is compatible with the execution model, since two non-null access objects
which share the same address will necessarily have the same value. However, this
invariant does not hold for proof, where we can see the value of the same access
object at different program points. Thus, we need to insert additional
information about values into equality so that we know that, when two access
objects are equal, they designate the same value.

Allocators
""""""""""
Following the SPARK RM, allocators are considered to have an effect on the
global memory area, and therefore should only be used in non-interfering
contexts. Like for volatile functions, we only introduce program
functions for allocators, and not logic functions.

These functions read and
modify a global reference to a mathematical integer named
``__next_pointer_address``, also declared in the representative module of the
access type. This integer is used as the address of the allocated value.
The idea was to have an invariant stating that the value of these references
is always increasing so that we could prove that a newly allocated pointer is
different from an existing one, but this is not implemented.

Here are the program functions introduced for initialized and uninitialized
allocators for ``Ptr``:

.. code-block:: whyml

 val __next_pointer_address  : int__ref
 val __new_uninitialized_allocator (_ : unit) : __rep
  requires { true }
  ensures  { not result.rec__p__ptr__is_null_pointer
		&& result.rec__p__ptr__pointer_address = __next_pointer_address.int__content }
  writes   { __next_pointer_address }

 val __new_initialized_allocator (__init_val : int) : __rep
  requires { true }
  ensures  { not result.rec__p__ptr__is_null_pointer
		&& result.rec__p__ptr__pointer_address = __next_pointer_address.int__content
                && result.rec__p__ptr__pointer_value = of_rep __init_val }
  writes { __next_pointer_address }

Both program functions have as a postcondition that the result of the allocation
is not null, and that its address is the next address. Additionally, the
postcondition of the initialized allocator assumes the value of the allocated
data. Note that we do not assume that the value of the uninitialized allocator
is default initialized in its postcondition. It is because uninitialized
allocators can be used with any subtype compatible with the designated subtype.
To handle them precisely, we assume default initialization of each uninitialized
allocated value specifically depending on the subtype used in the allocator.

Subtype Constraints
"""""""""""""""""""
Subtypes of access types to unconstrained composite objects can be supplied with
a composite constraint which applies to the designated values. When generating
the representative module for such an access subtype, we need to introduce
conversion functions to and from the base access type, as well as a range check
function to check membership to the subtype.

For example, consider an access type to unconstrained arrays of natural numbers,
and a subtype of this access type only storing arrays ranging from 1 to 5:

.. code-block:: ada

   type Arr_Ptr is access Nat_Array;
   subtype S is Arr_Ptr (1 .. 5);

Here are the conversion functions and range check predicate generated for ``S``:

.. code-block:: whyml

 function to_base (a : __rep) : p__arr_ptr.arr_ptr =
  { p__arr_ptr.rec__p__arr_ptr__pointer_value = of_array a.rec__p__arr_ptr__pointer_value 1 5;
    p__arr_ptr.rec__p__arr_ptr__pointer_address = a.rec__p__arr_ptr__pointer_address;
    p__arr_ptr.rec__p__ptr__is_null_pointer = a.rec__p__arr_ptr__is_null_pointer }

 function of_base (r : p__arr_ptr.arr_ptr) : __rep =
  { rec__p__arr_ptr__pointer_value = to_array r.p__arr_ptr.rec__p__arr_ptr__pointer_value;
    rec__p__arr_ptr__pointer_address = r.p__arr_ptr.rec__p__ptr__pointer_address;
    rec__p__arr_ptr__is_null_pointer = r.p__arr_ptr.rec__p__ptr__is_null_pointer }

 predicate in_range (first : int) (last : int) (r : p__arr_ptr.arr_ptr)  =
  not r.p__arr_ptr.rec__p__ptr__is_null_pointer ->
   first r.p__arr_ptr.rec__p__ptr__pointer_value = first
   /\ last r.p__arr_ptr.rec__p__ptr__pointer_value = last

We can see that the range predicate for arrays takes the array bounds as
parameters. This is because the bounds may contain references to constants which
are translated as variables in Why (this is similar to what is done for
discriminants in range predicates for records).

The range predicate is used both for checking that a value is in the expected
type, when translating conversions, qualifications, and allocators, and to
translate explicit membership test in the user code.


Type Completion
^^^^^^^^^^^^^^^

In addition to their main and possibly their representation module, types also
have a completion module. This module contains declarations and axioms which
may reference entities (types, functions...) defined after the type declaration.
For example, completion modules for scalar types with dynamic bounds contain
axioms which give the values of the bounds that do not have a static value, see
``Gnat2why.Types.Generate_Type_Completion.Create_Axioms_For_Scalar_Bounds``.

Completion modules are located after modules for declarations but before modules
for checks in the generated mlw file. They have the same name as the main module
they complete but with an additional __axiom suffix. Completion modules
for types are created in ``Gnat2Why.Types.Generate_Type_Completion``.

Predicates / Invariants
"""""""""""""""""""""""
If a type has a subtype predicate or a type invariant, a Why3 predicate is
generated for its expression. For example, let's consider a subtype for sorted
arrays:

.. code-block:: ada

   subtype Sorted_Nat_Array is Nat_Array with
     Predicate => Is_Sorted (Sorted_Nat_Array);

Here is the Why3 predicate generated for it (for readability, names are
simplified and axiom guards are removed):

.. code-block:: whyml

  predicate dynamic_predicate (x : sorted_nat_array) = is_sorted x

In SPARK, subtype predicates and type invariants are not allowed to depend on
variables (see SPARK RM 4.4 (2)). However, as scalar constants are sometimes
translated as variables in Why, it is possible for the Why3 expression
associated to such an aspect specification to reference a Why3 variable. In such
a case, the Why3 predicate generated for the invariant or predicate will take
the variable as an additional parameter. Here is an example:

.. code-block:: ada

   for I in 1 .. 10 loop
      declare
         subtype Dynamic_Bounds is Integer with
           Predicate => Dynamic_Bounds in 1 .. I;
      begin
         ...

Because loops are sometimes (partially) unrolled, scalar constants declared in
loops, and in particular loop indexes, are
translated as variables in Why. As a result, the predicate of type
``Dynamic_Bounds`` will have as an additional parameter the value of the loop
index at the current iteration:

.. code-block:: whyml

 predicate dynamic_predicate (x : int) (L_1__i : int) = 1 <= x <= L_1__i

Default initialization
""""""""""""""""""""""

For types which can be default initialized (ie. definite subtypes, see
``Can_Be_Default_Initialized``), a Why3 predicate named
``default_initial_assumption`` is defined for the type. It can be used to
express that a value of this type has been obtained by default initialization.
Note that even types which do not define full default initialization have a
``default_initial_assumption`` predicate. Parts of types which do not have
default values are simply left unspecified by the predicate. For example,
Ada does not define a default value for the standard type ``Integer``. A
predicate for the default initial assumption of values of type ``Integer`` is
still generated as variables of this type can be left uninitialized, but it does
not give any information on the value of its parameter:

.. code-block:: whyml

 predicate default_initial_assumption (x : int) (skip_top_level : bool) =
  true

As can be seen on the example above, the ``default_initial_assumption``
predicate takes a boolean ``skip_top_level`` argument in addition to the value
``x`` for which we want to assume default initialization. This argument can be
used to short circuit the top-level default initial condition of the type if
any. For example, consider the following ``Holder`` type which is empty when
default initialized:

.. code-block:: ada

   package P is
      type Holder is private with
        Default_Initial_Condition => Is_Empty (Holder);

      function Is_Empty (X : Holder) return Boolean;
   private
      type Holder is record
         Present : Boolean := False;
         Content : Natural := 0;
      end record;
      function Is_Empty (X : Holder) return Boolean is (not X.present);
   end P;

We can see that its default initial condition is ignored if ``skip_top_level``
is set to true:

.. code-block:: whyml

 predicate default_initial_assumption (x : holder) (skip_top_level : bool) =
  holder.__split_fields.rec__present = false /\
  to_rep (holder.__split_fields.rec__content) = 0 /\
  (if skip_top_level then true else is_empty holder)

This short-circuit is used in particular in code that checks the
``Default_Initial_Condition`` aspect itself, see
``Gnat2Why.Expr.Check_Type_With_DIC``. It is also used to ignore default
initial conditions when checking that type invariants and subtype predicates
hold on default values, since the default initial condition itself is checked
assuming all applicable invariants and predicates (at least when the default
initial condition is checked at declaration, see ``Needs_DIC_Check_At_Decl``
and ``Needs_DIC_Check_At_Use``).

Dynamic invariants
""""""""""""""""""
Not all information provided by Ada types is encoded into the corresponding
Why3 types. Here are some examples of information missing from Why3 types (see
``Gnat2Why.Expr.Compute_Dynamic_Invariant`` for the exhaustive list):

 * Type predicates and invariants,
 * Bounds of empty or dynamically constrained scalar types,
 * Bounds of dynamically constrained array types,
 * Discriminants of constrained record types...

This additional information is supplied by the mean of assumptions all over Why3
programs. It is assumed for inputs on subprogram entry (see
``Compute_Dynamic_Property_For_Inputs``), added to the postcondition of
subprograms for subprogram outputs, assumed inside loops as implicit invariants
etc. To make these assumptions easier and to improve readability in the Why3
files, a Why3 predicate named ``dynamic_invariant`` is defined
in the completion of every type entity (except for Itypes as they may depend on
locally defined constants such as 'Old; dynamic invariants of Itypes are
recomputed when needed, see ``Compute_Dynamic_Invariant``).

To see how this all works together, let's consider some examples. First,
here is a simple integer type with dynamic bounds:

.. code-block:: ada

   type Dyn_Int is new Integer range - Max .. Max;

Constants have already been introduced for its bounds, but ``Dyn_Int`` itself is
translated as a renaming of ``Integer``. The dynamic invariant of ``Dyn_Int``
simply states that its parameter is in the expected bounds:

.. code-block:: whyml

 predicate dynamic_invariant (expr : int) (is_init : bool)
    (skip_constant : bool) (do_toplevel : bool) (do_typ_inv : bool)  =
  (if is_init \/ dyn_int.first  <= dyn_int.last then
      dyn_int.first <= expr <= dyn_int.last
   else true)

We see that, in addition to its main ``expr`` parameter, ``dynamic_invariant``
takes 4 boolean arguments:

 * ``is_init`` is used to avoid assuming unsound properties if ``expr`` is
   not known to be initialized. We see it in use here, where it prevents
   assuming that ``expr`` is in an empty range unless it is known to be
   initialized (in which case an error will have been raised at the
   initialization of ``expr``).
 * ``skip_constant`` allows to skip the dynamic invariant which applies to
   constant parts of ``expr`` (array bounds, discriminants...). This is used to
   avoid polluting the context with already known facts.
 * ``do_toplevel`` allows to skip the toplevel type predicate applied to
   ``expr`` if any. This is used to check the predicate itself for absence of
   runtime errors.
 * ``do_typ_inv`` allows to skip all invariants that may apply to ``expr`` or
   to one of its components. This is used to avoid introducing soundness issues
   when translating private subprograms from boundary packages, as they are
   allowed to break the invariant.

Let's now consider a more complex example. We can declare an option type
with a mutable discriminant containing a value of type ``Dyn_Int``, but only
when the discriminant is True:

.. code-block:: ada

   type Result_Type (Found : Boolean := False) is record
      case Found is
      when True  =>
        Result : Dyn_Int;
      when False =>
         null;
      end case;
   end record;

Here is its dynamic invariant:

.. code-block:: whyml

 predicate dynamic_invariant (expr : result_type) (is_init : bool)
    (skip_constant : bool) (do_toplevel : bool) (do_typ_inv : bool) =
  (if p__result_type__result__pred expr then
    (if is_init \/ dyn_int.first  <= dyn_int.last then
      dyn_int.first <= dyn_int.to_rep expr.__split_fields.result <= dyn_int.last
     else false)
  else false)

We see that dynamic invariants of composite types repeat the dynamic invariants
of their components. As ``Result_Type`` has discriminant, the dynamic property
of the ``Result`` component is only assumed if the component is present. Note
that the ``dynamic_invariant`` predicate of components is not reused here. This
sometimes allows simplifications.

Let us now consider an unconstrained array of ``Result_Type``:

.. code-block:: ada

   type Result_Array is array (Positive range <>) of Result_Type;

Like for records, its dynamic invariant contains the invariant of its
components, but it also contains information about its bounds, which are only
assumed if ``skip_constant`` is false:

.. code-block:: whyml

 predicate dynamic_invariant (expr : result_array) (is_init : bool)
    (skip_constant : bool) (do_toplevel : bool) (do_typ_inv : bool) =
  (if skip_constant then true
   else dynamic_property Standard__positive.first Standard__positive.last
           (first expr) (last expr))
  /\ (forall i : int.
        (if (first expr) <= i <= (last expr) then
            ... (* dynamic invariant of get (to_array expr) i *)
            /\ (get (to_array expr) i).attr_constrained = False
         else true))

Note that, in addition to the dynamic invariant of ``Result_Type`` which is not
repeated here, the dynamic invariant also assumes that elements of ``expr`` are
unconstrained. Indeed, if it is not true in general that records with defaulted
discriminants are unconstrained, but it always holds when such elements are
nested in a composite type.

As a last example, lets use this array type to define a type of stacks. This
type contains a dynamically constrained subtype of ``Result_Array`` and features
a subtype predicate:

.. code-block:: ada

   type Result_Stack (Max : Natural) is record
      Content : Result_Array (1 .. Max);
      Length  : Natural;
   end record
     with Predicate => Length in 0 .. Max;

The frontend introduces an entity for the type of the content component. As
this entity is an Itype, it does not have its own dynamic invariant. However,
we will see it inlined in the invariant of ``Result_Stack``:

.. code-block:: whyml

 predicate dynamic_invariant (expr : result_stack) (is_init : bool)
    (skip_constant : bool) (do_toplevel : bool) (do_typ_inv : bool) =
  (if do_toplevel then
   (if is_init then
     0 <= to_rep expr.__split_fields.length <= to_rep expr.__split_discrs.max
    else true)
   else true) /\
   (if p__result_stack__content__pred expr then
       first expr.__split_fields.content = 1
    /\ last expr.__split_fields.content = to_rep expr.__split_discrs.max
    /\ (forall i : int. ...

The first conjunct of the dynamic invariant of ``Result_Stack`` concerns the
subtype predicate. We see that it only holds if ``do_toplevel`` and ``is_init``
are true (that is, if ``expr`` is initialized and if we do not intentionally
skip this predicate). The second conjunct is the invariant of the ``Content``
component (the ``Length`` component has no dynamic invariant, it is of  a static
scalar type, all necessary information is contained in its Why3 type). The
first part of the invariant of ``Content`` assumes the value of its bounds.
Note that this assumption is done even when ``skip_constants`` is true.
Indeed, constant parts of objects are only split in different object at the
top level. As a consequence, Why3 does not know that the bounds are constant
for nested arrays, and we need to assume it.

User equality
"""""""""""""
If primitive equality over a type which ultimately is a record is redefined by
the user, an axiom is provided to supply a definition for the primitive
equality function ``user_eq`` in the completion of the type entity. For example,
consider a type with two components, a ``Main`` component, which is the one we
care about, and another ``Ignored`` component which is only used for some
secondary usage, like logging. We define equality on this record type as
equality of the ``Main`` component only:

.. code-block:: ada

   type T_Rec is record
      Main    : Integer;
      Ignored : Integer;
   end record;

   function "=" (X, Y : T_Rec) return Boolean is (X.Main = Y.Main);

The "=" function above is translated as a normal function, producing a Why3
logic function named ``P__Oeq.oeq``. Using this function, we can define the
value of the generic primitive equality function ``user_eq`` introduced for
``T`` (see the section about Record Equality for usage of ``user_eq``):

.. code-block:: whyml

 axiom user_eq__def_axiom :
  (forall a b : t_rec__. P__t_rec.user_eq a b = P__Oeq.oeq a b)

Wrapper types for initialization by proof
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Initialization by proof is currently in a prototype stage. The idea is to relax
additional initialization rules imposed by SPARK on some types and to verify
initialization as precisely as possible using proof instead of flow analysis.
This prototype was implemented to answer a user need for procedures only
initializing parts of an object, or only initializing objects conditionally.
Here is a motivating example:

.. code-block:: ada

  procedure Init_By_Proof with SPARK_Mode is
   subtype My_Int is Integer;
   pragma Annotate (GNATprove, Init_By_Proof, My_Int);

   type Int_Array is array (Positive range <>) of My_Int;
   --  Array of potentially uninitialized integers

   type Int_Array_Init is array (Positive range <>) of Integer;
   --  Array of integers with normal treatment

   procedure Init_By_4 (A : out Int_Array; Error : out Boolean) with
     Pre  => A'Length = 4,
     Post => (if not Error then A'Valid_Scalars)
   is
   begin
      A := (1 .. 4 => 10);
      Error := False;
   end Init_By_4;

   procedure Read (Buf   : out Int_Array;
                   Size  : Natural;
                   Error : out Boolean)
   with Pre  => Buf'Length >= Size,
        Post => (if not Error then
                 Buf (Buf'First .. Buf'First + (Size - 1))'Valid_Scalars)
   is
      Offset    : Natural := Size mod 4;
      Nb_Chunks : Natural := Size / 4;
   begin
      if Offset /= 0 then
         Error := True;
         return;
      end if;

      for Loop_Var in 0 .. Nb_Chunks - 1 loop
         pragma Loop_Invariant
           (Buf (Buf'First .. Buf'First + (Loop_Var * 4) - 1)'Valid_Scalars);
         Init_By_4 (Buf (Buf'First + Loop_Var * 4 .. Buf'First + Loop_Var * 4 + 3), Error);
         exit when Error;
      end loop;

   end Read;

   procedure Process (Buf  : in out Int_Array;
                      Size : Natural)
   with Pre  => Buf'Length >= Size and then
                Buf (Buf'First .. Buf'First + (Size - 1))'Valid_Scalars,
        Post => Buf (Buf'First .. Buf'First + (Size - 1))'Valid_Scalars
   is
   begin
      for I in Buf'First .. Buf'First + (Size - 1) loop
         pragma Loop_Invariant
           (Buf (Buf'First .. Buf'First + (Size - 1))'Valid_Scalars);
         Buf (I) := Buf (I) / 2 + 5;
      end loop;
   end Process;

   procedure Process (Buf  : in out Int_Array_Init;
                      Size : Natural)
     with Pre => Buf'Length >= Size
   is
   begin
      for I in Buf'First .. Buf'First + (Size - 1) loop
         Buf (I) := Buf (I) / 2 + 5;
      end loop;
   end Process;

   Buf   : Int_Array (1 .. 150);
   Error : Boolean;
   X     : Integer;
  begin
   Read (Buf, 100, Error);
   if not Error then
      X := Buf (10);
      Process (Buf, 100);
      declare
         B : Int_Array_Init := Int_Array_Init (Buf (1 .. 100));
      begin
         Process (B, 50);
      end;
      X := Buf (20);
      X := Buf (110); -- medium: "Buf" might not be initialized
   end if;
  end Init_By_Proof;

In this example, initilization is only assumed if an ``Error`` boolean is
false.  Additionally, ``Read`` always initializes the array partially (up to
``Size``) and initializes the array components four by four, which is currently
out of reach of the very simple heuristic used by flow analysis to recognize
loops which fully initialize an array.

For now, we recognize objects for which we want to handle initialization by
proof by supplying a ``pragma Annotate (GNATprove, Init_By_Proof, Ty)`` on their
type ``Ty``. This pragma can only be supplied on scalar types. We then consider
all composite types containing a type with ``Init_By_Proof`` as
``Init_By_Proof`` too, and we enforce in marking that such composite types only
contain components of a type with ``Init_By_Proof``. We use the existing
attribute ``Valid_Scalars`` to express that an object is completely initialized.

In our example, initialization of objects of type ``Init_Array`` is handled by
proof whereas objects of type ``Init_Array_Init`` are handled by flow analysis.
We see on the two versions of ``Process`` that having initialization handled
by proof requires supplying more annotations as it relaxes assumptions on
subprogram boundaries.

Here are the basic ideas of how this prototype works:

* We introduce wrapper types for types which need their own initialize flag, see
  ``Needs_Wrapper_Type`` and ``Translate_Type``. Currently, we only do it for
  scalar types, but later we will also need it for types with predicates. So the
  machinery for handling types with ``Init_By_Proof`` is not reduced to scalar
  types (for example, we consider that all kinds of binders can have an
  initialization field in ``Insert_Ref_Context``). These types are used for
  components of composite types.

* We introduce a new field in ``Item_Type`` named Init. It optionally contains
  an identifier for the init flag for a variable (currently it is only used for
  scalar variables, that is, for regular binders). The flag is only present when
  necessary, ie when the object may not be initialized (for out parameters and
  variables initialized by default, see ``Mk_Item_Of_Entity``).

* Variables with such a field are seen as having a wrapper type in split form.
  This does not change the actual Why3 type but enforces the need of an
  initialization check at use (see ``Transform_Identifier``).

* Top-level initialization checks are introduced when converting from a wrapper
  type to any other type (see ``Insert_Scalar_Conversion``). They can be
  explicitly disabled (to do checks on fetch on out parameters in particular)
  using a new parameter ``Do_Init``.

* Additional initialization checks are manually inserted when translating
  operators on composite types which imply a read of its components (equality,
  logical operations...).

* As initialization checks are introduced at every conversion, to avoid
  introducing such a check, ``Transform_Expr`` must be called with a
  wrapper type as an ``Expected_Type``. The version of ``Transform_Expr`` which
  computes the expected type as an additional parameter ``No_Init`` which will
  use a wrapper type when possible (for components and variables). It is used
  for out parameters and attributes which do not read the value (in particular
  ``Valid_Scalars``).

Objects
-------
Mutable and Constant Objects
^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Objects are translated differently depending on their type, but also depending
on whether they are mutable or not. Let's first consider constants. Are
translated as constants in Why3 all Ada objects with are constants in Ada
except:

 * Loop parameters, as they need to be updated during the generated Why3 loop;
 * Scalar constants with variable inputs declared in unrolled loop, or before
   the loop invariant in normal loops, because they can appear twice with
   different values due to loop handling (see
   ``SPARK_Definition.Check_Loop_Invariant_Placement`` and
   ``SPARK_Definition.Check_Unrolled_Loop``);
 * Volatile in parameters with asynchronous writers.

See ``Is_Mutable_In_Why`` for more details.

Ada objects which are constant in Why3 are translated as functions without
parameters. Here are is an example:

.. code-block:: ada

   B : constant Boolean := True;

This declaration is translated into a single uninterpreted logic function
without parameters:

.. code-block:: whyml

 module P__b
   function b2 : bool
 end

If the definition of the constant does not depend on variables, it is supplied
as an axiom in a completion module for the object:

.. code-block:: whyml

 module P__b___axiom
   use        P__b

   axiom b__def_axiom :
    P__b.b = True
 end

Variables on the other hand, are translated using an uninterpreted program
declaration returning an object of a reference type. If we remove the
``constant`` keyword form the declaration of ``B``, the translation will become:

.. code-block:: whyml

 module P__b
  val b : bool__ref
 end

No axiom is generated for the value of a variable. The value will be provided
as an assignment at the location of the object declaration:

.. code-block:: whyml

 P__b.b.bool__content <- True;

Scalar Objects
^^^^^^^^^^^^^^
For some Ada types, expressions, and in particular objects, can be either in a
open, or split, form or in a closed, or abstract, form. This is the case for
most scalar types, arrays, and records. ``Why.Inter.EW_Abstract`` and
``Why.Inter.EW_Split`` are used to create the split and abstract form of
a type. Note that, whereas all types have an abstract form (it is always OK to
call ``EW_Abstract`` on an Ada type), only scalar types and array types have
a split form (even if record objects do have a split form, see corresponding
section).

Scalar types which are not standard boolean use their representative type as a
split form: When an expression of a scalar type which is not standard boolean is
in split form, if it is translated as a value of the underlying representative
type (mathematical integer, bitvector, floating point type...). Objects of
scalar types are always in split form (see ``Use_Split_Form_For_Type``). For
example, let's consider the following objects:

.. code-block:: ada

   X : constant Integer := 15;
   Y : Integer := 15;

As ``Integer`` is a signed integer type, its representative type is ``int``:

.. code-block:: whyml

 function x : int

 axiom x__def_axiom :
   P__x.x = 15

 val y : int__ref

Using this split form for scalar types avoids having to introduce conversions
between the closed form and the
representative type for computations. Missing information about the
bounds of the objects are supplied as assumptions
through dynamic invariant (see the corresponding section in Type Completion).

Array Objects
^^^^^^^^^^^^^
For arrays that are mutable in Why, separating the content of the array from its
bounds makes proof easier. Indeed, it allows to translate the bounds as
constants, so that their preservation comes for free, while keeping a
reference for the content. To achieve this,
unconstrained and dynamically constrained array types use the underlying map
type as a split form. Since the separation is only used for preservation of
information, only mutable arrays are in split form. Let us look at some
examples.

As array constants are in closed form, constants of constrained array types with
static bounds will be translated as functions returning the underlying Why3 map
and constants of unconstrained array types, or of dynamically constrained array
types, as functions returning the corresponding abstract type:

.. code-block:: ada

   type Nat_Array is array (Positive range <>) of Natural;

   A1 : constant Nat_Array (1 .. 10) := (1 .. 10 => 15);
   A2 : constant Nat_Array := (1 .. 10 => 15);

The type of ``A1`` is statically constrained. It will be translated as a Why3
map, the bounds being declared directly inside the module for the Ada type of
``A1``:

.. code-block:: whyml

 function a1 : Array__Int__Standard__natural.map

The type of ``A2`` is unconstrained. It will be translated using the abstract
type introduced for ``Nat_Array`` from which both the bounds and the
underlying map can be queried:

.. code-block:: whyml

 function a2 : P__nat_array.nat_array

Let us now consider mutable arrays:

.. code-block:: ada

   A1 : Nat_Array (1 .. 10) := (1 .. 10 => 15);
   A2 : Nat_Array := (1 .. 10 => 15);

Since the bounds of statically constrained array types are translated
separately, we simply need a global reference for the content of ``A1``:

.. code-block:: whyml

 val a1 : Array__Int__Standard__natural.map__ref

For unconstrained or dynamically constrained array types, mutable objects are
split into different parts, the bounds, which are constant, and the mutable
content. For one-dimensional arrays, this results in the declaration of three
Why3 objects:

.. code-block:: whyml

 val a2 : Array__Int__Standard__natural.map__ref

 function a2__first : Standard__integer.integer

 function a2__last : Standard__integer.integer

A draw back of this approach is that array variables need to be
reconstructed using the ``of_array`` conversion function when they are involved
in computations. Indeed, as the bounds are associated to Ada objects, they
cannot easily be retrieved from more complex expressions, therefore requiring
the switch to closed form.

Record Objects
^^^^^^^^^^^^^^
Like arrays, records can have both constant and variable parts. The regular
components of a mutable record object are always mutable, whereas discriminants
are constant most of the time, and tag of tagged record objects can never
change. As a result, it is interesting to split record objects so that
preservation of constant parts can come for free. However, unlike array objects,
record objects do not have a single main mutable part. As a result, there is not
a single type for the split form of a record and record expressions which are
not objects are never in split form (see assertions in ``New_Kind_Base_Type``
enforcing that it is never called with kind ``EW_Split`` on record types).

Record constants are in closed form. They are translated as a single
uninterpreted logic function of the corresponding abstract record type with
no parameters.

On the other hand, a mutable record object may produce up to four declarations:

 * A mutable Why3 record for the regular components of the Ada record type,
 * A Why3 record for the discriminants of the Ada record type (mutable only
   if the Ada type has defaulted discriminants),
 * A mathematical integer constant for the tag attribute of tagged types, and
 * A boolean constant for the constrained attribute of records with defaulted
   discriminants.

As an example, let us consider the following tagged Ada record:

.. code-block:: ada

   type Tagged_Rec is tagged record
      F : Integer;
   end record;

   T : Tagged_Rec := (F => 15);

As it has no discriminants, two declarations are emitted for it, a reference for
the regular components and a constant for the tag attribute:

.. code-block:: whyml

 val t2__split_fields : P__tagged_rec.__split_fields__ref

 function t2__attr__tag : int

Let us now consider a record type with mutable discriminants:

.. code-block:: ada

   type Option (Present : Boolean := False) is record
      case Present is
      when True  =>
        Content : Integer;
      when False =>
         null;
      end case;
   end record;

   O1 : Option := (Present => True, Content => 15);

As ``Option`` has defaulted discriminants, both its regular and its discriminant
parts are mutable. However, its constrained attribute is not:

.. code-block:: whyml

 val o1__split_fields : P__option.__split_fields__ref

 val o1__split_discrs : P__option.__split_discrs__ref

 function o1__attr__constrained : bool

If the discriminant of ``Option`` is fixed in its Ada type, the discriminant
part will be declared as a constant:

.. code-block:: ada

   O2 : Option (True) := (Present => True, Content => 15);

.. code-block:: whyml

 val o2__split_field : P__To2S.__split_fields__ref

 function o2__split_discrs : P__option.__split_discrs

 function o2__attr__constrained : bool

Effect-Only Objects
^^^^^^^^^^^^^^^^^^^
Global annotations may refer to state whose exact definition is hidden from the
analysis. The most common occurrence of this case is for state abstraction. When
analyzing a unit, abstract states defined in other units are opaque for SPARK.
To encode this unknown state, abstract states are translated in Why as a global
variable of the predefined ``__private`` type. Here is an example:

.. code-block:: ada

   package Withed_Unit with
     Abstract_State => State
   is
      ...
   end Withed_Unit;

   with Withed_Unit;
   procedure P with Global => (In_Out => Withed_Unit.State);

A global reference is introduced in Why for the abstract state of
``Withed_Unit``, so that it can be used in the translation of ``P``:

.. code-block:: whyml

 module Withed_unit__state
   use import "_gnatprove_standard".Main

   val state  : __private__ref
 end

 val p (__void_param : unit) : unit
  reads  {Withed_unit__state.state}
  writes {Withed_unit__state.state}

Global annotations can also refer to entities which are not in SPARK.
In the following example, ``P`` can state that it modifies ``V``
even if ``V`` is declared in a package with ``SPARK_Mode => Off``.

.. code-block:: ada

   package Nested with
     SPARK_Mode => Off
   is
      V : access Integer;
   end Nested;

   procedure P with Global => (In_Out => Nested.V);

``V`` should be translated to express the data dependency, but we should
not try to translate its type, which may not be in SPARK (here for example it is
an access type, but the translation mechanism would be the same if it was an
integer). To this aim, we emit a dummy variable declaration for ``V`` using the
predefined ``__private`` type:

.. code-block:: whyml

 module P__nested__v
   use import "_gnatprove_standard".Main

   val v  : __private__ref
 end

 val p (__void_param : unit) : unit
  reads  {P__nested__v.v}
  writes {P__nested__v.v}

Remark that dummy variables for effects of subprograms will also be defined for
generated Global contracts (when no user provided global contract is supplied
for a subprogram).

Subprograms
-----------

Global View
^^^^^^^^^^^

The declaration of a SPARK subprogram will lead to the declaration of
one or several Why function declarations and axioms located in one or
two modules.

Procedures
""""""""""

For procedures that are not primitives of tagged types, have no
refined postcondition, and are not boundary subprograms of any type
with an invariant, only one abstract program function is declared in
Why (see ``Gnat2why.Subprograms.Generate_Subprogram_Fun``). It is supplied
in a module named <my_subprogram_full_name>___axiom and mimics as much
as possible the effects and contracts of the Ada procedure.

As an example, let us consider the following minimalist procedure declaration:

.. code-block:: ada

     procedure P;

It leads to the declaration of a single Why program function as follows:

.. code-block:: whyml

    module P__p___axiom
     val p (__void_param : unit) : unit
      requires { true }
      ensures { true }
    end

Since the procedure P has no parameters, its Why translation has a
single unit argument. The pre and postconditions of the Why program
function (introduced by requires and ensures) are set to True because
the P procedure has no explicit or implicit contracts. Note that the
Why declaration is introduced by the val keyword, which means that it
won’t have a body. Indeed, in our translation, verification of a
subprogram body is completely decorrelated from the declaration of the
subprogram. Said otherwise, this declaration will be used to translate
calls to the P procedure, but not to verify it.

Functions
"""""""""

For functions, declarations are separated in two modules to avoid
circularity issues caused by forward references of other entities in
function contracts. The first module, named by the subprogram full
name, contains a (generally abstract) logic function declaration for
the Ada function, along with a guard predicate which is used to
specifically determine when the function is actually called. This
logic function is used to transform function calls occurring in
assertions in the generated Why code, as Why does not allow calling
program functions in assertions. Since this function is logic, it is
terminating and complete, unlike the translated Ada function. This
means that special care should be taken when giving a meaning to such
a function. More precisely, we only give information about the result
of a why logic function in the context of its precondition and if it
is ascertained to terminate. The guard predicate is used to give
additional protection against errors in function contracts by only
assuming the information on actual calls of the subprogram. It is not
required if all functions are thoroughly verified, which is why its
usage can be disabled by the --no-axiom-guard option.

As an example, let us look at the following Ada function:

.. code-block:: ada

     function F return Boolean;

Here are the logic declarations introduced for F:

.. code-block:: whyml

    module P__f
     function f (__void_param : unit) : bool
     predicate f__function_guard (result : bool) (__void_param : unit)
    end

To avoid circularity issues, the contract of the logic function f is
not given in this module, but is postponed until after all functions,
types, and objects have been defined.

Just like for procedures, a Why program function is defined for Ada
functions in a second module named <my_subprogram_full_name>___axiom.
It is also in this module that an axiom is generated for the contract
of the associated Why logic function. Here are the axioms and
declarations introduced for F:

.. code-block:: whyml

    module P__f___axiom
     val f (__void_param : unit) : bool
      requires { true }
      ensures { result = P__f.f ()
	     /\ P__f.f__function_guard result () }

     axiom f__post_axiom :
      (forall __void_param : unit.
       (let result = P__f.f __void_param in
	  if P__f.f__function_guard result __void_param then
	  true))
    end

Like procedure P, the function F has no contract. However, we can see
that the associated Why program function has a postcondition. It is
used to link the two definitions of f (the logic one and the program
one). Each time the program function f is called, we will assume that
F’s guard predicate is true, and that the result of the call is equal
to the result of the logic function f.

We see that the P__f___axiom module also contains a post axiom for the
logic function f (see ``Gnat2why.Subprograms.Generate_Axiom_For_Post``).
It is used to state that results of f are always compliant with its
postcondition. Since F has no postcondition, this axiom is useless
here (it allows to deduce True). However, we can see by its form how
the guard predicate is used to protect against wrong contracts which
could lead to false post axioms if the function is not verified.

Subprogram Signature
^^^^^^^^^^^^^^^^^^^^

Parameters and Return Type
""""""""""""""""""""""""""

When an Ada subprogram is converted into Why, its parameters are
translated into parameters of the associated Why logic or program
function. The translation of a subprogram parameter depend both on the
mode and on the type of the parameter (see
Gnat2why.Subprograms.Compute_Raw_Binders). More precisely, in
parameters will be translated as constants, and thus, if they are of a
composite type, be presented in closed form, whereas in out and out
parameters will be translated as variables, and are therefore given in
split form.

As an example, let us consider the following Ada subprograms:

.. code-block:: ada

   function F (X : Integer; Y : My_Rec; Z : My_Array) return Integer;
   procedure P
        (X : in out Integer; Y : in out My_Rec; Z : in out My_Array);

Parameters F and P have the same type, but not the same mode, which
will result in different translations in Why:

.. code-block:: whyml

     function f (x : int) (y : my_rec) (z : my_array) : int

     val f (x : int) (y : my_rec) (z : my_array) : int
      requires { true }
      ensures { … }

     val p (x : int__ref)
	   (y__split_fields : P__my_rec.__split_fields__ref)
	   (y__split_discrs : P__my_rec.__split_discrs__ref)
	   (y__attr__constrained : bool)
	   (z : Array__Int__Standard__natural.map__ref)
	   (z__first : integer)
	   (z__last : integer) : unit
      requires { true }
      ensures { … }
      writes {x, y__split_fields, y__split_discrs, z}

We can see that the parameters of F are given as a whole whereas the
parameters of P that are of a composite type are splitted in different
parts. Another difference between the two declarations, is of course
that parameters of P that are mutable are given through a reference
type, so that their value can be modified. Note that only mutable
parts of mutable parameters are of a reference type. For Y, both the
fields and discriminants are mutable because My_Rec has mutable
discriminants, but the Constrained attribute is not. As for Z, the
content of the array is mutable whereas the bounds are constant.

NB: In the frontend, a specific (constrained) subtype is introduced
for parameters of an unconstrained record or array type (see
``Einfo.Actual_Subtype``). For subprogram declarations, we do not use this
subtype but rather the nominal unconstrained type for the parameters
to be able to call the function on any object of the type.

Self Reference of Protected Objects
"""""""""""""""""""""""""""""""""""

One special case worth noting: for subprograms located inside a
protected type (see Sem_Util.Within_Protected_Type), an additional
parameter named Self is added to the list of parameters to handle
direct references to protected components (see call to
``Why.Gen.Binders.Concurrent_Self_Binder`` in
``Gnat2why.Subprograms.Compute_Raw_Binders``).

Global Variables
""""""""""""""""

In Ada, functions and procedures are allowed to access (and for
procedures to modify) global variables. In Why, only program functions
can access global variables, and so, only if they appear in an
appropriate reads (or writes if the global variables are modified)
annotation. Thus, when an Ada subprogram accessing variables is
translated in Why, its program functions are annotated with
appropriate reads and writes annotations (see
``Gnat2why.Subprograms.Compute_Effects``) whereas its logic function (if
any) will take additional parameters for each referenced variable (see
``Gnat2why.Subprograms.Add_Logic_Binders``). Note that, unlike regular
parameters, the parameters introduced for global variables will be in
split form whenever the Why declaration of the variable is in split
form, and so, even if the global mode in Input. Also, for global
variables in split form, only the variable parts are given as
parameters to the Why logic function.

As an example, let us look at the following Ada subprograms:

.. code-block:: ada

   function F return Integer with Global => (X, Y, Z);

   procedure P with Global => (In_Out => (X, Y, Z));

Here is the logic function introduced for F:

.. code-block:: whyml

     function f (x : int)
		(y__fields : P__my_rec.__split_fields)
		(y__discrs : P__my_rec.__split_discrs)
		(z : Array__Int__Standard__natural.map) : int


Here, although the global mode of X, Y, and Z in the contract of F is
Input, we can see that parameters for Y and Z are given in split form.
No parameter is supplied for the Constrained attribute of Y, nor for
the bounds of Z since they are translated as global constants.

As an example of effects of program function, we consider the translation of P:

.. code-block:: whyml

     val p (__void_param : unit) : unit
      requires { true }
      ensures { ... }
      reads {x, y__split_fields, y__split_discrs, z}
      writes {x, y__split_fields, y__split_discrs, z}

We can see that p has no parameter. Instead, global variables read and
written by the subprogram are described in the reads and writes
annotations. Note that global constants are not referenced here.

Volatile Functions
""""""""""""""""""

Volatile functions are functions which may read from a volatile
variable. As a result, they may have effects which should be modeled
in Why. First, since volatile functions cannot be called in
assertions, they have no associated logic functions. Then, to model
effects of volatile functions, a new global variable is introduced and
added as a write effect of the subprogram.

As an example, let us consider the following volatile function:

.. code-block:: ada

   function F_Vol return Integer with Volatile_Function;

Here is the program function introduced for it:

.. code-block:: whyml

 val volatile__effect : Main.__private__ref

 val f_vol (__void_param : unit) : int
  requires { true }
  ensures { Standard__integer___axiom.dynamic_invariant result
                True False True }
  writes {volatile__effect}

Note that functions declared inside protected objects, though
theoretically volatile, are not handled with this mechanism. Instead,
the additional self parameter works as the mutable reference.

Contracts
^^^^^^^^^

Contracts or definitions of generated Why functions can come from
several sources: typing information, Ada contracts, bodies of
expression functions… These informations are given as Why contracts
for program functions and through axioms (or possibly immediate
definition in particular cases) for logic functions. Why contracts are
always safe, as they are only assumed at call site. Conversely, axioms
can easily allow to deduce unsound hypothesis if not carefully
handled. More precisely, we do not generate axioms for Ada contracts
and type information of potentially non terminating function (see
Flow_Generated_Globals.Pase_2.Is_Potentially_Nonreturning) and of
recursive functions (see Flow_Generated_Globals.Pase_2.Is_Recursive).
Indeed, these contracts could be unsound in cases where the function
does not return, and could be used to prove themselves in recursive
functions. For definition of expression functions, we are less
restrictive. Indeed, an axiom of the form f x … = expr cannot be
unsound unless expr depends (directly or through other axioms) on f x.
To prevent this case, it is enough to avoid generating axioms for
expression function bodies of functions which are both potentially
non-terminating and recursive.

Implicit Contracts
""""""""""""""""""

It is often the case that a only part of the Ada typing information is
available in the Why types of the subprogram (both parameter types and
return type). For example, the return type of both Why functions f is
int, that is, mathematical integers, although the return type of the
Ada function F is Integer. Additional information for types are added
in a dynamic way, by enriching the postcondition for the result type
or for parameters which are references, and by constraining the
precondition for in parameter types (see
``Gnat2why.Subprograms.Compute_Guard_Formula``). Note that the
precondition needs only to be strengthened for the logic function. For
the program functions, the translation mechanism is enough to ensure
that it will always be called on adequate arguments.

As an example, we can see that the postcondition of the program
function f includes the dynamic invariant of its result, but that its
precondition is still true:

.. code-block:: whyml

     val f (x : int) (y : my_rec) (z : my_array) : int
      requires { true }
      ensures { result = P__f.f x y z
	     /\ P__f.f__function_guard result x y z
	     /\ Standard__integer___axiom.dynamic_invariant result
		     True False True }

As for the post axiom of f, it uses the dynamic invariants of
parameters as a guard to prevent solvers from deducing anything from
applications of F to out of type parameters:

.. code-block:: whyml

     axiom f__post_axiom :
      (forall x : int.
      (forall y : my_rec.
      (forall z : my_array.
	 Standard__integer___axiom.dynamic_invariant x True True True
      /\ P__my_rec___axiom.dynamic_invariant y True True True
      /\ P__my_array___axiom.dynamic_invariant z True True True
      ->
	 let result = P__f.f x y z in
	 if P__f.f__function_guard result x y z then
	 Standard__integer___axiom.dynamic_invariant result
	      True False True)))

In a similar way, the postcondition of P is enriched with the dynamic
invariant of its mutable parameters (see
``Gnat2why.Subprograms.Compute_Dynamic_Property_For_Effects``):

.. code-block:: whyml

     val p   (x : int__ref)
	     (y__split_fields : P__my_rec.__split_fields__ref)
	     (y__split_discrs : P__my_rec.__split_discrs__ref)
	     (y__attr__constrained : bool)
	     (z : Array__Int__Standard__natural.map__ref)
	     (z__first : Standard__integer.integer)
	     (z__last : Standard__integer.integer) : unit
      requires { true }
      ensures
	{ Standard__integer___axiom.dynamic_invariant x.int__content
	      True True True)
       /\ P__my_rec___axiom.dynamic_invariant
	   {__split_fields = y__split_fields.__split_fields__content;
	    __split_discrs = y__split_discrs.__split_discrs__content;
	    attr__constrained = y__attr__constrained } True True True }
      writes {x, y__split_fields, y__split_discrs, z}

Note that no additional information is required for Z, as the bounds
cannot be modified by the subprogram.

Unlike type predicates, type invariants applying to a type T are not
part of its dynamic invariant during analysis of T’s enclosing unit.
Indeed, type invariants may be broken for objects inside local
subprograms or during internal subprogram calls. However, for boundary
and external subprograms, the type invariant should be added to the
postcondition for outputs of type T and to the precondition for inputs
of type T (see
``Gnat2why.Subprograms.Compute_Type_Invariants_For_Subprogram``). This is
what is done for the Why logic function generated for the subprogram
in its post axiom.

As an example, let us consider the following function F_Inv, where
type T has a type invariant, and F_Inv is boundary for T:

.. code-block:: ada

    package P is
       type T is private;
       function F_Inv (X : T) return T;
    private
       type T is record
	  F : Integer;
       end record with Type_Invariant => F in Natural;
    end P;

Here is the logic function generated for it along with its post axiom,
during the analysis of P:

.. code-block:: whyml

     function f_inv (x : t) : t

     axiom f_inv__post_axiom :
      (forall x : t.
	 (P__t___axiom.dynamic_invariant x True True True
       /\ P__t___axiom.type_invariant x) ->
	let result = f_inv x in
	if f_inv__function_guard result x then
	  P__t___axiom.dynamic_invariant result True False True
       /\ P__t___axiom.type_invariant result)

We see that the type invariant of X is used as a guard, ensuring that
the axiom will only be used on parameters which comply with the
invariant. The type invariant is also assumed to hold for the result
of f_inv.

As we need to differentiate between precondition checks and type
invariant checks, type invariant checks cannot be added directly to
the precondition of the Why program functions. Instead, another
program function named f_inv__check_invariants_on_call is created in
the module with the same parameters as f_inv and the type invariants
as a precondition. This program function is called when necessary (see
``Spark_Util.Subprograms.Subp_Needs_Invariant_Checks``) when translating
procedure or function calls (see ``Transform_Function_Call`` and
``Transform_Statement_Or Declaration`` from ``Gnat2why.Expr``). Here is the
program function introduced for F_Inv, along with the function used
for the type invariant checks:

.. code-block:: whyml

     val f_inv (x : t) : t
      requires { true }
      ensures { result = P__f_inv.f_inv x
	     /\ P__f_inv.f_inv__function_guard result x
	     /\ P__t___axiom.dynamic_invariant result True False True
	     /\ P__t___axiom.type_invariant result }

     val f_inv__check_invariants_on_call (x : t) : unit
      requires { P__t___axiom.type_invariant x }
      ensures { P__t___axiom.type_invariant x }

Note that the program function f_inv__check_invariants_on_call as the
invariant of X both as a pre and as a postcondition. This is used to
ensure that, once a check has been emitted for the type invariant of
X, it is assumed to hold for the rest of the program.

NB: Non-local invariants are not introduced specifically in
requirements and assumptions of subprograms, but rather included
inside dynamic invariants, as type invariants should always hold
outside of the invariant enclosing package. There is an exception to
this rule for parameters and result of private subprograms of the
enclosing package. These subprograms cannot be called directly (as
they are private) but can still appear in completions of public
entities (expression functions body for example). To avoid introducing
unsound axioms, care should be taken to not assume the type invariants
in this case (see
``Gnat2why.Subprograms.Include_Non_Local_Type_Inv_For_Subp``).

Ada Contracts
"""""""""""""

When supplied, Ada contracts are translated into Why logical
expressions and added to the contracts of the Why program function and
to the post axiom of the logic function. As an example, let us
consider the following function:

.. code-block:: ada

   function F (X : Integer) return Integer with
     Pre  => My_Pre (X),
     Post => My_Post (F'Result);

Here are its program function and its post axiom (the syntax of
function calls has been simplified to improve readability):

.. code-block:: whyml

     val f (x : int) : int
      requires { my_pre x }
      ensures { result = P__f.f x
	     /\ P__f.f__function_guard result x
	     /\ Standard__integer___axiom.dynamic_invariant result
		     True False True
	     /\ my_post result }

     axiom f_3__post_axiom :
      (forall x.
	(Standard__integer___axiom.dynamic_invariant x True True True
      /\ my_pre x) ->
	 let result = P__f.f x in
	   if P__f.f__function_guard result x then
	     my_post result
	  /\ Standard__integer___axiom.dynamic_invariant result
	       True False True)

In the postcondition of the Why program function, references to the
result of the function must use the word result. In Gnat2why, this
keyword is stored in the global variable Result_Name of Gnat2why.Expr
when generating this postcondition (a different name will be stored
when generating checks for the postcondition, see later). To simplify
the translation, the same identifier is used to generate the post
axiom. However, in this case, the result word does not have any
special meaning and it needs to be defined through a let expression.

A similar mechanism is used for the Old attribute which must be
translated using the old key word when in postconditions and as local
references when generating checks (see ``Gnat2why.Expr.Name_For_Old``).

Pre and postconditions are not the only Ada aspects which are stored
into these contracts. When a subprogram has a contract case, it is
transformed into an if expression and conjuncted to the postcondition
(see ``Gnat2why.Subprograms.Compute_Contract_Cases_Postcondition``).

As an example, lets us consider the following procedure:

.. code-block:: ada

    procedure P (X : in out Integer);
      Contract_Cases =>
        ((X in Natural) => My_Post (X'Old, X),
         others         => X = X’Old);

The contract case of P is used as a postcondition to describe the
result of its Why program function:

.. code-block:: whyml

    val p_4 (x : int__ref) : unit
     requires { true }
     ensures
	{ if old (Standard__natural.in_range x.int__content) then
	     my_post (old x.int__content) x.int__content
	  else x.int__content = (old x.int__content)
	    /\ Standard__integer___axiom.dynamic_invariant x.int__content
		   True True True True }
     writes {x}

Following the SPARK semantics, guards of contract cases must be
evaluated in the prestate. It is expressed in Why using the old
keyword. Just like the Old attribute in SPARK, it can be applied to a
whole expression. Note that, unlike in Ada, the disjointness and
completeness of the contract cases is not expressed in this
translation. Gnat2why will still verify them of course.

Another source of contracts in Ada is classwide contracts. More
precisely, when no contracts are specified for a primitive of a tagged
type, Gnat2why will use the (potentially inherited) classwide contract
instead. As an example, let us look at a primitive of a tagged Root
type:

.. code-block:: ada

     function F (X : Root) return Integer with
       Pre'Class  => X.F > 0,
       Post'Class => F'Result > 0;

As it has a classwide contract, but no specific postcondition, its
classwide pre and postconditions are used in the definition of its
program function:

.. code-block:: whyml

     val f (x :root) : int
      requires { to_rep (x.__split_fields.rec__subp__root__f) > 0 }
      ensures {result = P__f.f x
	   /\ P__f.f__function_guard result x
	   /\ Standard__integer___axiom.dynamic_invariant result
		 True False True True
	   /\ result > 0 }

Since classwide contracts are inherited, the same contracts will be
used for the overriding of F on a derived type Child of Root if no
other contract is supplied:

.. code-block:: whyml

   function F (X : Child) return Integer;

     val f__2 (x : child) : int
      requires { result = P__f__2.f x
	   /\ P__f__2.f__2__function_guard result x
	   /\ Standard__integer___axiom.dynamic_invariant result
		 True False True True
	   /\ result > 0 }

But if a specific postcondition is used, then the classwide
postcondition won’t be used anymore. Indeed, there is no point in
conjuncting it with the specific post, as in SPARK the specific
postcondition must always be stronger than the classwide one:

.. code-block:: whyml

    function F (X : Child) return Integer with
       Post => F'Result > 10;

     val f__2 (x : child) : int
      requires { result = P__f__2.f x
	   /\ P__f__2.f__2__function_guard result x
	   /\ Standard__integer___axiom.dynamic_invariant result
		 True False True True
	   /\ result > 10 }

Finally, a last case which should be considered are procedures
annotated with the No_return aspect (see ``Einfo.No_Return``). A function
with this aspect will never return, so its postcondition will never be
exercised. To express it, the postcondition of the associated program
function is set to false. As an example, the following procedure:

.. code-block:: ada

   procedure P (X : in out Integer) with
     No_Return;

is translated as:

.. code-block:: whyml

     val p (x : int__ref) : unit
      requires { true }
      ensures { false }
      writes {x}

Expression Functions
""""""""""""""""""""

Inlining
""""""""

Alternative Views of Subprograms
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Refined View
Dispatching View
Error Signaling View

Modules for Checks
==================

Declare program ‘let’ functions for which Why3 will generate
verification conditions. They are not meant to execute as the Ada
program but rather to encode all the runtime checks and assertions of
the Ada program.

All start with “assumptions”: Initial_Condition, value of constants, bounds of
inputs.

For Types
---------

For Subprograms
---------------

For Packages
------------

For Concurrent Types
--------------------

Translation of Statements and Expressions
=========================================

Translation is parametrized by a ‘domain’ value (program, term,
predicate, or program term (program but no checks are needed)) which
adapts the generated code to Why3 context where it is used. Checks are
only emitted in the ‘program’ domain. As a result, logic code
(assertions for example) are translated twice, once in the program
domain to generate the checks and one in the term or predicate domain
to have the actual translation.

Statements and Declarations
---------------------------

Declarations
^^^^^^^^^^^^

Why entities are not declared here (see Modules for Entities) but checks are generated for them and assumptions are added.

Assignments
^^^^^^^^^^^

Loops
^^^^^

Loop invariants behave differently in Ada and Why. To preserve the Ada semantics, loops are cut in parts and reassembled to follow the Ada semantics. Some parts of the loop are duplicated, leading to duplication of checks.

Procedure Calls
^^^^^^^^^^^^^^^

Context, checks on parameters

Expressions
-----------

Aggregates
^^^^^^^^^^
Operators
^^^^^^^^^
Quantifiers
^^^^^^^^^^^
Function Calls
^^^^^^^^^^^^^^
Conversions
^^^^^^^^^^^

***********************
gnat2why Implementation
***********************

This section should describe the design of ``gnat2why``, so that
developers can enter into the code base more easily.

Design
======

Circularity Avoidance (aka buckets)
-----------------------------------

Translation Phases
------------------

Additional Information Computation
----------------------------------

Declaration of Entities
-----------------------

Completion of Entities
----------------------

Generation of Checks
--------------------

Warnings by Proof
^^^^^^^^^^^^^^^^^

When the switch ``--proof-warnings`` is used, GNATprove attempts to issue
warnings about various suspicious conditions in the code, like unreachable
branches, using the capability of provers. To that end, it generates VCs of
special kinds denoted as ``VC_Warning_Kind``, so that proof of these VCs
triggers a warning, and absence of proof is ignored. To control the cost of
this feature, proof is attempted with only one prover (the first prover passed
currently), and with a very short timeout (1 sec currently). The control of
these conditions is done in :file:`gnat_config.ml`, see the use of
``opt_warn_prover`` and ``opt_warn_timeout``.

At the location where a warning could be issued, ``gnat2why`` generates an
assertion of the suitable kind, checking for the bad condition against which we
want to defend. For example, it's checking ``False`` for the warning on
unreachable branches. The assertion is isolated in an ignore block.

In fact, the case of unreachable branches and code is treated specially, as
it's necessary to generate a call to ``absurd`` instead of an assertion of
``False``, for the VCgen to correctly handle this case. It turns out that
putting this call inside an ignore block is also not enough for its effects to
be ignored, so we additionally isolate it in an if-expression (see
``Warn_On_Dead_Branch`` in :file:`gnat2why-expr.adb`).

The decision to ignore unproved VCs that correspond to warnings is done in
``Emit_Proof_Result`` in :file:`gnat2why-error_messages.adb`. Otherwise, the
proper classification of this message as a warning is done in
``Error_Msg_Proof`` in :file:`gnat2why-flow_error_messages.adb`.

Handling of Imports (Close_Theory)
----------------------------------

Global Structures
=================

Annotate Pragmas
----------------

Component information
---------------------

Names for Entity Symbols (E_Symb, filled during declaration phase)
------------------------------------------------------------------

Mutable Global Structures
=========================

Symbol Map for Variables (Symbol_Table)
---------------------------------------

Name for Old
------------

Self Reference of Protected Objects
-----------------------------------

Architecture
============

Why syntax tree (why-atree)
---------------------------

Low level generation routines (why-gen)
---------------------------------------

High level entry points (gnat2why)
----------------------------------

Interface with Why3
-------------------

VC labels
^^^^^^^^^

Labels (now called attributes in Why3) are strings added to identifiers, terms,
formulas, program expressions etc. They are kept by WP generation and can be
used to give names to goals or identifiers, give a location to a term etc. Some
of them are used by transformations: for example, "stop_split" stops Why3's
split transformation (do not work for gnatwhy3).
The list of labels that are used by gnat2why can be found in vc_kinds.ads and
the exhaustive list is the following:

``GP_Id:<n>`` with n a natural, is used to make the association between SPARK
checks and Why3 goals. For example, gnatwhy3's answer will typically contain
``{GP_ID:"1", proved:true}``, gnat2why will make the
correspondence with the real SPARK check which gives ``overflow check proved``.

``GP_Pretty_Ada:<n>``, with n the integer representation of an Ada AST node. It
is an extra information added to a specific check/goal so that, in the case
where this goal is not proved, the part of the program is reprinted: ``overflow
check might fail: cannot prove (In_range (B))``.

``GP_Reason:<reason_name>``, with reason_name a string that defines
the kind of a vc: ``OVERFLOW_CHECK``, ``RANGE_CHECK`` etc. This is used for
reporting of messages to the user. In debug mode and for coq proofs, the reason
is also used to create appropriate filename for .smt2 or .v files. It is also
used to recognize a goal in prove check mode.
The exhaustive list of kinds can be found in type ``VC_Kind`` in vc_kinds.ads.

``GP_Shape:<s>`` with s a string representing the shape of an Ada node, is
used to generate appropriate Coq filenames in manual proofs.

``GP_Sloc:<l>`` with l a location is used to give the precise location of
a VC. It is not to be confused with the # notation of Why3 for locations. l is
of the form file:line:column. In case of instantiated or inlined VC, the
location is also contained file:line:column:instantiated:file:line:column.

``GP_Subp`` ???

``GP_Already_Proved`` indicates that the VC is already proved (probably by
Codepeer).

``keep_on_simp`` prevents Why3 from simplifying inside a term that has this
label. For example, ``a /\ "keep_on_simp" true`` cannot be simplified to
``a``. We use this label to make sure we get a result for *all* VCs given even
the most trivial ones.

``comment:<e>`` with e a string containing a carriage is used in manual proof
with Coq. It is intended to show where exactly the check was located *inside*
the generated .v files. In debug mode, this comment is ***not*** generated.

``model``: Counterexample label

``model_trace:<n>`` where n is the number representing a node of Ada
AST. Counterexample label

``model_projected``: Counterexample label

``model_vc``: Counterexample label

``model_vc_post``: Counterexample label

identifying subparts of formulas to be reported to user (“cannot prove ‘bla’”)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

When a complex assertion cannot be proved, likely some parts of it actually
*have* been proved, and it is worthwhile to show the user (one of) the unproved
part(s). This is done as follows:

- gnat2why adds special markers to the subparts of the translation of an
  assertion, this is done in ``gnat2why-expr.Transform_Expr`` if the
  Transformation_Params enable this functionality. These markers contain the
  location of the subpart (using a regular ``GP_Sloc`` attribute) and the
  Node_Id of the corresponding node of the GNAT tree (using a ``GP_Pretty_Ada``
  attribute).
- gnatwhy3 attempts proof of these parts individually. It stops at the first
  unproved part, and returns the node of the ``GP_Pretty_Ada`` attribute as an
  ``extra_info`` (name of the JSON field) of the VC.
- gnat2why uses the ``extra_info`` to produce a message part of the form
  "cannot prove <subpart>".  Usually, we also want to update the sloc of the
  message to point to the subpart. This latter part is not done for types of
  checks where the part to be proved is in some other location of the code:
  precondition checks and Liskov-related checks.
