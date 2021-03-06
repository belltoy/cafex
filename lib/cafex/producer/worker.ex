defmodule Cafex.Producer.Worker do
  use GenServer

  defmodule State do
    @moduledoc false
    defstruct broker: nil,
              topic: nil,
              partition: nil,
              client_id: nil,
              conn: nil,
              acks: 1,
              batch_num: nil,
              batches: [],
              # max_request_size: nil,
              linger_ms: 0,
              timer: nil,
              timeout: 60000,
              compression: nil
  end

  alias Cafex.Connection
  alias Cafex.Protocol.Produce.Request
  alias Cafex.Protocol.Produce.Response

  # ===================================================================
  # API
  # ===================================================================

  def start_link(broker, topic, partition, opts \\ []) do
    GenServer.start_link __MODULE__, [broker, topic, partition, opts]
  end

  def produce(pid, message) do
    GenServer.call pid, {:produce, message}
  end

  def async_produce(pid, message) do
    GenServer.cast pid, {:produce, message}
  end

  def stop(pid) do
    GenServer.call pid, :stop
  end

  # ===================================================================
  #  GenServer callbacks
  # ===================================================================

  def init([{host, port} = broker, topic, partition, opts]) do
    acks          = Keyword.get(opts, :acks, 1)
    timeout       = Keyword.get(opts, :timeout, 60000)
    client_id     = Keyword.get(opts, :client_id, "cafex")
    batch_num        = Keyword.get(opts, :batch_num)
    # max_request_size = Keyword.get(opts, :max_request_size)
    linger_ms        = Keyword.get(opts, :linger_ms)
    compression      = Keyword.get(opts, :compression)

    state = %State{ broker: broker,
                    topic: topic,
                    partition: partition,
                    client_id: client_id,
                    acks: acks,
                    batch_num: batch_num,
                    # max_request_size: max_request_size,
                    linger_ms: linger_ms,
                    timeout: timeout,
                    compression: compression}

    case Connection.start_link(host, port, client_id: client_id) do
      {:ok, pid} ->
        {:ok, %{state | conn: pid}}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_call({:produce, message}, from, state) do
    maybe_produce(message, from, state)
  end
  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_cast({:produce, message}, state) do
    maybe_produce(message, nil, state)
  end

  def handle_info({:timeout, timer, :linger_timeout}, %{timer: timer, batches: batches} = state) do
    result = batches |> Enum.reverse |> do_produce(state)
    state = %{state|timer: nil, batches: []}
    case result do
      :ok ->
        {:noreply, state}
      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  def terminate(reason, %{conn: conn, batches: batches}) do
    case batches do
      nil -> :ok
      [] -> :ok
      batches ->
        Enum.each(batches, fn {from, _} ->
          do_reply({from, {:error, reason}})
        end)
    end

    if conn, do: Connection.close(conn)
    :ok
  end

  # ===================================================================
  #  Internal functions
  # ===================================================================

  defp maybe_produce(message, from, %{linger_ms: linger_ms} = state) when is_integer(linger_ms) and linger_ms <= 0 do
    case do_produce([{from, message}], state) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end
  defp maybe_produce(message, from, %{batches: batches, batch_num: batch_num} = state) when length(batches) + 1 >= batch_num do
    result = [{from, message}|batches] |> Enum.reverse |> do_produce(state)
    state = %{state|batches: []}
    case result do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end
  defp maybe_produce(message, from, %{linger_ms: linger_ms, batches: batches, timer: timer} = state) do
    timer = case timer do
      nil ->
        :erlang.start_timer(linger_ms, self, :linger_timeout)
      timer ->
        timer
    end
    {:noreply, %{state|batches: [{from, message}|batches], timer: timer}}
  end

  defp do_produce([], _state), do: :ok
  defp do_produce(message_pairs, state) do
    case do_request(message_pairs, state) do
      {:ok, replies} ->
        Enum.each(replies, &do_reply/1)
        :ok
      {:error, reason} ->
        # Enum.each(message_pairs, &(do_reply({elem(&1, 0), reason})))
        Enum.each(message_pairs, fn {from, _message} ->
          do_reply({from, reason})
        end)
        {:error, reason}
    end
  end

  defp do_request(message_pairs, %{topic: topic,
                               partition: partition,
                                    acks: acks,
                                 timeout: timeout,
                             compression: compression,
                                    conn: conn}) do

    messages = Enum.map(message_pairs, fn {_from, message} ->
      %{message | topic: topic, partition: partition}
    end)

    request = %Request{ required_acks: acks,
                        timeout: timeout,
                        compression: compression,
                        messages: messages }

    case Connection.request(conn, request) do
      {:ok, %Response{topics: [{^topic, [%{error: :no_error, partition: ^partition}]}]}} ->
        replies = Enum.map(message_pairs, fn {from, _} ->
          {from, :ok}
        end)
        {:ok, replies}
      {:ok, %Response{topics: [{^topic, [%{error: reason}]}]}} ->
        replies = Enum.map(message_pairs, fn {from, _} ->
          {from, {:error, reason}}
        end)
        {:ok, replies}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_reply({nil, _reply}), do: :ok
  defp do_reply({from, reply}), do: GenServer.reply(from, reply)
end
