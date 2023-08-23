defmodule ALF.Components.Done do
  use ALF.Components.Basic

  defstruct Basic.common_attributes() ++
              [
                type: :done,
                module: nil,
                function: true,
                opts: [],
                source_code: nil
              ]

  alias ALF.DSLError

  @dsl_options [:opts, :name]

  @spec start_link(t()) :: GenServer.on_start()
  def start_link(%__MODULE__{} = state) do
    GenStage.start_link(__MODULE__, state)
  end

  @impl true
  def init(state) do
    state = %{
      state
      | pid: self(),
        opts: init_opts(state.module, state.opts),
        source_code: state.source_code || read_source_code(state.module, state.function)
    }

    {:producer_consumer, state, subscribe_to: state.subscribe_to}
  end

  def init_sync(state, telemetry_enabled) do
    %{
      state
      | pid: make_ref(),
        opts: init_opts(state.module, state.opts),
        source_code: state.source_code || read_source_code(state.module, state.function),
        telemetry_enabled: telemetry_enabled
    }
  end

  @impl true
  def handle_events([%ALF.IP{} = ip], _from, %__MODULE__{telemetry_enabled: true} = state) do
    :telemetry.span(
      [:alf, :component],
      telemetry_data(ip, state),
      fn ->
        case process_ip(ip, state) do
          %IP{} = ip ->
            {{:noreply, [ip], state}, telemetry_data(ip, state)}

          %ErrorIP{} = ip ->
            {{:noreply, [], state}, telemetry_data(ip, state)}

          nil ->
            {{:noreply, [], state}, telemetry_data(ip, state)}
        end
      end
    )
  end

  def handle_events([%ALF.IP{} = ip], _from, %__MODULE__{telemetry_enabled: false} = state) do
    case process_ip(ip, state) do
      %IP{} = ip ->
        {:noreply, [ip], state}

      %ErrorIP{} ->
        {:noreply, [], state}

      nil ->
        {:noreply, [], state}
    end
  end

  defp process_ip(ip, state) do
    ip = %{ip | history: [{state.name, ip.event} | ip.history]}

    case call_function(state.module, state.function, ip.event, state.opts) do
      {:error, error, stacktrace} ->
        send_error_result(ip, error, stacktrace, state)

      true ->
        send_result(ip, ip)
        nil

      false ->
        ip

      nil ->
        ip
    end
  end

  def sync_process(ip, %__MODULE__{telemetry_enabled: false} = state) do
    do_sync_process(ip, state)
  end

  def sync_process(ip, %__MODULE__{telemetry_enabled: true} = state) do
    :telemetry.span(
      [:alf, :component],
      telemetry_data(ip, state),
      fn ->
        {success, ip} = do_sync_process(ip, state)
        {{success, ip}, telemetry_data(ip, state)}
      end
    )
  end

  def do_sync_process(ip, state) do
    ip = %{ip | history: [{state.name, ip.event} | ip.history]}

    case call_function(state.module, state.function, ip.event, state.opts) do
      {:error, error, stacktrace} ->
        {false, build_error_ip(ip, error, stacktrace, state)}

      true ->
        {true, ip}

      false ->
        {false, ip}

      nil ->
        {false, ip}
    end
  end

  def validate_options(atom, options) do
    wrong_options = Keyword.keys(options) -- @dsl_options

    unless is_atom(atom) do
      raise DSLError, "The name must be an atom: #{inspect(atom)}"
    end

    if Enum.any?(wrong_options) do
      raise DSLError,
            "Wrong options for the #{atom} done?: #{inspect(wrong_options)}. " <>
              "Available options are #{inspect(@dsl_options)}"
    end
  end

  defp call_function(_module, true, _event, _opts), do: true

  defp call_function(module, function, event, opts) when is_atom(module) and is_atom(function) do
    apply(module, function, [event, opts])
  rescue
    error ->
      {:error, error, __STACKTRACE__}
  catch
    kind, value ->
      {:error, kind, value}
  end
end
