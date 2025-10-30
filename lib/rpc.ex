defmodule Xaft.RPC do
  @moduledoc """
  RPC message types for Xaft

  Structs:
  - `AppendEntries` - Sent by a leader to replicate log entries and as heartbeat.
  - `AppendEntriesResponse` - Response to Raft `AppendEntries` RPC message.
  - `RequestVote` - Sent by candidate nodes during elections.
  - `RequestVoteResponse` - Response to Raft `RequestVote` RPC message.
  """
  defmodule AppendEntries do
    @moduledoc """
    Raft AppendEntries RPC message.

    Sent by a leader to replicate log entries and as heartbeat.
    """
    alias Xaft.Types
    @fields [:term, :leader_id, :prev_log_index, :prev_log_term, :entries, :leader_commit]
    @enforce_keys @fields
    defstruct @fields

    @typedoc """
    Represents an `AppendEntries` RPC message.

    Fields:
    - `term`: leader's term.
    - `leader_id`: so follower can redirect clients.
    - `prev_log_index`: index of log entry immediately preceding new ones.
    - `prev_log_term`: term of prevLogIndex entry.
    - `entries`: log entries to store (empty for heartbeat; may send more than one for efficiency).
    - `leader_commit`: leader’s commitIndex.

    """

    @type t :: %__MODULE__{
            term: Types.xaft_term(),
            leader_id: Types.xaft_node_id(),
            prev_log_index: Types.xaft_index(),
            prev_log_term: Types.xaft_term(),
            entries: list(),
            leader_commit: Types.xaft_index()
          }
  end

  defmodule AppendEntriesResponse do
    @moduledoc """
    Response to Raft AppendEntries RPC message.

    Sent to the leader that made the AppendEntries RPC.
    """
    alias Xaft.Types
    @fields [:term, :success?, :from]
    @enforce_keys @fields
    defstruct @fields

    @typedoc """
    Represents an `AppendEntriesResponse` RPC message.

    Fields:
    - `term`: currentTerm, for leader to update itself.
    - `success?`: true if follower contained entry matching prevLogIndex and prevLogTerm.
    - `from`: ID of the node responding to the `AppendEntries` message.

    """
    @type t :: %__MODULE__{
            term: Types.xaft_term(),
            success?: boolean(),
            from: Types.xaft_node_id()
          }
  end

  defmodule RequestVote do
    @moduledoc """
    Raft RequestVote RPC message.

    Sent by candidate nodes during elections.
    """
    alias Xaft.Types
    @fields [:term, :candidate_id, :last_log_index, :last_log_term]
    @enforce_keys @fields
    defstruct @fields

    @typedoc """
    Represents a `RequestVote` RPC message.

    Fields:
    - `term`: candidate’s term.
    - `candidate_id`: candidate requesting vote.
    - `last_log_index`: index of candidate’s last log entry .
    - `last_log_term`: term of candidate’s last log entry.
    """

    @type t :: %__MODULE__{
            term: Types.xaft_term(),
            candidate_id: Types.xaft_node_id(),
            last_log_index: Types.xaft_index(),
            last_log_term: Types.xaft_term()
          }
  end

  defmodule RequestVoteResponse do
    @moduledoc """
    Response to Raft RequestVote RPC message.

    Sent to the candidate that made the RequestVote RPC, granting or denying a vote.
    """
    alias Xaft.Types
    @fields [:term, :vote_granted?, :from]
    @enforce_keys @fields
    defstruct @fields

    @typedoc """
    Represents a `RequestVoteResponse` RPC message.

    Fields:
    - `term`: currentTerm, for candidate to update itself.
    - `vote_granted?`: true means candidate received vote.
    - `from`: ID of the node responding to the `RequestVote` message.

    """
    @type t :: %__MODULE__{
            term: Types.xaft_term(),
            vote_granted?: boolean(),
            from: Types.xaft_node_id()
          }
  end
end
