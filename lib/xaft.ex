defmodule Xaft do
  @moduledoc """
  Core Xaft module, implemented with :gen_statem state functions for the Raft role lifecycle
  """

  require Logger
  @behaviour :gen_statem

  alias Xaft.RPC.{RequestVote, RequestVoteResponse, AppendEntries, AppendEntriesResponse}
  alias Xaft.Types

  @heartbeat Application.compile_env(:xaft, :heartbeat, 75)
  @election_min Application.compile_env(:xaft, :election_min_timeout, 150)
  @election_max Application.compile_env(:xaft, :election_max_timeout, 300)

  if not is_integer(@heartbeat), do: raise(ArgumentError, ":xaft, :heartbeat must be an integer")

  if not is_integer(@election_min),
    do: raise(ArgumentError, ":xaft, :election_min_timeout must be an integer")

  if not is_integer(@election_max),
    do: raise(ArgumentError, ":xaft, :election_max_timeout must be an integer")

  if @heartbeat <= 0, do: raise(ArgumentError, ":xaft, :heartbeat must be > 0")
  if @election_min <= 0, do: raise(ArgumentError, ":xaft, :election_min_timeout must be > 0")
  if @election_max <= 0, do: raise(ArgumentError, ":xaft, :election_max_timeout must be > 0")

  if @election_min <= @heartbeat do
    raise ArgumentError, ":xaft, :election_min_timeout must be > :heartbeat"
  end

  if @election_max < @election_min do
    raise ArgumentError, ":xaft, :election_max_timeout must be >= :election_min_timeout"
  end

  defstruct [
    # TODO - Persist these on disk
    # PERSISTENT
    # latest term server has seen
    current_term: 0,
    # candidateId that received vote in current term
    voted_for: nil,
    # log entries
    log: [],

    # VOLATILE
    # index of highest log entry known to be committed
    commit_index: 0,
    # index of highest log entry applied to state machine
    last_applied: 0,

    # LEADER ONLY
    # for each server, index of the next log entry to send to that server
    next_index: %{},
    # for each server, index of highest log entry known to be replicated on server
    match_index: %{},

    # IMPLEMENTATION
    # peer xaft nodes
    peers: [],
    # pids/ids that voted for this node in this term (including self)
    votes_granted: MapSet.new(),
    # pids/ids that did not vote for this node in this term
    votes_denied: MapSet.new()
  ]

  @typedoc """
  Complete Raft state kept by a Xaft node.

  ## Persistent
  - `current_term` - latest term the server has seen.
  - `voted_for` - candidate id this server voted for in `current_term`, or `nil`.
  - `log` - list of log entries.

  ## Volatile
  - `commit_index` - highest log index known to be committed.
  - `last_applied` - highest log index applied to the state machine.

  ## Leader Only
  - `next_index` - for each server, index of the next log entry to send to that server.
  - `match_index` - for each server, index of highest log entry known to be replicated on server.

  ## Implementation
  - `peers` - list of peer node ids (excluding self).
  - `votes_granted` - pids/ids that voted for this node in this term (including self).
  - `votes_denied` - pids/ids that did not vote for this node in this term.
  """
  @type t :: %__MODULE__{
          # Persistent
          current_term: Types.xaft_term(),
          voted_for: Types.xaft_node_id() | nil,
          log: list(),

          # Volatile
          commit_index: Types.xaft_index(),
          last_applied: Types.xaft_index(),

          # Leader Only
          next_index: %{optional(Types.xaft_node_id()) => Types.xaft_index()},
          match_index: %{optional(Types.xaft_node_id()) => Types.xaft_index()},

          # Implementation
          peers: [Types.xaft_node_id()],
          votes_granted: MapSet.t(Types.xaft_node_id()),
          votes_denied: MapSet.t(Types.xaft_node_id())
        }

  @doc """
  Starts the Xaft server process.

  ## Options

    - `:bootstrap` - `true` to start as a single-node cluster leader.

  ## Returns

    * `{:ok, pid}` on success
    * `{:error, {:already_started, pid}}` if a named instance already exists
    * `{:error, reason}` otherwise

  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    {bootstrap?, config_peers} = build_args!(opts)
    :gen_statem.start_link({:global, {:xaft, node()}}, __MODULE__, {bootstrap?, config_peers}, [])
  end

  @impl true
  @doc false
  def callback_mode, do: :state_functions

  @impl true
  @doc false
  def init({bootstrap?, config_peers}) do
    random_seed!()
    :net_kernel.monitor_nodes(true, node_type: :visible)

    Enum.each(config_peers, fn p ->
      case Node.connect(p) do
        true -> Logger.info("Connected to #{inspect(p)}")
        false -> Logger.warning("Could not connect to #{inspect(p)}")
        :ignored -> Logger.warning("Ignored connect to #{inspect(p)} (distribution off?)")
      end
    end)

    raft = struct(__MODULE__, peers: Node.list())
    Logger.info("[Follower #{inspect(node())}] starting with term=#{raft.current_term}")

    if bootstrap? do
      Logger.info("[#{inspect(node())}] bootstrapping single-node cluster as leader")
      raft = raft |> bump_term() |> reset_votes() |> vote_for(node())
      {:ok, :leader, raft, [{:state_timeout, @heartbeat, :heartbeat_timeout}]}
    else
      {:ok, :follower, raft,
       [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}
    end
  end

  def follower(:info, {:nodeup, n, _}, raft) do
    Logger.info("[Follower #{inspect(node())}] observed nodeup #{inspect(n)}")
    {:keep_state, %{raft | peers: Node.list()}}
  end

  def follower(:info, {:nodedown, n, _}, raft) do
    Logger.warning("[Follower #{inspect(node())}] observed nodedown #{inspect(n)}")
    {:keep_state, %{raft | peers: Node.list()}}
  end

  def follower(
        :cast,
        %AppendEntries{
          term: t,
          leader_id: lid,
          prev_log_index: _pli,
          prev_log_term: _plt,
          entries: _e,
          leader_commit: _lc
        },
        raft
      ) do
    cond do
      t < raft.current_term ->
        Logger.warning(
          "[Follower #{inspect(node())}] Append Entries reject: stale term #{t} < #{raft.current_term} from #{inspect(lid)}"
        )

        :gen_statem.cast(
          {:global, {:xaft, lid}},
          %AppendEntriesResponse{
            term: raft.current_term,
            success?: false,
            from: node()
          }
        )

        {:keep_state_and_data, []}

      t > raft.current_term ->
        Logger.info(
          "[Follower #{inspect(node())}] Append Entries accept: set new term #{t} > #{raft.current_term} from #{inspect(lid)}"
        )

        :gen_statem.cast(
          {:global, {:xaft, lid}},
          %AppendEntriesResponse{
            term: t,
            success?: true,
            from: node()
          }
        )

        {:keep_state, raft |> set_term(t) |> vote_for(nil),
         [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}

      true ->
        Logger.info(
          "[Follower #{inspect(node())}] Append Entries accept: term #{raft.current_term} from #{inspect(lid)}"
        )

        :gen_statem.cast(
          {:global, {:xaft, lid}},
          %AppendEntriesResponse{
            term: raft.current_term,
            success?: true,
            from: node()
          }
        )

        {:keep_state_and_data,
         [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}
    end
  end

  def follower(
        :cast,
        %RequestVote{
          term: t,
          candidate_id: cid,
          last_log_index: _lli,
          last_log_term: _llt
        },
        raft
      ) do
    cond do
      t < raft.current_term ->
        Logger.warning(
          "[Follower #{inspect(node())}] Request Vote reject: stale term #{t} < #{raft.current_term} from #{inspect(cid)}"
        )

        :gen_statem.cast(
          {:global, {:xaft, cid}},
          %RequestVoteResponse{
            term: raft.current_term,
            vote_granted?: false,
            from: node()
          }
        )

        {:keep_state_and_data, []}

      t > raft.current_term ->
        Logger.info(
          "[Follower #{inspect(node())}] Request Vote accept: term #{t} > #{raft.current_term} from #{inspect(cid)}"
        )

        :gen_statem.cast(
          {:global, {:xaft, cid}},
          %RequestVoteResponse{
            term: t,
            vote_granted?: true,
            from: node()
          }
        )

        {:keep_state, raft |> set_term(t) |> vote_for(cid),
         [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}

      true ->
        if is_nil(raft.voted_for) or raft.voted_for == cid do
          Logger.info(
            "[Follower #{inspect(node())}] Request Vote accept: term #{raft.current_term} from #{inspect(cid)}"
          )

          :gen_statem.cast(
            {:global, {:xaft, cid}},
            %RequestVoteResponse{
              term: raft.current_term,
              vote_granted?: true,
              from: node()
            }
          )

          {:keep_state, raft |> vote_for(cid),
           [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}
        else
          Logger.warning(
            "[Follower #{inspect(node())}] Request Vote reject: already voted for #{inspect(raft.voted_for)} in term #{t}"
          )

          :gen_statem.cast(
            {:global, {:xaft, cid}},
            %RequestVoteResponse{
              term: raft.current_term,
              vote_granted?: false,
              from: node()
            }
          )

          {:keep_state_and_data,
           [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}
        end
    end
  end

  def follower(:state_timeout, :election_timeout, raft) do
    Logger.info(
      "[Follower #{inspect(node())}] election timeout -> becoming Candidate, new term=#{raft.current_term + 1}"
    )

    {:next_state, :candidate, raft,
     [
       {:next_event, :internal, :start_election}
     ]}
  end

  def follower(event_type, msg, raft) do
    Logger.debug(
      "[Follower] ignoring #{event_type} event #{inspect(msg)} in term=#{raft.current_term}"
    )

    {:keep_state, raft}
  end

  def candidate(:info, {:nodeup, n, _}, raft) do
    Logger.info("[Candidate #{inspect(node())}] observed nodeup #{inspect(n)}")
    {lli, llt} = last_log_info(raft)

    req = %RequestVote{
      term: raft.current_term,
      candidate_id: node(),
      last_log_index: lli,
      last_log_term: llt
    }

    :gen_statem.cast({:global, {:xaft, n}}, req)
    {:keep_state, %{raft | peers: Node.list()}}
  end

  def candidate(:info, {:nodedown, n, _}, raft) do
    Logger.warning("[Candidate #{inspect(node())}] observed nodedown #{inspect(n)}")
    {:keep_state, %{raft | peers: Node.list()}}
  end

  def candidate(:internal, :start_election, raft) do
    raft = raft |> bump_term() |> reset_votes() |> vote_for(node())
    raft = %{raft | votes_granted: MapSet.put(raft.votes_granted, node())}

    if Enum.empty?(raft.peers) do
      Logger.info(
        "[Candidate #{inspect(node())}] is lone node in term=#{raft.current_term}, promoted to leader"
      )

      {:next_state, :leader, raft, [{:state_timeout, @heartbeat, :heartbeat_timeout}]}
    else
      {lli, llt} = last_log_info(raft)

      req = %RequestVote{
        term: raft.current_term,
        candidate_id: node(),
        last_log_index: lli,
        last_log_term: llt
      }

      Logger.info(
        "[Candidate #{inspect(node())}] starting election term=#{raft.current_term} quorum=#{quorum(raft)}"
      )

      Enum.each(raft.peers, fn p -> :gen_statem.cast({:global, {:xaft, p}}, req) end)

      {:keep_state, raft,
       [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}
    end
  end

  def candidate(:state_timeout, :election_timeout, raft) do
    Logger.info("[Candidate #{inspect(node())}] election timed out, restarting")

    {:keep_state, raft,
     [
       {:next_event, :internal, :start_election}
     ]}
  end

  def candidate(:cast, %RequestVoteResponse{term: t, vote_granted?: granted, from: from}, raft) do
    cond do
      t < raft.current_term ->
        Logger.warning(
          "[Candidate #{inspect(node())}] Request Vote response: stale term #{t} < #{raft.current_term} from #{inspect(from)}"
        )

        {:keep_state_and_data, []}

      t > raft.current_term ->
        Logger.info(
          "[Candidate #{inspect(node())}] stepping down to follower: term #{t} > #{raft.current_term} from #{inspect(from)}"
        )

        {:next_state, :follower, raft |> set_term(t) |> reset_votes(),
         [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}

      true ->
        if granted do
          Logger.info(
            "[Candidate #{inspect(node())}] granted vote in term #{raft.current_term} from #{inspect(from)}"
          )

          raft = %{raft | votes_granted: MapSet.put(raft.votes_granted, from)}

          if MapSet.size(raft.votes_granted) >= quorum(raft) do
            Logger.info(
              "[Candidate #{inspect(node())}] won election in term #{raft.current_term}, promoted to leader"
            )

            {lli, llt} = last_log_info(raft)

            heartbeat = %AppendEntries{
              term: raft.current_term,
              leader_id: node(),
              prev_log_index: lli,
              prev_log_term: llt,
              entries: [],
              leader_commit: raft.commit_index
            }

            Enum.each(raft.peers, fn p -> :gen_statem.cast({:global, {:xaft, p}}, heartbeat) end)
            {:next_state, :leader, raft, [{:state_timeout, @heartbeat, :heartbeat_timeout}]}
          else
            {:keep_state, raft}
          end
        else
          Logger.warning(
            "[Candidate #{inspect(node())}] Request Vote reject in term #{t} by #{inspect(from)}"
          )

          raft = %{raft | votes_denied: MapSet.put(raft.votes_denied, from)}
          {:keep_state, raft}
        end
    end
  end

  def candidate(
        :cast,
        %AppendEntries{
          term: t,
          leader_id: lid,
          prev_log_index: _pli,
          prev_log_term: _plt,
          entries: _e,
          leader_commit: _lc
        },
        raft
      ) do
    if t < raft.current_term do
      Logger.warning(
        "[Candidate #{inspect(node())}] Append Entries reject: stale term #{t} < #{raft.current_term} from #{inspect(lid)}"
      )

      :gen_statem.cast({:global, {:xaft, lid}}, %AppendEntriesResponse{
        term: raft.current_term,
        success?: false,
        from: node()
      })

      {:keep_state_and_data, []}
    else
      Logger.info(
        "[Candidate #{inspect(node())}] stepping down to follower: Append Entries term #{t} >= #{raft.current_term} from #{inspect(lid)}"
      )

      raft = raft |> set_term(t) |> reset_votes()

      :gen_statem.cast({:global, {:xaft, lid}}, %AppendEntriesResponse{
        term: raft.current_term,
        success?: true,
        from: node()
      })

      {:next_state, :follower, raft,
       [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}
    end
  end

  def candidate(
        :cast,
        %RequestVote{
          term: t,
          candidate_id: cid,
          last_log_index: _lli,
          last_log_term: _llt
        },
        raft
      ) do
    cond do
      t < raft.current_term ->
        Logger.warning(
          "[Candidate #{inspect(node())}] Request Vote reject: stale term #{t} < #{raft.current_term} from #{inspect(cid)}"
        )

        :gen_statem.cast({:global, {:xaft, cid}}, %RequestVoteResponse{
          term: raft.current_term,
          vote_granted?: false,
          from: node()
        })

        {:keep_state_and_data, []}

      t > raft.current_term ->
        Logger.info(
          "[Candidate #{inspect(node())}] stepping down to follower: Request Vote term #{t} > #{raft.current_term} from #{inspect(cid)}"
        )

        raft = raft |> set_term(t) |> reset_votes() |> vote_for(cid)

        Logger.info(
          "[Follower #{inspect(node())}] Request Vote accept: term #{raft.current_term} from #{inspect(cid)}"
        )

        :gen_statem.cast({:global, {:xaft, cid}}, %RequestVoteResponse{
          term: raft.current_term,
          vote_granted?: true,
          from: node()
        })

        {:next_state, :follower, raft,
         [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}

      true ->
        Logger.warning(
          "[Candidate #{inspect(node())}] Request Vote reject: already voted for #{inspect(raft.voted_for)}"
        )

        :gen_statem.cast({:global, {:xaft, cid}}, %RequestVoteResponse{
          term: raft.current_term,
          vote_granted?: false,
          from: node()
        })

        {:keep_state_and_data, []}
    end
  end

  def candidate(event_type, msg, raft) do
    Logger.debug(
      "[Candidate #{inspect(node())}] ignoring #{event_type} event #{inspect(msg)} in term=#{raft.current_term}"
    )

    {:keep_state_and_data, []}
  end

  def leader(:state_timeout, :heartbeat_timeout, raft) do
    Logger.debug("[Leader #{inspect(node())}] heartbeat, term=#{raft.current_term}")
    {lli, llt} = last_log_info(raft)

    heartbeat = %AppendEntries{
      term: raft.current_term,
      leader_id: node(),
      prev_log_index: lli,
      prev_log_term: llt,
      entries: [],
      leader_commit: raft.commit_index
    }

    Enum.each(raft.peers, fn p -> :gen_statem.cast({:global, {:xaft, p}}, heartbeat) end)
    {:keep_state_and_data, [{:state_timeout, @heartbeat, :heartbeat_timeout}]}
  end

  def leader(:info, {:nodeup, n, _}, raft) do
    Logger.info("[Leader #{inspect(node())}] observed nodeup #{inspect(n)}")
    {lli, llt} = last_log_info(raft)

    :gen_statem.cast({:global, {:xaft, n}}, %AppendEntries{
      term: raft.current_term,
      leader_id: node(),
      prev_log_index: lli,
      prev_log_term: llt,
      entries: [],
      leader_commit: raft.commit_index
    })

    {:keep_state, %{raft | peers: Node.list()}}
  end

  def leader(:info, {:nodedown, n, _}, raft) do
    Logger.warning("[Leader #{inspect(node())}] observed nodedown #{inspect(n)}")
    {:keep_state, %{raft | peers: Node.list()}}
  end

  def leader(
        :cast,
        %AppendEntriesResponse{
          term: t,
          success?: success?,
          from: from
        },
        raft
      ) do
    cond do
      t < raft.current_term ->
        Logger.warning(
          "[Leader #{inspect(node())}] Append Entries response: stale term #{t} < #{raft.current_term} from #{inspect(from)}"
        )

        {:keep_state_and_data, []}

      t > raft.current_term ->
        Logger.info(
          "[Leader #{inspect(node())}] stepping down to follower: term #{t} > #{raft.current_term} from #{inspect(from)}"
        )

        {:next_state, :follower, raft |> set_term(t) |> reset_votes(),
         [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}

      true ->
        if success? do
          Logger.debug(
            "[Leader #{inspect(node())}] Append Entries successful ack from #{inspect(from)}"
          )
        else
          Logger.warning(
            "[Leader #{inspect(node())}] Append Entries failed ack from #{inspect(from)}"
          )
        end

        {:keep_state_and_data, []}
    end
  end

  def leader(
        :cast,
        %AppendEntries{
          term: t,
          leader_id: lid,
          prev_log_index: _pli,
          prev_log_term: _plt,
          entries: _e,
          leader_commit: _lc
        },
        raft
      ) do
    cond do
      t < raft.current_term ->
        Logger.warning(
          "[Leader #{inspect(node())}] Append Entries reject: stale term #{t} < #{raft.current_term} from #{inspect(lid)}"
        )

        :gen_statem.cast({:global, {:xaft, lid}}, %AppendEntriesResponse{
          term: raft.current_term,
          success?: false,
          from: node()
        })

        {:keep_state_and_data, []}

      ## TODO - revisit the case where t == raft.current_term, response must depend on log
      true ->
        Logger.info(
          "[Leader #{inspect(node())}] stepping down to follower: Append Entries term #{t} >= #{raft.current_term} from #{inspect(lid)}"
        )

        raft = raft |> set_term(t) |> reset_votes()

        :gen_statem.cast({:global, {:xaft, lid}}, %AppendEntriesResponse{
          term: raft.current_term,
          success?: true,
          from: node()
        })

        {:next_state, :follower, raft,
         [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}
    end
  end

  def leader(
        :cast,
        %RequestVote{
          term: t,
          candidate_id: cid,
          last_log_index: _lli,
          last_log_term: _llt
        },
        raft
      ) do
    cond do
      t < raft.current_term ->
        Logger.warning(
          "[Leader #{inspect(node())}] Request Vote reject: stale term #{t} < #{raft.current_term} from #{inspect(cid)}"
        )

        :gen_statem.cast({:global, {:xaft, cid}}, %RequestVoteResponse{
          term: raft.current_term,
          vote_granted?: false,
          from: node()
        })

        {:keep_state_and_data, []}

      t > raft.current_term ->
        Logger.info(
          "[Leader #{inspect(node())}] stepping down to follower: Request Vote term #{t} > #{raft.current_term} from #{inspect(cid)}"
        )

        raft = raft |> set_term(t) |> reset_votes() |> vote_for(cid)

        Logger.info(
          "[Follower #{inspect(node())}] Request Vote accept: term #{raft.current_term} from #{inspect(cid)}"
        )

        :gen_statem.cast({:global, {:xaft, cid}}, %RequestVoteResponse{
          term: raft.current_term,
          vote_granted?: true,
          from: node()
        })

        {:next_state, :follower, raft,
         [{:state_timeout, election_timeout(@election_min, @election_max), :election_timeout}]}

      true ->
        Logger.warning(
          "[Leader #{inspect(node())}] Request Vote reject: already elected as leader"
        )

        :gen_statem.cast({:global, {:xaft, cid}}, %RequestVoteResponse{
          term: raft.current_term,
          vote_granted?: false,
          from: node()
        })

        {:keep_state_and_data, []}
    end
  end

  def leader(event_type, msg, raft) do
    Logger.debug(
      "[Leader #{inspect(node())}] ignoring #{event_type} event #{inspect(msg)} in term=#{raft.current_term}"
    )

    {:keep_state_and_data, []}
  end

  @spec build_args!(keyword()) :: {boolean(), [Types.xaft_node_id()]}
  defp build_args!([]) do
    {false, get_config_peers()}
  end

  defp build_args!(opts) when is_list(opts) do
    allowed = [:bootstrap]
    args = Keyword.keys(opts) -- allowed
    if args != [], do: raise(ArgumentError, "Unknown Xaft options: #{inspect(args)}")
    bootstrap? = Keyword.get(opts, :bootstrap, false)
    if not is_boolean(bootstrap?), do: raise(ArgumentError, ":bootstrap must be boolean")

    config_peers = get_config_peers()

    if bootstrap? and config_peers != [],
      do:
        raise(
          ArgumentError,
          "Cannot use `bootstrap: true` when peers are configured (got: #{inspect(config_peers)}) — " <>
            "bootstrapping is only for a single-node cluster"
        )

    {bootstrap?, config_peers}
  end

  defp build_args!(opts) do
    raise ArgumentError, "Xaft start_link options must be a keyword list, got #{inspect(opts)}"
  end

  # Peers set in config, excluding self and duplicates
  @spec get_config_peers() :: [Types.xaft_node_id()]
  defp get_config_peers() do
    peers = Application.get_env(:xaft, :peers, [])

    if is_list(peers) and Enum.all?(peers, &is_atom/1) do
      peers
      |> Enum.uniq()
      |> Enum.reject(&(&1 == node()))
    else
      raise ArgumentError,
            ":xaft, :peers must be a list of node name atoms, got: #{inspect(peers)}"
    end
  end

  @spec bump_term(t()) :: t()
  defp bump_term(raft), do: %{raft | current_term: raft.current_term + 1}
  @spec set_term(t(), Types.xaft_term()) :: t()
  defp set_term(raft, term), do: %{raft | current_term: term}

  @spec vote_for(t(), Types.xaft_node_id() | nil) :: t()
  defp vote_for(raft, who), do: %{raft | voted_for: who}

  @spec reset_votes(t()) :: t()
  defp reset_votes(raft),
    do: %{raft | voted_for: nil, votes_granted: MapSet.new(), votes_denied: MapSet.new()}

  # Majority 
  @spec quorum(t()) :: pos_integer()
  defp quorum(%__MODULE__{peers: peers}), do: div(length(peers) + 1, 2) + 1

  # Last log index and term
  @spec last_log_info(t()) :: {non_neg_integer(), non_neg_integer()}
  defp last_log_info(%__MODULE__{log: []}), do: {0, 0}

  defp last_log_info(%__MODULE__{log: log}) do
    last = List.last(log)
    last_index = Map.get(last, :index, 0)
    last_term = Map.get(last, :term, 0)
    {last_index, last_term}
  end

  # Enum.random, which uses the Erlang :rand module, is not secure by default!
  # It is recommended to seed it this way - 
  # https://hashrocket.com/blog/posts/the-adventures-of-generating-random-numbers-in-erlang-and-elixir
  defp random_seed! do
    <<a::32, b::32, c::32>> = :crypto.strong_rand_bytes(12)
    :rand.seed(:exsplus, {a, b, c})
    :ok
  end

  @spec election_timeout(pos_integer(), pos_integer()) :: pos_integer()
  defp election_timeout(min, max)
       when is_integer(min) and is_integer(max) and min > 0 and max >= min,
       do: Enum.random(min..max)

  defp election_timeout(min, max) do
    raise ArgumentError,
          "Xaft election timeouts must be positive integers with max >= min, got min: #{inspect(min)} and max: #{inspect(max)}"
  end
end
