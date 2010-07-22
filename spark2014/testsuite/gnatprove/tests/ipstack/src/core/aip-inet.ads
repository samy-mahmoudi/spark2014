------------------------------------------------------------------------------
--                            IPSTACK COMPONENTS                            --
--             Copyright (C) 2010, Free Software Foundation, Inc.           --
------------------------------------------------------------------------------

--  General Internet-ting facilities

--# inherit AIP;

package AIP.Inet is

   -------------------------------------
   -- Basic network layer abstraction --
   -------------------------------------

   type Inet_Layer is (LINK_LAYER, IP_LAYER, TRANSPORT_LAYER);

   function HLEN_To (L : Inet_Layer) return AIP.U16_T;
   --  How much room, in bytes, do we need for cumulated protocol headers
   --  for data to be sent from layer L.

end AIP.Inet;
