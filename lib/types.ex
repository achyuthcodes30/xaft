defmodule Xaft.Types do
  @moduledoc """
    Shared basic Raft type aliases used across Xaft.
  """

  @typedoc "Monotonically increasing Raft term"
  @type xaft_term :: non_neg_integer()

  @typedoc "Log index"
  @type xaft_index :: non_neg_integer()

  @typedoc "BEAM node name"
  @type xaft_node_id :: node()
end
