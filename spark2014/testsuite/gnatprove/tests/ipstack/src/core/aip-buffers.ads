------------------------------------------------------------------------------
--                            IPSTACK COMPONENTS                            --
--             Copyright (C) 2010, Free Software Foundation, Inc.           --
------------------------------------------------------------------------------

--  Generic Packet Buffers (network packet data containers) management.

--# inherit AIP,  --  Needed in order to inherit AIP.Buffers in child packages
--#         AIP.Support;  -- Same reason to inherit AIP.Support

package AIP.Buffers
--# own State;
is
   Chunk_Size : constant AIP.U16_T := 256;
   --  Size of an individual chunk
   Chunk_Num  : constant AIP.U16_T := 10;
   --  Total number of chunks statically allocated
   Ref_Num    : constant AIP.U16_T := 64;
   --  Number of 'ref' buffers statically allocated

   subtype Elem is Character;

   --  There should be at least one buffer per chunk, plus additional buffers
   --  for the case where no data is stored
   Buffer_Num : constant AIP.U16_T := Chunk_Num + Ref_Num;

   subtype Buffer_Id is AIP.U16_T range 0 .. Buffer_Num;
   subtype Chunk_Length is AIP.U16_T range 0 .. Chunk_Size;
   subtype Offset_Length is AIP.U16_T range 0 .. Chunk_Size - 1;
   subtype Data_Length is AIP.U16_T range 1 .. Chunk_Size * Chunk_Num;

   NOBUF : constant Buffer_Id := 0;

   --  Network packet data is held in buffers, chained as required when
   --  several buffers are needed for a single packet. Such chaining
   --  capabilities are very useful to allow storage of large data blocks in
   --  possibly smaller buffers allocated in static pools. They also offer
   --  convenient incremental packet construction possibilities, such as
   --  chaining initially separate buffers to make up a single packet,
   --  prepending info ahead of existing data, ...

   --  Several packets, each consisting of one or more buffers, may as well be
   --  chained together as 'packet queues' in some circumstances.

   --  Buffers feature reference counters to facilitate sharing and allow
   --  control over deallocation responsibilities.

   -----------------------
   -- Buffer allocation --
   -----------------------

   --  Buffers always materialize as a least control structure and can be used
   --  to hold or designate different kinds of data locations.

   type Buffer_Kind is
     (MONO_BUF,
      --  Buffer data is allocated as contiguous chunks

      LINK_BUF,
      --  Buffer data is allocated from available chunks. A chain is
      --  constructed if a single chunk is not big enough for the intended
      --  buffer size.

      REF_BUF
      --  No buffer data is allocated. Instead, the buffer references the data
      --  (payload) through a reference that needs to be attached explicitely
      --  before use.
     );

   subtype Data_Buffer_Kind is Buffer_Kind range MONO_BUF .. LINK_BUF;

   procedure Buffer_Alloc
     (Offset :     Offset_Length;
      Size   :     Data_Length;
      Kind   :     Buffer_Kind;
      Buf    : out Buffer_Id);
   --# global in out State;
   --  Allocate and return a new Buf of kind Kind, aimed at holding or
   --  referencing Size elements of data

   -----------------------------
   -- Buffer struct accessors --
   -----------------------------

   function Buffer_Len (Buf : Buffer_Id) return AIP.U16_T;
   --# global in State;
   --  Amount of packet data held in the first chunk of buffer Buf

--     function Buffer_Tlen (Buf : Buffer_Id) return AIP.U16_T;
--     --# global in State;
--     --  Amount of packet data held in all chunks of buffer Buf through the chain
--     --  for this packet. Tlen = Len means PB is the last buffer in the chain for
--     --  a packet.
--
--     function Buffer_Next (Buf : Buffer_Id) return Buffer_Id;
--     --# global in State;
--     --  Buffer following PB in a chain, either next Buffer for the same packet
--     --  or first Buffer of another one.
--
--     function Buffer_Payload (Buf : Buffer_Id) return AIP.IPTR_T;
--     --# global in State;
--     --  Pointer to Data held or referenced by Buffer PB.
--
--     ----------------------------------
--     -- Buffer reference and release --
--     ----------------------------------
--
--     procedure Buffer_Ref (Buf : Buffer_Id);
--     --# global in out State;
--     --  Increase reference count of Buffer PB, with influence on Buffer_Free
--
--     procedure Buffer_Free (Buf : Buffer_Id; N_Deallocs : out AIP.U8_T);
--     --# global in out State;
--     --  Decrement PB's reference count, and deallocate if the count reaches
--     --  zero. In the latter case, repeat for the following Buffers in a chain for
--     --  the same packet. Return the number of Buffers that were de-allocated.
--     --
--     --  1->2->3 yields ...1->3
--     --  3->3->3 yields 2->3->3
--     --  1->1->2 yields ......1
--     --  2->1->1 yields 1->1->1
--     --  1->1->1 yields .......
--
--     procedure Buffer_Blind_Free (Buf : Buffer_Id);
--     --# global in out State;
--     --  Same as Buffer_Free, ignoring return value
--
--     procedure Buffer_Release (Buf : Buffer_Id);
--     --# global in out State;
--     --  Buffer_Free on PB until it deallocates.
--
--     -----------------------
--     -- Buffer operations --
--     -----------------------
--
--     procedure Buffer_Cat (Head : Buffer_Id; Tail : Buffer_Id);
--     --# global in out State;
--     --  Append TAIL at the end of the chain starting at HEAD, taking over
--     --  the caller's reference to TAIL.
--
--     procedure Buffer_Chain (Head : Buffer_Id; Tail : Buffer_Id);
--     --# global in out State;
--     --  Append TAIL at the end of the chain starting at HEAD, and bump TAIL's
--     --  reference count. The caller remains responsible of it's own reference,
--     --  in particular wrt release duties.
--
--     procedure Buffer_Header (Buf : Buffer_Id; Bump : AIP.S16_T);
--     --# global in out State;
--     --  Move the payload pointer of PB by BUMP bytes, signed. Typically used to
--     --  reveal or hide protocol headers.

end AIP.Buffers;
