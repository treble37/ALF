defmodule ALF.ComponentThrowTest do
  use ExUnit.Case, async: false

  alias ALF.{Manager, ErrorIP, IP}

  describe "throw in stage" do
    defmodule ThrowInStagePipeline do
      use ALF.DSL

      @components [
        stage(:add_one),
        stage(:mult_two)
      ]

      def add_one(event, _) do
        if event == 1 do
          throw("throw in :add_one")
        else
          event + 1
        end
      end

      def mult_two(event, _), do: event * 2
    end

    setup do
      Manager.start(ThrowInStagePipeline)
    end

    test "returns error immediately (skips mult_two)" do
      results =
        [1, 2, 3]
        |> Manager.stream_to(ThrowInStagePipeline)
        |> Enum.to_list()

      assert [
               %ErrorIP{
                 component: %ALF.Components.Stage{function: :add_one},
                 ip: %IP{} = ip,
                 error: :throw,
                 stacktrace: "throw in :add_one"
               },
               6,
               8
             ] = results

      assert [{{:add_one, 0}, _event}] = ip.history
    end
  end

  describe "exit in stage" do
    defmodule ExitInStagePipeline do
      use ALF.DSL

      @components [
        stage(:add_one),
        stage(:mult_two)
      ]

      def add_one(event, _) do
        if event == 1 do
          exit("exit in :add_one")
        else
          event + 1
        end
      end

      def mult_two(event, _), do: event * 2
    end

    setup do
      Manager.start(ExitInStagePipeline)
    end

    test "returns error immediately (skips mult_two)" do
      results =
        [1, 2, 3]
        |> Manager.stream_to(ExitInStagePipeline)
        |> Enum.to_list()

      assert [
               %ErrorIP{
                 component: %ALF.Components.Stage{function: :add_one},
                 ip: %IP{} = ip,
                 error: :exit,
                 stacktrace: "exit in :add_one"
               },
               6,
               8
             ] = results

      assert [{{:add_one, 0}, _event}] = ip.history
    end
  end

  describe "throw in switch function" do
    defmodule ThrowInSwitchPipeline do
      use ALF.DSL

      @components [
        switch(:switch_cond,
          branches: %{
            1 => [stage(:add_one)],
            2 => [stage(:mult_two)]
          }
        ),
        stage(:ok)
      ]

      def switch_cond(_event, _) do
        throw("throw in :switch")
      end

      def add_one(event, _) do
        event + 1
      end

      def mult_two(event, _) do
        event * 2
      end

      def ok(event, _), do: event
    end

    setup do
      Manager.start(ThrowInSwitchPipeline)
    end

    test "error results" do
      results =
        [1, 2]
        |> Manager.stream_to(ThrowInSwitchPipeline, return_ips: true)
        |> Enum.to_list()

      assert [
               %ErrorIP{
                 component: %ALF.Components.Switch{name: :switch_cond},
                 ip: %IP{} = ip,
                 error: :throw,
                 stacktrace: "throw in :switch"
               },
               %ErrorIP{}
             ] = results

      assert [switch_cond: _event] = ip.history
    end
  end

  describe "error in goto function" do
    defmodule ThrowInGotoPipeline do
      use ALF.DSL

      @components [
        goto_point(:goto_point),
        stage(:add_one),
        goto(:goto_function, to: :goto_point)
      ]

      def goto_function(_event, _) do
        throw("throw in :goto")
      end

      def add_one(event, _), do: event + 1
    end

    setup do
      Manager.start(ThrowInGotoPipeline)
    end

    test "error results" do
      results =
        [1, 2, 3]
        |> Manager.stream_to(ThrowInGotoPipeline)
        |> Enum.to_list()

      assert [
               %ErrorIP{
                 component: %ALF.Components.Goto{name: :goto_function},
                 ip: %IP{} = ip,
                 error: :throw,
                 stacktrace: "throw in :goto"
               },
               %ErrorIP{},
               %ErrorIP{}
             ] = results

      assert [{:goto_function, _}, {{:add_one, 0}, _}, {:goto_point, _}] = ip.history
    end
  end
end
