defmodule ALF.IP do
  @moduledoc "Defines internal pipeline struct"

  defstruct type: :ip,
            init_datum: nil,
            stream_ref: nil,
            ref: nil,
            new_stream_ref: nil,
            destination: nil,
            event: nil,
            history: [],
            manager_name: nil,
            done!: false,
            in_progress: false,
            decomposed: false,
            recomposed: false,
            plugs: %{},
            sync_path: nil
end
