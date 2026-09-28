defmodule TestFleet.DockerProxy do
  @moduledoc """
  A TCP proxy in front of the Docker Engine, to break TestFleet's connections the
  way a restarted socket proxy or daemon does (Milestone 7, section 7).

  `interrupt/1` closes every open connection and stops listening, so new connections
  are refused; `resume/1` listens again on the same port.
  """
  use GenServer

  def start_link(upstream), do: GenServer.start_link(__MODULE__, upstream)

  @doc "`tcp://127.0.0.1:<port>`, to use as the Docker host."
  def host(proxy), do: "tcp://127.0.0.1:#{GenServer.call(proxy, :port)}"

  def interrupt(proxy), do: GenServer.call(proxy, :interrupt)

  def resume(proxy), do: GenServer.call(proxy, :resume)

  @impl true
  def init({upstream_host, upstream_port}) do
    Process.flag(:trap_exit, true)
    state = %{upstream: {String.to_charlist(upstream_host), upstream_port}, connections: []}
    {:ok, listen(state, 0)}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:interrupt, _from, state) do
    :gen_tcp.close(state.listener)
    Enum.each(state.connections, &Process.exit(&1, :kill))
    {:reply, :ok, %{state | listener: nil, connections: []}}
  end

  def handle_call(:resume, _from, state), do: {:reply, :ok, listen(state, state.port)}

  @impl true
  def handle_info({:connection, pid}, state),
    do: {:noreply, %{state | connections: [pid | state.connections]}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp listen(state, port) do
    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    proxy = self()
    upstream = state.upstream
    spawn_link(fn -> accept(listener, proxy, upstream) end)
    Map.merge(state, %{listener: listener, port: port})
  end

  defp accept(listener, proxy, upstream) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        pid = spawn(fn -> connection(upstream) end)
        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, {:client, client})
        send(proxy, {:connection, pid})
        accept(listener, proxy, upstream)

      {:error, _closed} ->
        :ok
    end
  end

  defp connection({host, port}) do
    receive do
      {:client, client} ->
        {:ok, upstream} = :gen_tcp.connect(host, port, [:binary, active: true])
        :ok = :inet.setopts(client, active: true)
        relay(client, upstream)
    end
  end

  defp relay(client, upstream) do
    receive do
      {:tcp, ^client, data} ->
        :gen_tcp.send(upstream, data)
        relay(client, upstream)

      {:tcp, ^upstream, data} ->
        :gen_tcp.send(client, data)
        relay(client, upstream)

      {:tcp_closed, _socket} ->
        close(client, upstream)

      {:tcp_error, _socket, _reason} ->
        close(client, upstream)
    end
  end

  defp close(client, upstream) do
    :gen_tcp.close(client)
    :gen_tcp.close(upstream)
  end
end
