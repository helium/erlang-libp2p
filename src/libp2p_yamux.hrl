-define(SYN, 16#01).
-define(ACK, 16#02).
-define(FIN, 16#04).
-define(RST, 16#08).

-define(FLAG_IS_SET(Flags, Flag), (Flags band Flag) == Flag).
-define(FLAG_SET(Flags, Flag), Flags band Flag).
-define(FLAG_CLR(Flags, Flag), (Flags band (bnot Flag))).

-define(DEFAULT_MAX_WINDOW_SIZE, (256 * 1024)).
