defmodule Mix.Tasks.Garlic.UpdateAuthorities do
  @moduledoc false
  @shortdoc "Updates directory authorities list"

  use Mix.Task

  @link "https://gitweb.torproject.org/tor.git/plain/src/app/config/auth_dirs.inc"

  @impl true
  def run(_args) do
    with {:ok, {{_, 200, _}, _, body}} <- :httpc.request(@link) do
      File.write!("./priv/auth_dirs.inc", body)
    end
  end
end
