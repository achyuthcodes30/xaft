defmodule XaftTest do
  use ExUnit.Case
  doctest Xaft

  test "greets the world" do
    assert Xaft.hello() == :world
  end
end
