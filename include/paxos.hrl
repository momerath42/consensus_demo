-define(NODE_COUNT,5).
-define(QUORUM_COUNT,3).

-define(SET_TIMEOUT,6000).
-define(GET_FAST_TIMEOUT,2000).
-define(CAMPAIGNING_TIMEOUT,5000).
-define(AWAITING_ELECTION_TIMEOUT,5000).
-define(ELECTION_TIMEOUT_BASE,6000).
-define(ELECTION_TIMEOUT_RANGE,25000).
-define(PREPARING_TIMEOUT,5000).
-define(COMMITTING_TIMEOUT,5000).
-define(HEARTBEAT_TIMEOUT,4000).
-define(HEARTBEAT_PERIOD,3500).
-define(RUN_FOR_ELECTION_TIMEOUT,1). %% kludge

%% To simulate noisy connections:
-define(FUZZ,false).
-define(PACKET_LOSS_PERCENTAGE,5).
-define(PACKET_DUP_PERCENTAGE,2).

%% 4 is debug, 2 is warnings, 1 is errors. 3 is design-level
-define(LOG_VERBOSITY,3).
