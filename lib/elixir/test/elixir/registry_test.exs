Code.require_file "test_helper.exs", __DIR__

defmodule RegistryTest do
  use ExUnit.Case, async: true
  doctest Registry, except: [:moduledoc]

  setup config do
    keys = config[:keys] || :unique
    partitions = config[:partitions] || 1
    listeners = List.wrap(config[:listener])
    opts = [keys: keys, name: config.test, partitions: partitions, listeners: listeners]
    {:ok, sup} = Supervisor.start_link([{Registry, opts}], strategy: :one_for_one)
    {:ok, %{registry: config.test, partitions: partitions, sup: sup}}
  end

  for {describe, partitions} <- ["with 1 partition": 1, "with 8 partitions": 8] do
    describe "unique #{describe}" do
      @describetag keys: :unique, partitions: partitions

      test "starts configured amount of partitions", %{registry: registry, partitions: partitions} do
        assert length(Supervisor.which_children(registry)) == partitions
      end

      test "has unique registrations", %{registry: registry} do
        {:ok, pid} = Registry.register(registry, "hello", :value)
        assert is_pid(pid)
        assert Registry.keys(registry, self()) == ["hello"]

        assert {:error, {:already_registered, pid}} =
               Registry.register(registry, "hello", :value)
        assert pid == self()
        assert Registry.keys(registry, self()) == ["hello"]

        {:ok, pid} = Registry.register(registry, "world", :value)
        assert is_pid(pid)
        assert Registry.keys(registry, self()) |> Enum.sort() == ["hello", "world"]
      end

      test "has unique registrations across processes", %{registry: registry} do
        {_, task} = register_task(registry, "hello", :value)
        Process.link(Process.whereis(registry))

        assert {:error, {:already_registered, ^task}} =
               Registry.register(registry, "hello", :recent)
        assert Registry.keys(registry, self()) == []
        {:links, links} = Process.info(self(), :links)
        assert Process.whereis(registry) in links
      end

      test "has unique registrations even if partition is delayed", %{registry: registry} do
        {owner, task} = register_task(registry, "hello", :value)
        assert Registry.register(registry, "hello", :other) ==
               {:error, {:already_registered, task}}

        :sys.suspend(owner)
        kill_and_assert_down(task)
        Registry.register(registry, "hello", :other)
        assert Registry.lookup(registry, "hello") == [{self(), :other}]
      end

      test "supports match patterns", %{registry: registry} do
        value = {1, :atom, 1}
        {:ok, _} = Registry.register(registry, "hello", value)
        assert Registry.match(registry, "hello", {1, :_, :_}) ==
               [{self(), value}]
        assert Registry.match(registry, "hello", {1.0, :_, :_}) ==
               []
        assert Registry.match(registry, "hello", {:_, :atom, :_}) ==
               [{self(), value}]
        assert Registry.match(registry, "hello", {:"$1", :_, :"$1"}) ==
               [{self(), value}]
      end

      test "supports guard conditions", %{registry: registry} do
        value = {1, :atom, 2}
        {:ok, _} = Registry.register(registry, "hello", value)
        assert Registry.match(registry, "hello", {:_, :_, :"$1"}, [{:>, :"$1", 1}]) ==
               [{self(), value}]
        assert Registry.match(registry, "hello", {:_, :_, :"$1"}, [{:>, :"$1", 2}]) ==
               []
        assert Registry.match(registry, "hello", {:_, :"$1", :_,}, [{:is_atom, :"$1"}]) ==
               [{self(), value}]
      end

      test "compares using ===", %{registry: registry} do
        {:ok, _} = Registry.register(registry, 1.0, :value)
        {:ok, _} = Registry.register(registry, 1, :value)
        assert Registry.keys(registry, self()) |> Enum.sort() == [1, 1.0]
      end

      test "updates current process value", %{registry: registry} do
        assert Registry.update_value(registry, "hello", &raise/1) == :error
        register_task(registry, "hello", :value)
        assert Registry.update_value(registry, "hello", &raise/1) == :error

        Registry.register(registry, "world", 1)
        assert Registry.lookup(registry, "world") == [{self(), 1}]
        assert Registry.update_value(registry, "world", & &1 + 1) == {2, 1}
        assert Registry.lookup(registry, "world") == [{self(), 2}]
      end

      test "dispatches to a single key", %{registry: registry} do
        assert Registry.dispatch(registry, "hello", fn _ ->
          raise "will never be invoked"
        end) == :ok

        {:ok, _} = Registry.register(registry, "hello", :value)

        assert Registry.dispatch(registry, "hello", fn [{pid, value}] ->
          send(pid, {:dispatch, value})
        end)

        assert_received {:dispatch, :value}
      end

      test "allows process unregistering", %{registry: registry} do
        :ok = Registry.unregister(registry, "hello")

        {:ok, _} = Registry.register(registry, "hello", :value)
        {:ok, _} = Registry.register(registry, "world", :value)
        assert Registry.keys(registry, self()) |> Enum.sort() == ["hello", "world"]

        :ok = Registry.unregister(registry, "hello")
        assert Registry.keys(registry, self()) == ["world"]

        :ok = Registry.unregister(registry, "world")
        assert Registry.keys(registry, self()) == []
      end

      test "allows unregistering with no entries", %{registry: registry} do
        assert Registry.unregister(registry, "hello") == :ok
      end

      @tag listener: :"unique_listener_#{partitions}"
      test "allows listeners", %{registry: registry, listener: listener} do
        Process.register(self(), listener)
        {_, task} = register_task(registry, "hello", :world)
        assert_received {:register, ^registry, "hello", ^task, :world}

        self = self()
        {:ok, _} = Registry.register(registry, "world", :value)
        assert_received {:register, ^registry, "world", ^self, :value}

        :ok = Registry.unregister(registry, "world")
        assert_received {:unregister, ^registry, "world", ^self}
      end

      test "links and unlinks on register/unregister", %{registry: registry} do
        {:ok, pid} = Registry.register(registry, "hello", :value)
        {:links, links} = Process.info(self(), :links)
        assert pid in links

        {:ok, pid} = Registry.register(registry, "world", :value)
        {:links, links} = Process.info(self(), :links)
        assert pid in links

        :ok = Registry.unregister(registry, "hello")
        {:links, links} = Process.info(self(), :links)
        assert pid in links

        :ok = Registry.unregister(registry, "world")
        {:links, links} = Process.info(self(), :links)
        refute pid in links
      end

      test "raises on unknown registry name" do
        assert_raise ArgumentError, ~r/unknown registry/, fn ->
          Registry.register(:unknown, "hello", :value)
        end
      end

      test "via callbacks", %{registry: registry} do
        name = {:via, Registry, {registry, "hello"}}

        # register_name
        {:ok, pid} = Agent.start_link(fn -> 0 end, name: name)

        # send
        assert Agent.update(name, & &1 + 1) == :ok

        # whereis_name
        assert Agent.get(name, & &1) == 1

        # unregister_name
        assert {:error, _} =
               Agent.start(fn -> raise "oops" end)

        # errors
        assert {:error, {:already_started, ^pid}} =
               Agent.start(fn -> 0 end, name: name)
      end
    end
  end

  for {describe, partitions} <- ["with 1 partition": 1, "with 8 partitions": 8] do
    describe "duplicate #{describe}" do
      @describetag keys: :duplicate, partitions: partitions

      test "starts configured amount of partitions", %{registry: registry, partitions: partitions} do
        assert length(Supervisor.which_children(registry)) == partitions
      end

      test "has duplicate registrations", %{registry: registry} do
        {:ok, pid} = Registry.register(registry, "hello", :value)
        assert is_pid(pid)
        assert Registry.keys(registry, self()) == ["hello"]

        assert {:ok, pid} = Registry.register(registry, "hello", :value)
        assert is_pid(pid)
        assert Registry.keys(registry, self()) == ["hello", "hello"]

        {:ok, pid} = Registry.register(registry, "world", :value)
        assert is_pid(pid)
        assert Registry.keys(registry, self()) |> Enum.sort() == ["hello", "hello", "world"]
      end

      test "compares using matches", %{registry: registry} do
        {:ok, _} = Registry.register(registry, 1.0, :value)
        {:ok, _} = Registry.register(registry, 1, :value)
        assert Registry.keys(registry, self()) |> Enum.sort() == [1, 1.0]
      end

      test "dispatches to multiple keys", %{registry: registry} do
        assert Registry.dispatch(registry, "hello", fn _ ->
          raise "will never be invoked"
        end) == :ok

        {:ok, _} = Registry.register(registry, "hello", :value1)
        {:ok, _} = Registry.register(registry, "hello", :value2)
        {:ok, _} = Registry.register(registry, "world", :value3)

        assert Registry.dispatch(registry, "hello", fn entries ->
          for {pid, value} <- entries, do: send(pid, {:dispatch, value})
        end)

        assert_received {:dispatch, :value1}
        assert_received {:dispatch, :value2}
        refute_received {:dispatch, :value3}

        assert Registry.dispatch(registry, "world", fn entries ->
          for {pid, value} <- entries, do: send(pid, {:dispatch, value})
        end)

        refute_received {:dispatch, :value1}
        refute_received {:dispatch, :value2}
        assert_received {:dispatch, :value3}
      end

      test "allows process unregistering", %{registry: registry} do
        {:ok, _} = Registry.register(registry, "hello", :value)
        {:ok, _} = Registry.register(registry, "hello", :value)
        {:ok, _} = Registry.register(registry, "world", :value)
        assert Registry.keys(registry, self()) |> Enum.sort() == ["hello", "hello", "world"]

        :ok = Registry.unregister(registry, "hello")
        assert Registry.keys(registry, self()) == ["world"]

        :ok = Registry.unregister(registry, "world")
        assert Registry.keys(registry, self()) == []
      end

      test "allows unregistering with no entries", %{registry: registry} do
        assert Registry.unregister(registry, "hello") == :ok
      end

      test "supports match patterns", %{registry: registry} do
        value1 = {1, :atom, 1}
        {:ok, _} = Registry.register(registry, "hello", value1)
        value2 = {2, :atom, 2}
        {:ok, _} = Registry.register(registry, "hello", value2)

        assert Registry.match(registry, "hello", {1, :_, :_}) ==
               [{self(), value1}]
        assert Registry.match(registry, "hello", {1.0, :_, :_}) ==
               []
        assert Registry.match(registry, "hello", {:_, :atom, :_}) |> Enum.sort() ==
               [{self(), value1}, {self(), value2}]
        assert Registry.match(registry, "hello", {:"$1", :_, :"$1"}) |> Enum.sort() ==
               [{self(), value1}, {self(), value2}]
        assert Registry.match(registry, "hello", {2, :_, :_}) ==
               [{self(), value2}]
        assert Registry.match(registry, "hello", {2.0, :_, :_}) ==
               []
      end

      test "supports guards", %{registry: registry} do
        value1 = {1, :atom, 1}
        {:ok, _} = Registry.register(registry, "hello", value1)
        value2 = {2, :atom, 2}
        {:ok, _} = Registry.register(registry, "hello", value2)

        assert Registry.match(registry, "hello", {:"$1", :_, :_}, [{:<, :"$1", 2}]) ==
               [{self(), value1}]
        assert Registry.match(registry, "hello", {:"$1", :_, :_}, [{:>, :"$1", 3}]) ==
               []
        assert Registry.match(registry, "hello", {:"$1", :_, :_}, [{:<, :"$1", 3}]) |> Enum.sort() ==
               [{self(), value1}, {self(), value2}]
        assert Registry.match(registry, "hello", {:_, :"$1",  :_}, [{:is_atom, :"$1"}]) |> Enum.sort() ==
               [{self(), value1}, {self(), value2}]
      end

      @tag listener: :"duplicate_listener_#{partitions}"
      test "allows listeners", %{registry: registry, listener: listener} do
        Process.register(self(), listener)
        {_, task} = register_task(registry, "hello", :world)
        assert_received {:register, ^registry, "hello", ^task, :world}

        self = self()
        {:ok, _} = Registry.register(registry, "hello", :value)
        assert_received {:register, ^registry, "hello", ^self, :value}

        :ok = Registry.unregister(registry, "hello")
        assert_received {:unregister, ^registry, "hello", ^self}
      end

      test "links and unlinks on register/unregister", %{registry: registry} do
        {:ok, pid} = Registry.register(registry, "hello", :value)
        {:links, links} = Process.info(self(), :links)
        assert pid in links

        {:ok, pid} = Registry.register(registry, "world", :value)
        {:links, links} = Process.info(self(), :links)
        assert pid in links

        :ok = Registry.unregister(registry, "hello")
        {:links, links} = Process.info(self(), :links)
        assert pid in links

        :ok = Registry.unregister(registry, "world")
        {:links, links} = Process.info(self(), :links)
        refute pid in links
      end

      test "raises on unknown registry name" do
        assert_raise ArgumentError, ~r/unknown registry/, fn ->
          Registry.register(:unknown, "hello", :value)
        end
      end

      test "raises if attempt to be used on via", %{registry: registry} do
        assert_raise ArgumentError, ":via is not supported for duplicate registries", fn ->
          name = {:via, Registry, {registry, "hello"}}
          Agent.start_link(fn -> 0 end, name: name)
        end
      end
    end
  end

  # Note: those tests relies on internals
  for keys <- [:unique, :duplicate] do
    describe "clean up #{keys} registry on process crash" do
      @describetag keys: keys

      @tag partitions: 8
      test "with 8 partitions", %{registry: registry} do
        {_, task1} = register_task(registry, "hello", :value)
        {_, task2} = register_task(registry, "world", :value)

        kill_and_assert_down(task1)
        kill_and_assert_down(task2)

        # pid might be in different parition to key so need to sync with all
        # paritions before checking ets tables are empty.
        for i <- 0..7 do
          [{_, _, {partition, _}}] = :ets.lookup(registry, i)
          GenServer.call(partition, :sync)
        end

        for i <- 0..7 do
          [{_, key, {_, pid}}] = :ets.lookup(registry, i)
          assert :ets.tab2list(key) == []
          assert :ets.tab2list(pid) == []
        end
      end

      @tag partitions: 1
      test "with 1 partition", %{registry: registry} do
        {_, task1} = register_task(registry, "hello", :value)
        {_, task2} = register_task(registry, "world", :value)

        kill_and_assert_down(task1)
        kill_and_assert_down(task2)

        [{-1, {_, _, key, {partition, pid}, _}}] = :ets.lookup(registry, -1)
        GenServer.call(partition, :sync)
        assert :ets.tab2list(key) == []
        assert :ets.tab2list(pid) == []
      end
    end
  end

  defp register_task(registry, key, value) do
    parent = self()
    {:ok, task} =
      Task.start(fn ->
        send(parent, Registry.register(registry, key, value))
        Process.sleep(:infinity)
      end)
    assert_receive {:ok, owner}
    {owner, task}
  end

  defp kill_and_assert_down(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
  end
end
