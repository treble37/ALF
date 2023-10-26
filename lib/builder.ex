defmodule ALF.Builder do
  alias ALF.Pipeline

  alias ALF.Components.{
    Producer,
    Stage,
    Goto,
    DeadEnd,
    GotoPoint,
    Switch,
    Clone,
    Done,
    Consumer,
    Plug,
    Unplug,
    Decomposer,
    Recomposer,
    Tbd
  }

  @spec build(atom, pid, boolean) :: {:ok, Pipeline.t()}
  def build(pipeline_module, supervisor_pid, telemetry) do
    pipe_spec = pipeline_module.alf_components()
    producer = start_producer(supervisor_pid, pipeline_module, telemetry)

    {last_stages, final_stages} =
      do_build_pipeline(
        pipeline_module,
        pipe_spec,
        [producer],
        supervisor_pid,
        [],
        telemetry
      )

    consumer =
      start_consumer(
        supervisor_pid,
        last_stages,
        pipeline_module,
        telemetry
      )

    {producer, consumer} =
      set_modules_to_producer_and_consumer({producer, consumer}, pipeline_module)

    pipeline = %Pipeline{producer: producer, consumer: consumer, components: final_stages}
    {:ok, pipeline}
  end

  defp do_build_pipeline(
         pipeline_module,
         pipe_spec,
         producers,
         supervisor_pid,
         final_stages,
         telemetry
       )
       when is_list(pipe_spec) do
    pipe_spec
    |> Enum.reduce({producers, final_stages}, fn stage_spec, {prev_stages, stages} ->
      case stage_spec do
        %Stage{count: count} = stage ->
          stage_set_ref = make_ref()

          new_stages =
            Enum.map(0..(count - 1), fn number ->
              stage
              |> Map.merge(%{
                pipeline_module: pipeline_module,
                stage_set_ref: stage_set_ref,
                number: number,
                telemetry: telemetry
              })
              |> start_stage(supervisor_pid, prev_stages)
            end)

          {new_stages, stages ++ new_stages}

        %Goto{} = goto ->
          goto =
            goto
            |> Map.merge(%{
              pipeline_module: pipeline_module,
              stage_set_ref: make_ref(),
              telemetry: telemetry
            })
            |> start_stage(supervisor_pid, prev_stages)

          {[goto], stages ++ [goto]}

        %DeadEnd{} = dead_end ->
          dead_end =
            dead_end
            |> Map.merge(%{
              pipeline_module: pipeline_module,
              stage_set_ref: make_ref(),
              telemetry: telemetry
            })
            |> start_stage(supervisor_pid, prev_stages)

          {[], stages ++ [dead_end]}

        %GotoPoint{} = goto_point ->
          goto_point =
            goto_point
            |> Map.merge(%{
              pipeline_module: pipeline_module,
              stage_set_ref: make_ref(),
              telemetry: telemetry
            })
            |> start_stage(supervisor_pid, prev_stages)

          {[goto_point], stages ++ [goto_point]}

        %Switch{branches: branches} = switch ->
          switch =
            switch
            |> Map.merge(%{
              pipeline_module: pipeline_module,
              stage_set_ref: make_ref(),
              telemetry: telemetry
            })
            |> start_stage(supervisor_pid, prev_stages)

          {last_stages, branches} =
            Enum.reduce(branches, {[], %{}}, fn {key, inner_pipe_spec},
                                                {all_last_stages, branches} ->
              {last_stages, final_stages} =
                do_build_pipeline(
                  pipeline_module,
                  inner_pipe_spec,
                  [{switch, partition: key}],
                  supervisor_pid,
                  [],
                  telemetry
                )

              {all_last_stages ++ last_stages, Map.put(branches, key, final_stages)}
            end)

          switch = %{switch | branches: branches}

          {last_stages, stages ++ [switch]}

        %Clone{to: pipe_stages} = clone ->
          clone =
            clone
            |> Map.merge(%{
              pipeline_module: pipeline_module,
              stage_set_ref: make_ref(),
              telemetry: telemetry
            })
            |> start_stage(supervisor_pid, prev_stages)

          {last_stages, final_stages} =
            do_build_pipeline(
              pipeline_module,
              pipe_stages,
              [clone],
              supervisor_pid,
              [],
              telemetry
            )

          clone = %{clone | to: final_stages}

          {last_stages ++ [clone], stages ++ [clone]}

        %Done{} = done ->
          done =
            done
            |> Map.merge(%{
              pipeline_module: pipeline_module,
              stage_set_ref: make_ref(),
              telemetry: telemetry
            })
            |> start_stage(supervisor_pid, prev_stages)

          {[done], stages ++ [done]}

        %Plug{} = plug ->
          plug =
            plug
            |> Map.merge(%{stage_set_ref: make_ref(), telemetry: telemetry})
            |> start_stage(supervisor_pid, prev_stages)

          {[plug], stages ++ [plug]}

        %Unplug{} = unplug ->
          unplug =
            unplug
            |> Map.merge(%{stage_set_ref: make_ref(), telemetry: telemetry})
            |> start_stage(supervisor_pid, prev_stages)

          {[unplug], stages ++ [unplug]}

        %Decomposer{} = decomposer ->
          decomposer =
            decomposer
            |> Map.merge(%{stage_set_ref: make_ref(), telemetry: telemetry})
            |> start_stage(supervisor_pid, prev_stages)

          {[decomposer], stages ++ [decomposer]}

        %Recomposer{} = recomposer ->
          recomposer =
            recomposer
            |> Map.merge(%{stage_set_ref: make_ref(), telemetry: telemetry})
            |> start_stage(supervisor_pid, prev_stages)

          {[recomposer], stages ++ [recomposer]}

        %Tbd{} = tbd ->
          tbd =
            tbd
            |> Map.merge(%{stage_set_ref: make_ref(), telemetry: telemetry})
            |> start_stage(supervisor_pid, prev_stages)

          {[tbd], stages ++ [tbd]}
      end
    end)
  end

  @spec build_sync(atom, boolean) :: [map]
  def build_sync(pipeline_module, telemetry) do
    pipe_spec = pipeline_module.alf_components()
    producer = Producer.init_sync(%Producer{pipeline_module: pipeline_module}, telemetry)
    {components, last_stage_refs} = do_build_sync(pipe_spec, [producer.pid], telemetry)
    consumer = Consumer.init_sync(%Consumer{pipeline_module: pipeline_module}, telemetry)
    subscribed_to = Enum.map(last_stage_refs, &{&1, :sync})
    consumer = %{consumer | subscribed_to: subscribed_to}
    [producer | components] ++ [consumer]
  end

  defp do_build_sync(pipe_spec, stage_refs, telemetry) when is_list(pipe_spec) do
    Enum.reduce(pipe_spec, {[], stage_refs}, fn comp, {stages, last_stage_refs} ->
      subscribed_to = Enum.map(last_stage_refs, &{&1, :sync})

      case comp do
        %Switch{branches: branches} = switch ->
          switch = switch.__struct__.init_sync(switch, telemetry)

          branches =
            Enum.reduce(branches, %{}, fn {key, inner_pipe_spec}, branch_pipes ->
              {branch_stages, _last_ref} = do_build_sync(inner_pipe_spec, [switch.pid], telemetry)

              Map.put(branch_pipes, key, branch_stages)
            end)

          switch = %{switch | branches: branches, subscribed_to: subscribed_to}

          last_stage_refs =
            Enum.map(branches, fn {_key, stages} ->
              case List.last(stages) do
                nil -> nil
                stage -> stage.pid
              end
            end)

          {stages ++ [switch], last_stage_refs}

        %Clone{to: pipe_stages} = clone ->
          clone = clone.__struct__.init_sync(clone, telemetry)
          {to_stages, _last_ref} = do_build_sync(pipe_stages, [clone.pid], telemetry)
          clone = %{clone | to: to_stages, subscribed_to: subscribed_to}
          {stages ++ [clone], [clone.pid]}

        component ->
          component = component.__struct__.init_sync(component, telemetry)
          component = %{component | subscribed_to: subscribed_to}
          {stages ++ [component], [component.pid]}
      end
    end)
  end

  defp start_producer(supervisor_pid, pipeline_module, telemetry) do
    producer = %Producer{
      pipeline_module: pipeline_module,
      stage_set_ref: make_ref(),
      telemetry: telemetry
    }

    {:ok, producer_pid} = DynamicSupervisor.start_child(supervisor_pid, {Producer, producer})
    %{producer | pid: producer_pid}
  end

  defp start_consumer(
         supervisor_pid,
         last_stages,
         pipeline_module,
         telemetry
       ) do
    consumer = %Consumer{
      pipeline_module: pipeline_module,
      telemetry: telemetry
    }

    {:ok, consumer_pid} = DynamicSupervisor.start_child(supervisor_pid, {Consumer, consumer})
    subscribe(consumer_pid, last_stages)

    %{consumer | pid: consumer_pid}
  end

  defp set_modules_to_producer_and_consumer({producer, consumer}, pipeline_module) do
    producer = %{producer | pipeline_module: pipeline_module}
    consumer = %{consumer | pipeline_module: pipeline_module}

    {producer, consumer}
  end

  defp start_stage(stage, supervisor_pid, prev_stages) do
    {:ok, stage_pid} = DynamicSupervisor.start_child(supervisor_pid, {stage.__struct__, stage})
    subscribe(stage_pid, prev_stages)
    %{stage | pid: stage_pid}
  end

  defp subscribe(stage_pid, stages) do
    stages
    |> Enum.each(fn stage ->
      case stage do
        {stage, partition: key} ->
          GenStage.async_subscribe(stage_pid,
            to: stage.pid,
            max_demand: 1,
            cancel: :temporary,
            partition: key
          )

        stage ->
          GenStage.async_subscribe(stage_pid, to: stage.pid, max_demand: 1, cancel: :temporary)
      end
    end)
  end
end
