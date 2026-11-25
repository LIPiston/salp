# dart_mosh 0.0.4 local changes

Origin: https://github.com/gwitko/dart_mosh, pub.dev release 0.0.4 (Apache-2.0; upstream LICENSE retained).

The transport now retains optional authority callbacks for queued input and checks them before first transmission. `discardUnsent()` removes only the never-transmitted suffix at application lock. Any invalid suffix is discarded in order, preventing later input from overtaking a revoked command. Already transmitted state is immutable and retains normal Mosh retransmission/deduplication; receipt/execution cannot be inferred from local UDP success.

Unacknowledged input is bounded at 64 KiB / 1024 instructions. Closed sessions reject send/resize, ACKs cannot acknowledge unsent states, zero-byte UDP sends do not advance the sent state, and shutdown stops further scheduling. Tests include a real OpenSSH/mosh-server flow proving queued input at lock is not executed after unlocking, while fresh input still works.
